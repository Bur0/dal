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
        let result = try await Shell.run("git", base + args, cwd: dir, input: input, env: self.env.merging(env) { $1 })
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
