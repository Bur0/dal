import Foundation
import AppKit

/// Everything about linked worktrees: status, open, lock, move, remove, prune, repair, and
/// new worktrees on a new branch. The worktrees of coding agents are ordinary worktrees with
/// a recognised location (`Worktree.agent`), so they get all of this too.
extension RepoStore {
    // MARK: Lookup

    /// The worktree this tab shows (paths compared after resolving symlinks: /tmp vs /private/tmp).
    func isCurrent(_ tree: Worktree) -> Bool {
        Self.samePath(tree.path, url.path)
    }

    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Another worktree that has `branch` checked out.
    func worktree(holding branch: String) -> Worktree? {
        worktrees.first { $0.branch == branch && !isCurrent($0) && !$0.isPrunable }
    }

    /// Git for another worktree, with this tab's identity and safety settings.
    func git(for tree: Worktree) -> Git {
        Git(dir: URL(fileURLWithPath: tree.path), env: git.env, safety: git.safety)
    }

    /// Worktree commands run from the main worktree, so removing or moving the worktree this
    /// tab shows doesn't pull the floor out from under the command.
    private var mainGit: Git {
        if let main = worktrees.first(where: \.isMain), !main.isBare { return git(for: main) }
        return git
    }

    // MARK: Status

    /// Uncommitted file counts of the other worktrees, at most every few seconds.
    func loadWorktreeStatus(force: Bool = false) async {
        if !force, let last = worktreeStatusLoadedAt, Date().timeIntervalSince(last) < 5 { return }
        worktreeStatusLoadedAt = Date()
        let trees = worktrees.filter { !$0.isBare && !$0.isPrunable }
        var counts: [String: Int] = [:]
        // Four at a time: dozens of agent worktrees mustn't flood the machine with git processes.
        let jobs = trees.prefix(60).map { (path: $0.path, git: git(for: $0)) }
        await withTaskGroup(of: (String, Int?).self) { group in
            var pending = jobs.makeIterator()
            func addNext() {
                guard let job = pending.next() else { return }
                let g = job.git, path = job.path
                group.addTask {
                    let out = try? await g.string(["status", "--porcelain", "--untracked-files=normal"])
                    return (path, out.map { $0.split(separator: "\n").count })
                }
            }
            for _ in 0..<4 { addNext() }
            for await (path, count) in group {
                if let count { counts[path] = count }
                addNext()
            }
        }
        if counts != worktreeChanges { worktreeChanges = counts }
    }

    // MARK: Open

    func openWorktree(_ tree: Worktree) {
        AppState.shared.open(URL(fileURLWithPath: tree.path))
    }

    // MARK: New worktree on a new branch

    /// "+" in the sidebar: name a new branch, pick a folder; the worktree opens in a tab.
    func promptNewWorktree(from start: String? = nil) {
        let base = start.map { String($0.prefix(7)) } ?? headBranch ?? headSha.map { String($0.prefix(7)) } ?? "HEAD"
        input = InputRequest(title: "New worktree", message: "A new branch starting at \(base), checked out in its own folder",
                             placeholder: "feature/my-branch", confirmLabel: "Choose Folder…",
                             validate: { [weak self] name in self?.branchNameProblem(name) },
                             transform: RepoStore.branchNameTyping, hint: "Spaces become dashes",
                             action: { [weak self] name in
            guard let self else { return }
            let branch = name.trimmed
            // The sheet closes before the panel can run.
            DispatchQueue.main.async { self.addWorktree(newBranch: branch, start: start ?? "HEAD") }
        })
    }

