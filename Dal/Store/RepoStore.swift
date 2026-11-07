import Foundation
import AppKit
import Observation

enum Selection: Hashable {
    case wip
    case commit(String)
}

enum FileFocus: Hashable {
    case working(FileChange, staged: Bool)
    case commit(sha: String, parent: String?, change: FileChange)
    case conflict(FileChange)

    var change: FileChange {
        switch self {
        case .working(let c, _): c
        case .commit(_, _, let c): c
        case .conflict(let c): c
        }
    }
}

struct GraphItem: Identifiable {
    let id: String
    let commit: Commit?
    let row: GraphRow
    var isWIP: Bool { commit == nil }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String? = nil
    var destructive = false
    var action: (() -> Void)? = nil
}

struct InputRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String? = nil
    var placeholder: String
    var initial: String = ""
    var confirmLabel: String
    var validate: ((String) -> String?)? = nil
    var action: (String) -> Void
}

struct DropRequest: Identifiable {
    let id = UUID()
    let source: String
    let target: String
    var canFastForward = false
}

enum PullMode: String, CaseIterable, Identifiable {
    case ffIfPossible, ffOnly, rebase
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ffIfPossible: "Pull (fast-forward if possible)"
        case .ffOnly: "Pull (fast-forward only)"
        case .rebase: "Pull (rebase)"
        }
    }
    var args: [String] {
        switch self {
        case .ffIfPossible: ["pull", "--no-rebase", "--ff"]
        case .ffOnly: ["pull", "--ff-only"]
        case .rebase: ["pull", "--rebase"]
        }
    }
}

enum UndoAction {
    case commit(before: String?, after: String, branch: String?)
    /// `mode` is the `git reset` mode used to go back (soft for amend, keep for merges…).
    case moveHead(before: String, after: String, label: String, mode: String, branch: String?)
    case checkout(before: String, after: String)
    case createBranch(name: String, sha: String, previous: String?)
    case deleteBranch(name: String, sha: String)

    var label: String {
        switch self {
        case .commit: "Commit"
        case .moveHead(_, _, let label, _, _): label
        case .checkout(_, let after): "Checkout \(after)"
        case .createBranch(let name, _, _): "Create branch \(name)"
        case .deleteBranch(let name, _): "Delete branch \(name)"
        }
    }
}

