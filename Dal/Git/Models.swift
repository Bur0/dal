import Foundation

struct Commit: Identifiable, Hashable {
    let sha: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let commitDate: Date
    let subject: String
    let body: String

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
    var fullMessage: String { body.isEmpty ? subject : subject + "\n\n" + body }
}

enum RefKind: Int, Comparable {
    case localBranch, remoteBranch, tag
    static func < (a: RefKind, b: RefKind) -> Bool { a.rawValue < b.rawValue }
}

struct Ref: Identifiable, Hashable {
    let fullName: String
    let name: String
    let kind: RefKind
    let target: String
    var upstream: String?
    /// Remote and branch name the upstream lives on (e.g. "fork" / "feature"), for pushing.
    var upstreamRemote: String?
    var upstreamBranch: String?
    var ahead = 0
    var behind = 0
    var upstreamGone = false
    var isHead = false

    var id: String { fullName }

    /// "origin" for "origin/feature/x"
    var remoteName: String? {
        guard kind == .remoteBranch else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    /// "feature/x" for "origin/feature/x"
    var branchName: String {
        guard kind == .remoteBranch else { return name }
        let parts = name.split(separator: "/", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : name
    }
}

/// One label in the graph's branch/tag column. A local branch and its same-named remote
/// branches pointing at the same commit collapse into one badge.
struct RefBadge: Identifiable, Hashable {
    let id: String
    let name: String
    var local: Ref?
    var remotes: [Ref] = []
    var tag: Ref?
    var isHead = false

    var primary: Ref? { local ?? remotes.first ?? tag }
}

enum ChangeKind: String, Hashable {
    case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted

    init(code: Character) {
        switch code {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "?": self = .untracked
        case "U": self = .conflicted
        default: self = .modified
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "New"
        case .conflicted: "Conflicted"
        }
    }
}

struct FileChange: Identifiable, Hashable {
    let path: String
    var oldPath: String?
    let kind: ChangeKind
    /// Porcelain XY code for conflicts (UU, AA, DU, …)
    var conflictCode: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct WorkingStatus: Equatable {
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []
    var conflicted: [FileChange] = []

    var isEmpty: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
    var fileCount: Int { Set(staged.map(\.path) + unstaged.map(\.path) + conflicted.map(\.path)).count }
}

struct Stash: Identifiable, Hashable {
    let index: Int
    let sha: String
    let message: String
    let date: Date
    var ref: String { "stash@{\(index)}" }
    var id: String { sha }
}

struct Worktree: Identifiable, Hashable {
    let path: String
    var head: String = ""
    var branch: String?
    var isBare = false
    var isMain = false
    var isDetached = false
    /// `git worktree lock`: protected from remove / move / prune. The reason may be empty.
    var lockReason: String?
    /// Its folder is gone (or no longer a worktree); `git worktree prune` would drop it.
    var prunableReason: String?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isLocked: Bool { lockReason != nil }
    var isPrunable: Bool { prunableReason != nil }

    /// The coding agent that made this worktree, recognised by where agents put theirs
    /// (Claude Code: `<repo>/.claude/worktrees/`, Codex: `~/.codex/worktrees/`, …) or by
    /// the branch prefix they use.
    var agent: String? { Self.agent(path: path, branch: branch) }

    static func agent(path: String, branch: String?) -> String? {
        let markers: [(String, String)] = [
            ("/.claude/worktrees/", "Claude Code"),
            ("/.codex/worktrees/", "Codex"),
            ("/.cursor/worktrees/", "Cursor"),
            ("/conductor/workspaces/", "Conductor"),
            ("/.gemini/worktrees/", "Gemini"),
            ("/.windsurf/worktrees/", "Windsurf"),
        ]
        if let match = markers.first(where: { path.contains($0.0) }) { return match.1 }
        let prefixes: [(String, String)] = [("claude/", "Claude Code"), ("codex/", "Codex"), ("cursor/", "Cursor")]
        if let branch, let match = prefixes.first(where: { branch.hasPrefix($0.0) }) { return match.1 }
        return nil
    }
}

struct GHUser: Decodable, Hashable {
    let login: String
}

struct PullRequest: Identifiable, Decodable, Hashable {
    let number: Int
    let title: String
    let url: String
    let headRefName: String
    let baseRefName: String
    let isDraft: Bool
    let state: String
    let author: GHUser?
    var id: Int { number }
}

struct GHIssue: Identifiable, Decodable, Hashable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let author: GHUser?
    var id: Int { number }
}

enum OngoingOperation: Equatable {
    case merge, rebase, cherryPick, revert

    var title: String {
        switch self {
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        }
    }

    var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind: Hashable { case context, addition, deletion, noNewline }
    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    var isChange: Bool { kind == .addition || kind == .deletion }
}

struct DiffHunk: Identifiable, Hashable {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]
    var changeIDs: Set<Int> { Set(lines.filter(\.isChange).map(\.id)) }
}

struct FileDiff: Hashable {
    var header: [String] = []
    var hunks: [DiffHunk] = []
    var isBinary = false

    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
}
