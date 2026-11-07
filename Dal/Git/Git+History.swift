import Foundation

/// History editing, patches, worktrees and web links — the extra commit/branch actions.
extension Git {
    enum HistoryEdit: String {
        case drop      // remove the commit
        case reword    // change its message
        case down      // swap with its parent (moves it lower in the graph)
        case up        // swap with its child (moves it higher)
    }

    /// Rewrites a commit on the current branch with a non-interactive `git rebase -i`: a small
    /// Perl script (Perl ships with macOS) edits the todo list in place of an editor.
    /// Callers check the preconditions (clean tree, linear range, target on HEAD's history).
    func rewrite(_ edit: HistoryEdit, target: String, message: String? = nil) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let script = temp.appendingPathComponent("todo.pl")
        try Self.todoEditor.write(to: script, atomically: true, encoding: .utf8)
        var env = ["GIT_SEQUENCE_EDITOR": "perl \(script.path.shellQuoted)",
                   "DAL_TARGET": target, "DAL_OP": edit.rawValue]
        if let message {
            let file = temp.appendingPathComponent("message.txt")
            try message.write(to: file, atomically: true, encoding: .utf8)
            env["GIT_EDITOR"] = "cp \(file.path.shellQuoted)"
        }
        let base = edit == .down ? "\(target)~2" : "\(target)^"
        try await run(["-c", "rebase.abbreviateCommands=false", "rebase", "-i", "--no-autosquash", "--no-update-refs",
                       "--end-of-options", base], env: env)
    }

    /// Edits the rebase todo: finds the target's `pick` line by SHA prefix and applies DAL_OP.
    static let todoEditor = #"""
    use strict;
    my ($file) = @ARGV;
    open(my $in, '<', $file) or die "cannot read todo\n";
    my @l = <$in>;
    close $in;
    my $t = $ENV{DAL_TARGET};
    my $op = $ENV{DAL_OP};
    my $idx = -1;
    for my $i (0 .. $#l) {
        if ($l[$i] =~ /^pick\s+([0-9a-f]+)/ && index($t, $1) == 0) { $idx = $i; last; }
    }
    die "commit not found in rebase todo\n" if $idx < 0;
    if ($op eq 'drop') { $l[$idx] =~ s/^pick\b/drop/; }
    elsif ($op eq 'reword') { $l[$idx] =~ s/^pick\b/reword/; }
    elsif ($op eq 'down') {
        my $j = $idx - 1; $j-- while ($j >= 0 && $l[$j] !~ /^pick\s/);
        die "no older commit to swap with\n" if $j < 0;
        @l[$j, $idx] = @l[$idx, $j];
    }
    elsif ($op eq 'up') {
        my $j = $idx + 1; $j++ while ($j <= $#l && $l[$j] !~ /^pick\s/);
        die "no newer commit to swap with\n" if $j > $#l;
        @l[$j, $idx] = @l[$idx, $j];
    }
    open(my $out, '>', $file) or die "cannot write todo\n";
    print $out @l;
    close $out;
    """#

    /// Why a commit can't be rewritten in place, or nil when it can.
    func rewriteProblem(_ edit: HistoryEdit, target: String) async -> String? {
        guard (try? await run(["merge-base", "--is-ancestor", target, "HEAD"])) != nil else {
            return "Only commits on the checked-out branch's history can be edited."
        }
        let base = edit == .down ? "\(target)~2" : "\(target)^"
        guard (try? await run(["rev-parse", "--verify", "-q", "\(base)^{commit}"])) != nil else {
            return edit == .down ? "This commit has nothing older to move below." : "The first commit of a repository can't be edited this way."
        }
        let merges = (try? await string(["rev-list", "--merges", "\(base)..HEAD"]))?.trimmed ?? ""
        if !merges.isEmpty { return "There's a merge between this commit and HEAD; edit history from the command line instead." }
        if edit == .up, (try? await string(["rev-parse", "HEAD"]))?.trimmed == target {
            return "This is already the newest commit."
        }
        return nil
    }

    /// Remote branches that already contain the commit (rewriting it needs a force push).
    func remotesContaining(_ sha: String) async -> [String] {
        let out = (try? await string(["branch", "-r", "--contains", sha, "--format=%(refname:short)"])) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
    }

    func formatPatch(_ sha: String) async throws -> Data {
        try await run(["format-patch", "-1", "--stdout", "--end-of-options", sha])
    }

    /// `git am` for mailbox patches (from format-patch), otherwise `git apply` to the working tree.
    func applyPatch(at file: URL) async throws {
        let head = (try? String(contentsOf: file, encoding: .utf8).prefix(200)) ?? ""
        if head.hasPrefix("From ") {
            try await run(["am", "--3way", "--", file.path])
        } else {
            try await run(["apply", "--3way", "--", file.path])
        }
    }

    func remoteURL(_ remote: String) async -> String? {
        let url = (try? await string(["remote", "get-url", "--", remote]))?.trimmed ?? ""
        return url.isEmpty ? nil : url
    }
}

/// Turns a remote URL into web links (GitHub, GitLab, Bitbucket and look-alikes).
enum RemoteWeb {
    /// "git@github.com:owner/repo.git" / "https://github.com/owner/repo" → https://github.com/owner/repo
    static func base(_ remote: String) -> URL? {
        var s = remote.trimmed
        if s.hasSuffix(".git") { s.removeLast(4) }
        if s.hasPrefix("git@"), let colon = s.firstIndex(of: ":") {
            let host = s[s.index(s.startIndex, offsetBy: 4)..<colon]
            return URL(string: "https://\(host)/\(s[s.index(after: colon)...])")
        }
        if s.hasPrefix("ssh://") {
            s.removeFirst(6)
            if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            if let slash = s.firstIndex(of: "/") {
                var host = String(s[..<slash])
                if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
                return URL(string: "https://\(host)\(s[slash...])")
            }
            return nil
        }
        if s.hasPrefix("https://") || s.hasPrefix("http://"), var comps = URLComponents(string: s) {
            comps.user = nil; comps.password = nil; comps.scheme = "https"
            return comps.url
        }
        return nil
    }

    static func branch(_ remote: String, _ branch: String) -> URL? {
        guard let base = base(remote) else { return nil }
        let name = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let host = base.host ?? ""
        if host.contains("gitlab") { return URL(string: "\(base.absoluteString)/-/tree/\(name)") }
        if host.contains("bitbucket") { return URL(string: "\(base.absoluteString)/src/\(name)") }
        return URL(string: "\(base.absoluteString)/tree/\(name)")
    }

    static func commit(_ remote: String, _ sha: String) -> URL? {
        guard let base = base(remote) else { return nil }
        let host = base.host ?? ""
        if host.contains("gitlab") { return URL(string: "\(base.absoluteString)/-/commit/\(sha)") }
        if host.contains("bitbucket") { return URL(string: "\(base.absoluteString)/commits/\(sha)") }
        return URL(string: "\(base.absoluteString)/commit/\(sha)")
    }
}