    private func addWorktree(newBranch branch: String, start: String) {
        let panel = NSSavePanel()
        panel.title = "New Worktree"
        panel.prompt = "Create"
        panel.message = "Choose a folder for \(branch)"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = "\(url.lastPathComponent)-\(branch.replacingOccurrences(of: "/", with: "-"))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        run("Create worktree", success: "Created \(branch) in \(dest.lastPathComponent)") { [self] in
            try await git.run(["worktree", "add", "-b", branch, "--end-of-options", dest.path, start])
            AppState.shared.open(dest)
        }
    }

    // MARK: Lock

    func promptLockWorktree(_ tree: Worktree) {
        input = InputRequest(title: "Lock \(tree.name)",
                             message: "A locked worktree can't be removed, moved or pruned — handy for one on a removable disk or one an agent is using.",
                             placeholder: "Reason (optional)", confirmLabel: "Lock", allowEmpty: true,
                             action: { [weak self] reason in
            guard let self else { return }
            let reason = reason.trimmed
            run("Lock worktree", success: "Locked \(tree.name)") { [self] in
                var args = ["worktree", "lock"]
                if !reason.isEmpty { args += ["--reason", reason] }
                try await self.mainGit.run(args + ["--end-of-options", tree.path])
            }
        })
    }

    func unlockWorktree(_ tree: Worktree) {
        run("Unlock worktree", success: "Unlocked \(tree.name)") { [self] in
            try await self.mainGit.run(["worktree", "unlock", "--end-of-options", tree.path])
        }
    }

    // MARK: Move

    func moveWorktree(_ tree: Worktree) {
        let panel = NSSavePanel()
        panel.title = "Move Worktree"
        panel.prompt = "Move"
        panel.message = "Choose the new location of \(tree.name)"
        panel.directoryURL = URL(fileURLWithPath: tree.path).deletingLastPathComponent()
        panel.nameFieldStringValue = tree.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url, !Self.samePath(dest.path, tree.path) else { return }
        let openTab = AppState.shared.tabs.first { Self.samePath($0.url.path, tree.path) }
        run("Move worktree", success: "Moved \(tree.name) to \(dest.lastPathComponent)") { [self] in
            try await self.mainGit.run(["worktree", "move", "--end-of-options", tree.path, dest.path])
            // A tab on the old folder now points at nothing: reopen it at the new place.
            if let openTab {
                AppState.shared.close(openTab)
                AppState.shared.open(dest)
            }
        }
    }

    // MARK: Remove

    /// Removes the worktree's folder (the branch stays). Uncommitted work is shown first and
    /// only thrown away with "Remove Anyway".
    func removeWorktree(_ tree: Worktree) {
        guard !tree.isMain else { return }
        if tree.isLocked {
            let reason = tree.lockReason.flatMap { $0.isEmpty ? nil : " (“\($0)”)" } ?? ""
            alert = AppAlert(title: "\(tree.name) is locked", message: "Unlock it first\(reason), then remove it.",
                             confirmLabel: "Unlock") { [weak self] in self?.unlockWorktree(tree) }
            return
        }
        Task {
            let changes = tree.isPrunable ? 0
                : ((try? await git(for: tree).string(["status", "--porcelain", "--untracked-files=normal"]))?
                    .split(separator: "\n").count ?? 0)
            let branchNote = tree.branch.map { " The branch \($0) stays." } ?? ""
            if changes > 0 {
                alert = AppAlert(title: "Remove \(tree.name)?",
                                 message: "It has \(changes) uncommitted \(changes == 1 ? "change" : "changes") that will be lost. The folder is deleted.\(branchNote)",
                                 confirmLabel: "Remove Anyway", destructive: true) { [weak self] in
                    self?.performRemove(tree, force: true)
                }
            } else {
                alert = AppAlert(title: "Remove \(tree.name)?",
                                 message: "The folder \(tree.path) is deleted.\(branchNote)",
                                 confirmLabel: "Remove Worktree", destructive: true) { [weak self] in
                    self?.performRemove(tree, force: false)
                }
            }
        }
    }

    private func performRemove(_ tree: Worktree, force: Bool) {
        let openTab = AppState.shared.tabs.first { Self.samePath($0.url.path, tree.path) }
        run("Remove worktree", success: "Removed \(tree.name)") { [self] in
            if tree.isPrunable {
                try await self.mainGit.run(["worktree", "prune"])
            } else {
                try await self.mainGit.run(["worktree", "remove"] + (force ? ["--force"] : []) + ["--end-of-options", tree.path])
            }
            if let openTab, openTab !== self { AppState.shared.close(openTab) }
            if openTab === self { AppState.shared.close(self) }
        }
    }

    // MARK: Prune & repair

    /// Drops the records of worktrees whose folders are gone.
    func pruneWorktrees() {
        let stale = worktrees.filter { $0.isPrunable && !$0.isLocked }.count
        run("Prune worktrees", success: stale == 0 ? "Nothing to prune" : "Pruned \(stale) stale \(stale == 1 ? "worktree" : "worktrees")") { [self] in
            try await self.mainGit.run(["worktree", "prune"])
        }
    }

    /// Re-links worktrees after their folders or the main repository were moved by hand.
    func repairWorktrees() {
        run("Repair worktrees", success: "Repaired worktree links") { [self] in
            try await self.mainGit.run(["worktree", "repair"])
        }
    }
}