@MainActor
@Observable
final class RepoStore: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }

    /// Git bound to this repository with the active profile applied.
    var git: Git { Git(dir: url, env: ProfileStore.shared.environment(for: url.path)) }
    var githubEnv: [String: String] { ProfileStore.shared.environment(for: url.path) }

    // Repository data
    var commits: [Commit] = []
    var items: [GraphItem] = []
    @ObservationIgnored var commitIndex: [String: Int] = [:]
    @ObservationIgnored var itemIndex: [String: Int] = [:]
    var laneCount = 1
    var refs: [Ref] = []
    var badges: [String: [RefBadge]] = [:]
    var headBranch: String?
    var headSha: String?
    var status = WorkingStatus()
    var stashes: [Stash] = []
    var worktrees: [Worktree] = []
    var remotes: [String] = []
    var ongoing: OngoingOperation?
    var gitDir: URL?

    // GitHub
    var pullRequests: [PullRequest] = []
    var issues: [GHIssue] = []
    var githubError: String?
    var githubLoading = false
    @ObservationIgnored var githubStale = false

    // UI state
    var selection: Selection? = .wip
    var fileFocus: FileFocus?
    var scrollTarget: String?
    var scrollCentered = true
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    /// Commits matching `searchText`, newest first, and the same as a set for row lookups.
    var searchMatches: [String] = []
    @ObservationIgnored var searchMatchSet: Set<String> = []
    var busy: String?
    var alert: AppAlert?
    var input: InputRequest?
    var drop: DropRequest?
    var toast: String?
    var toastWarning = false
    var showCreatePR = false
    var createPRHead: String?
    var loaded = false
    var refreshVersion = 0

    // Commit composer
    var commitSummary = ""
    var commitBody = ""
    var amend = false

    // Paging
    var limit = UserDefaults.standard.integer(forKey: "commitLimit").nonZero ?? 2000
    var hasMore = false

    // Undo
    var undoStack: [UndoAction] = []
    var redoStack: [UndoAction] = []

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFull = false
    @ObservationIgnored private var queuedFull = false
    @ObservationIgnored private var logFingerprint = ""
    @ObservationIgnored private var watchedGitDirs: [String] = []
    @ObservationIgnored var loadingMore = false
    // Operation queue (see enqueue in RepoStore+Actions)
    @ObservationIgnored var operationTail: Task<Void, Never>?
    @ObservationIgnored var runningOperations = 0
    @ObservationIgnored var cancelled = false

    init(url: URL) {
        self.url = url
    }

    // MARK: Lifecycle

    /// Called when the tab becomes visible: watch the disk and bring data up to date.
    func activate() {
        guard watcher == nil else { return }
        let firstLoad = !loaded
        startWatching()
        Task {
            await refresh(full: true)
            // Linked worktrees and submodules keep their git dir elsewhere; watch it too so
            // commits and checkouts made in Terminal show up.
            if watchedGitDirs.isEmpty, let dirs = await gitDirectories(), !dirs.isEmpty {
                watchedGitDirs = dirs
                if watcher != nil { startWatching() }
            }
            if firstLoad { await loadGitHub() }
        }
    }

    private func startWatching() {
        watcher?.stop()
        let gitPaths = watchedGitDirs
        watcher = FileWatcher(paths: [url.path] + gitPaths) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
    }

    private func gitDirectories() async -> [String]? {
        let out = try? await git.string(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"])
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return out.map { Array(Set($0.split(separator: "\n").map(String.init))).filter { !$0.hasPrefix(root) } }
    }

    /// Edits in the working tree only need `git status`; changes under .git (refs, HEAD, index)
    /// need a full refresh.
    private func filesChanged(_ paths: [String]) {
        let gitDirs = ([gitDir?.path].compactMap { $0 } + watchedGitDirs).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let touchesGit = paths.contains { path in
            path.contains("/.git/") || path.hasSuffix("/.git") || gitDirs.contains { path.hasPrefix($0) }
        }
        scheduleRefresh(full: touchesGit)
    }

    /// Called when the tab goes to the background: stop watching to keep many open tabs cheap.
    func deactivate() {
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
    }

    func scheduleRefresh(full: Bool = true) {
        if full { pendingFull = true }
        guard busy == nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let full = self.pendingFull
            self.pendingFull = false
            await self.refresh(full: full)
        }
    }

    func refresh(full: Bool = true) async {
        if refreshing {
            refreshQueued = true
            queuedFull = queuedFull || full
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshQueued {
                refreshQueued = false
                let full = queuedFull
                queuedFull = false
                Task { await refresh(full: full) }
            }
        }
        if !full && loaded {
            await refreshStatus()
            return
        }
        do {
            if gitDir == nil { gitDir = try await git.gitDir() }
            async let refsTask = git.refs()
            async let statusTask = git.status()
            async let stashTask = git.stashes()
            async let worktreeTask = git.worktrees()
            async let remotesTask = git.remotes()
            async let headTask = git.headSha()
            async let branchTask = git.currentBranch()

            let newRefs = try await refsTask
            let newHead = await headTask
            // `git log` is the expensive part; skip it when no ref, HEAD or page size moved.
            let fingerprint = newRefs.map { $0.fullName + $0.target }.joined(separator: ",") + "|\(newHead ?? "")|\(limit)"
            let newCommits: [Commit]
            if newRefs.isEmpty && newHead == nil {
                newCommits = []
            } else if fingerprint == logFingerprint && !commits.isEmpty {
                newCommits = commits
            } else {
                newCommits = try await git.log(limit: limit, includeHead: newHead != nil)
            }
            logFingerprint = fingerprint

            let newStatus = try await statusTask
            let newStashes = (try? await stashTask) ?? []
            let newWorktrees = (try? await worktreeTask) ?? []
            let newRemotes = (try? await remotesTask) ?? []
            let newBranch = await branchTask
            let newOngoing = detectOngoing()

            // Only write values that changed: every write invalidates the views that read it,
            // and file-system events trigger refreshes often.
            let graphChanged = newCommits != commits || newHead != headSha
                || newStatus.isEmpty != status.isEmpty || newOngoing != ongoing
            let statusChanged = newStatus != status
            update(\.stashes, newStashes)
            update(\.worktrees, newWorktrees)
            update(\.remotes, newRemotes)
            update(\.headBranch, newBranch)
            update(\.headSha, newHead)
            if newRefs != refs {
                refs = newRefs
                badges = Parse.badges(newRefs)
            }
            update(\.status, newStatus)
            update(\.ongoing, newOngoing)
            if newCommits != commits {
                commits = newCommits
                commitIndex = Dictionary(newCommits.enumerated().map { ($1.sha, $0) }, uniquingKeysWith: { a, _ in a })
                if !searchText.trimmed.isEmpty { runSearch() }
            }
            update(\.hasMore, newCommits.count >= limit)
            loadingMore = false
            if graphChanged || items.isEmpty { rebuildGraph() }
            validateSelection()
            update(\.loaded, true)
            if statusChanged || graphChanged { refreshVersion += 1 }
        } catch {
            loaded = true
            loadingMore = false
            alert = AppAlert(title: "Couldn't read repository", message: error.localizedDescription)
        }
    }

    /// Cheap refresh for working-tree edits: status (and the WIP row) only.
    private func refreshStatus() async {
        guard let newStatus = try? await git.status() else { return }
        let newOngoing = detectOngoing()
        let graphChanged = newStatus.isEmpty != status.isEmpty || newOngoing != ongoing
        let statusChanged = newStatus != status
        update(\.status, newStatus)
        update(\.ongoing, newOngoing)
        if graphChanged { rebuildGraph() }
        if statusChanged || graphChanged {
            validateSelection()
            refreshVersion += 1
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    private func runSearch() {
        let q = searchText.trimmed
        guard !q.isEmpty else {
            searchMatchSet = []
            update(\.searchMatches, [])
            return
        }
        let lower = q.lowercased()
        let matches = commits.filter { commit in
            commit.sha.hasPrefix(lower)
                || commit.subject.localizedCaseInsensitiveContains(q)
                || commit.authorName.localizedCaseInsensitiveContains(q)
                || commit.body.localizedCaseInsensitiveContains(q)
                || (badges[commit.sha]?.contains { $0.name.localizedCaseInsensitiveContains(q) } ?? false)
        }.map(\.sha)
        searchMatchSet = Set(matches)
        update(\.searchMatches, matches)
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<RepoStore, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func loadMore() {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        limit += 2000
        Task { await refresh(full: true) }
    }

    private func rebuildGraph() {
        var nodes = commits.map { GraphLayout.Node(id: $0.sha, parents: $0.parents) }
        let showWIP = !status.isEmpty || ongoing != nil
        if showWIP {
            nodes.insert(GraphLayout.Node(id: "WIP", parents: headSha.map { [$0] } ?? []), at: 0)
        }
        let layout = GraphLayout.compute(nodes)
        var result: [GraphItem] = []
        result.reserveCapacity(nodes.count)
        var offset = 0
        if showWIP {
            result.append(GraphItem(id: "WIP", commit: nil, row: layout.rows[0]))
            offset = 1
        }
        for (i, commit) in commits.enumerated() {
            result.append(GraphItem(id: commit.sha, commit: commit, row: layout.rows[i + offset]))
        }
        items = result
        itemIndex = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        laneCount = layout.width
    }

    private func validateSelection() {
        if case .commit(let sha) = selection, commitIndex[sha] == nil,
           !stashes.contains(where: { $0.sha == sha }) {
            selection = .wip
            fileFocus = nil
        }
        if case .working(let change, let staged) = fileFocus {
            let list = staged ? status.staged : status.unstaged
            if !list.contains(where: { $0.path == change.path }) {
                // The file moved between lists (e.g. it was staged); follow it when possible.
                let other = staged ? status.unstaged : status.staged
                if let moved = other.first(where: { $0.path == change.path }) {
                    fileFocus = .working(moved, staged: !staged)
                } else {
                    fileFocus = nil
                }
            }
        }
        if case .conflict(let change) = fileFocus, !status.conflicted.contains(where: { $0.path == change.path }) {
            fileFocus = nil
        }
    }

    private func detectOngoing() -> OngoingOperation? {
        guard let gitDir else { return nil }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    // MARK: Derived

    var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch } }
    var tags: [Ref] { refs.filter { $0.kind == .tag } }
    var headRef: Ref? { localBranches.first { $0.isHead } }

    func commit(_ sha: String) -> Commit? {
        guard let i = commitIndex[sha], i < commits.count else { return nil }
        return commits[i]
    }

    func laneColor(for sha: String) -> Int {
        guard let i = itemIndex[sha], i < items.count else { return 0 }
        return items[i].row.color
    }

    func matchesSearch(_ commit: Commit) -> Bool {
        searchText.trimmed.isEmpty || searchMatchSet.contains(commit.sha)
    }

    func nextMatch(backwards: Bool = false) {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        var index = 0
        if case .commit(let sha) = selection, let current = matches.firstIndex(of: sha) {
            index = backwards ? (current - 1 + matches.count) % matches.count : (current + 1) % matches.count
        }
        select(commit: matches[index], scroll: true)
    }

    func select(commit sha: String, scroll: Bool = false) {
        selection = .commit(sha)
        fileFocus = nil
        if scroll { scrollCentered = true; scrollTarget = sha }
    }

    func selectWIP() {
        selection = .wip
        fileFocus = nil
        scrollCentered = true
        scrollTarget = items.first?.id
    }

    /// Moves selection one row up or down in the graph (keyboard navigation).
    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let currentID: String? = {
            switch selection {
            case .wip: return "WIP"
            case .commit(let sha): return sha
            case nil: return nil
            }
        }()
        let index = currentID.flatMap { itemIndex[$0] } ?? -1
        let next = min(max(index + delta, 0), items.count - 1)
        let item = items[next]
        if item.isWIP { selection = .wip } else { selection = .commit(item.id) }
        fileFocus = nil
        scrollCentered = false
        scrollTarget = item.id
    }

    func showToast(_ text: String, warning: Bool = false) {
        toastWarning = warning
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: GitHub

    func loadGitHub() async {
        guard remotes.contains(where: { _ in true }) else { return }
        githubLoading = true
        defer { githubLoading = false }
        do {
            async let prs = GitHub.pullRequests(in: url, env: githubEnv)
            async let iss = GitHub.issues(in: url, env: githubEnv)
            pullRequests = try await prs
            issues = (try? await iss) ?? []
            githubError = nil
        } catch {
            githubError = error.localizedDescription
        }
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
