import Foundation

/// Thin async wrapper over the git CLI for one working tree.
struct Git: Sendable {
    let dir: URL
    /// Extra environment (the active profile's identity, SSH key and credential helper).
    var env: [String: String] = [:]
    /// `-c` overrides that neutralise program-running settings of an untrusted repository.
    var safety: [String] = []

    @discardableResult
    func run(_ args: [String], input: Data? = nil, allowExit: Set<Int32> = [0],
             env: [String: String] = [:]) async throws -> Data {
        // log.showSignature would make `git log` run gpg.program; Dal never shows signatures.
        let base = ["-c", "color.ui=false", "-c", "core.quotepath=false", "-c", "advice.detachedHead=false",
                    "-c", "log.showSignature=false"] + safety
        var result = try await Shell.run("git", base + args, cwd: dir, input: input, env: self.env.merging(env) { $1 })
        // Another git (a coding agent in this worktree, an editor, a hook) holds index.lock or a
        // ref lock for a moment. Git takes the lock before touching anything, so trying again is
        // safe; wait it out for a few seconds instead of failing the user's click.
        var attempt = 0
        while !allowExit.contains(result.status), attempt < 12, Self.isLockContention(result.stderr.utf8) {
            attempt += 1
            try await Task.sleep(for: .milliseconds(min(150 * attempt, 600)))
            result = try await Shell.run("git", base + args, cwd: dir, input: input, env: self.env.merging(env) { $1 })
        }
        guard allowExit.contains(result.status) else {
            var message = result.stderr.utf8.trimmed
            if message.isEmpty { message = result.stdout.utf8.trimmed }
            throw GitError(command: args.first ?? "", message: Self.clean(message), exitCode: result.status)
        }
        return result.stdout
    }

    func string(_ args: [String], input: Data? = nil, allowExit: Set<Int32> = [0]) async throws -> String {
        try await run(args, input: input, allowExit: allowExit).utf8
    }

    /// "Unable to create '…/index.lock': File exists." / "cannot lock ref …" — another git
    /// process is mid-write.
    static func isLockContention(_ stderr: String) -> Bool {
        stderr.contains(".lock") && (stderr.contains("File exists") || stderr.contains("Unable to create"))
    }

    /// The lock file named in git's "Unable to create '<path>.lock': File exists." message.
    static func lockPath(in message: String) -> String? {
        guard let start = message.range(of: "Unable to create '")?.upperBound,
              let end = message[start...].range(of: ".lock'")?.lowerBound else { return nil }
        return String(message[start..<end]) + ".lock"
    }

    /// Strips git's "hint:" noise so error alerts stay readable.
    static func clean(_ message: String) -> String {
        message.split(separator: "\n")
            .filter { !$0.hasPrefix("hint:") }
            .joined(separator: "\n")
            .trimmed
    }

    // MARK: Reading

    func gitDir() async throws -> URL {
        URL(fileURLWithPath: try await string(["rev-parse", "--absolute-git-dir"]).trimmed)
    }

    func headSha() async -> String? {
        let s = (try? await string(["rev-parse", "-q", "--verify", "HEAD"], allowExit: [0, 1]))?.trimmed ?? ""
        return s.isEmpty ? nil : s
    }

    func currentBranch() async -> String? {
        let s = (try? await string(["symbolic-ref", "--short", "-q", "HEAD"], allowExit: [0, 1]))?.trimmed ?? ""
        return s.isEmpty ? nil : s
    }

    func refs() async throws -> [Ref] {
        Parse.refs(try await string(["for-each-ref", "--format=\(Parse.refFormat)",
                                     "refs/heads", "refs/remotes", "refs/tags"]))
    }

    /// Like `refs()`, but survives refs whose commit is missing from the object store (a crash
    /// or concurrent `git gc` mid-write can leave one behind; `for-each-ref` then aborts and
    /// `log --branches` fails). The good refs come back, the broken ones are named separately.
    func refsTolerant() async throws -> (refs: [Ref], broken: [String]) {
        do {
            return (try await refs(), [])
        } catch {
            let listing = try await string(["for-each-ref", "--format=%(objectname) %(refname)",
                                            "refs/heads", "refs/remotes", "refs/tags"])
            let pairs = listing.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
            guard !pairs.isEmpty else { throw error }
            let check = try await string(["cat-file", "--batch-check"],
                                         input: Data(pairs.map { $0.0 + "\n" }.joined().utf8))
            let missing = Set(check.split(separator: "\n").filter { $0.hasSuffix(" missing") }
                .map { String($0.dropLast(" missing".count)) })
            let broken = pairs.filter { missing.contains($0.0) }.map(\.1)
            guard !broken.isEmpty else { throw error }
            let good = pairs.filter { !missing.contains($0.0) }.map(\.1)
            if good.isEmpty { return ([], broken) }
            let text = try await string(["for-each-ref", "--format=\(Parse.refFormat)"] + good)
            return (Parse.refs(text), broken)
        }
    }

    func log(limit: Int, includeHead: Bool, only: [String]? = nil) async throws -> [Commit] {
        var args = ["log", "--date-order", "-n", "\(limit)", "--format=\(Parse.logFormat)"]
        if let only {
            // Full refnames only (refs/heads/…), so a name can't be read as an option.
            args += only.filter { $0.hasPrefix("refs/") }
        } else {
            args += ["--branches", "--remotes", "--tags"]
        }
        if includeHead { args.append("HEAD") }
        args.append("--")
        return Parse.log(try await string(args))
    }

    func status() async throws -> WorkingStatus {
        Parse.status(try await string(["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
    }

    func stashes() async throws -> [Stash] {
        Parse.stashes(try await string(["stash", "list", "--format=\(Parse.stashFormat)"]))
    }

    func worktrees() async throws -> [Worktree] {
        Parse.worktrees(try await string(["worktree", "list", "--porcelain"]))
    }

    func remotes() async throws -> [String] {
        try await string(["remote"]).split(separator: "\n").map(String.init)
    }

    func changes(sha: String, parent: String?) async throws -> [FileChange] {
        if let parent {
            return Parse.nameStatus(try await string(["diff", "--no-ext-diff", "--name-status", "-z", "-M", parent, sha]))
        }
        return Parse.nameStatus(try await string(["diff-tree", "--root", "-r", "--no-commit-id",
                                                  "--name-status", "-z", "-M", sha]))
    }

    func lastCommitMessage() async -> String {
        (try? await string(["log", "-1", "--format=%B"]))?.trimmed ?? ""
    }

    func show(_ spec: String) async throws -> String {
        try await string(["show", spec])
    }

    // MARK: Diffs

    func diffWorking(_ change: FileChange, staged: Bool) async throws -> FileDiff {
        if change.kind == .untracked {
            let out = try await string(["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", change.path],
                                       allowExit: [0, 1])
            return Parse.diff(out)
        }
        var args = ["diff", "--no-ext-diff", "-M"]
        if staged { args.append("--cached") }
        args.append("--")
        if let old = change.oldPath { args.append(old) }
        args.append(change.path)
        return Parse.diff(try await string(args))
    }

    func diffCommit(sha: String, parent: String?, change: FileChange) async throws -> FileDiff {
        var paths = [change.path]
        if let old = change.oldPath { paths.insert(old, at: 0) }
        if let parent {
            return Parse.diff(try await string(["diff", "--no-ext-diff", "-M", parent, sha, "--"] + paths))
        }
        return Parse.diff(try await string(["show", "--no-ext-diff", "--format=", "-M", sha, "--"] + paths))
    }

    func apply(patch: String, cached: Bool, reverse: Bool) async throws {
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        args.append("-")
        try await run(args, input: Data(patch.utf8))
    }
}

enum GitHub {
    static func run(_ args: [String], in dir: URL, env: [String: String] = [:]) async throws -> Data {
        let result = try await Shell.run("gh", args, cwd: dir, env: env)
        guard result.status == 0 else {
            let msg = result.stderr.utf8.trimmed
            throw GitError(command: "gh", message: msg.isEmpty ? "gh exited with \(result.status)" : msg,
                           exitCode: result.status)
        }
        return result.stdout
    }

    static func pullRequests(in dir: URL, env: [String: String] = [:]) async throws -> [PullRequest] {
        let data = try await run(["pr", "list", "--limit", "50", "--json",
                                  "number,title,url,headRefName,baseRefName,isDraft,state,author"], in: dir, env: env)
        return try JSONDecoder().decode([PullRequest].self, from: data)
    }

    static func issues(in dir: URL, env: [String: String] = [:]) async throws -> [GHIssue] {
        let data = try await run(["issue", "list", "--limit", "50", "--json", "number,title,url,state,author"], in: dir, env: env)
        return try JSONDecoder().decode([GHIssue].self, from: data)
    }

    static func defaultBranch(in dir: URL, env: [String: String] = [:]) async -> String? {
        let data = try? await run(["repo", "view", "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"], in: dir, env: env)
        let s = data?.utf8.trimmed ?? ""
        return s.isEmpty ? nil : s
    }
}
