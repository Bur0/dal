import Foundation
import AppKit

extension RepoStore {
    // MARK: Runner

    func run(_ title: String, success: String? = nil, _ body: @escaping () async throws -> Void) {
        Task { await perform(title, success: success, body) }
    }

    /// Mutating git commands run one at a time, in order: two quick clicks never race for
    /// `index.lock`, and `busy` stays set until the last queued command has finished.
    func enqueue(_ title: String, _ body: @escaping () async -> Void) async {
        let previous = operationTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.runningOperations += 1
            self.busy = title
            await body()
            self.runningOperations -= 1
            if self.runningOperations == 0 { self.busy = nil }
        }
        operationTail = task
        await task.value
    }

    func perform(_ title: String, success: String? = nil, _ body: @escaping () async throws -> Void) async {
        await enqueue(title) { [self] in
            do {
                try await body()
                await refresh(full: true)
                if let success { showToast(success) }
            } catch {
                await refresh(full: true)
                if cancelled {
                    cancelled = false
                    showToast("\(title) cancelled", warning: true)
                    return
                }
                if ongoing != nil, !status.conflicted.isEmpty {
                    showToast("\(status.conflicted.count) conflicted file\(status.conflicted.count == 1 ? "" : "s") — resolve to continue",
                              warning: true)
                    selection = .wip
                    return
                }
                alert = AppAlert(title: "\(title) failed", message: error.localizedDescription)
            }
        }
    }

    /// Stops the git/gh process behind the current operation (a stuck push, a slow hook).
    func cancelRunning() {
        cancelled = true
        ProcessRegistry.shared.terminate(tag: url.path)
    }

    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var currentPosition: String? { headBranch ?? headSha }

    // MARK: Checkout & branches

    func checkout(_ target: String) {
        let before = currentPosition
        run("Checkout", success: "Checked out \(target)") { [self] in
            try await git.run(["checkout", target, "--"])
            if let before { pushUndo(.checkout(before: before, after: target)) }
        }
    }

    func checkout(remote ref: Ref) {
        let local = ref.branchName
        if localBranches.contains(where: { $0.name == local }) {
            checkout(local)
            return
        }
        let before = currentPosition
        run("Checkout", success: "Created \(local) tracking \(ref.name)") { [self] in
            try await git.run(["checkout", "-b", local, "--track", ref.name])
            if let before { pushUndo(.checkout(before: before, after: local)) }
        }
    }

    func promptCreateBranch(at sha: String? = nil, checkout: Bool = true) {
        input = InputRequest(
            title: "Create branch",
            message: sha.map { "Starting at \(String($0.prefix(7)))" } ?? "Starting at \(headBranch ?? "HEAD")",
            placeholder: "feature/my-branch",
            confirmLabel: checkout ? "Create & Checkout" : "Create",
            validate: { [weak self] name in self?.branchNameProblem(name) },
            transform: RepoStore.branchNameTyping,
            hint: "Spaces become dashes",
            action: { [weak self] name in self?.createBranch(name.trimmed, at: sha, checkout: checkout) }
        )
    }

    /// Live clean-up while typing a branch name: spaces → dashes, no leading dash.
    static func branchNameTyping(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: " ", with: "-")
        while name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    func branchNameProblem(_ raw: String) -> String? {
        let name = raw.trimmed
        if name.isEmpty { return "" }
        if name.contains(" ") { return "Branch names can't contain spaces." }
        if name.contains("..") || name.hasSuffix("/") || name.hasSuffix(".lock") || name.hasPrefix("-") {
            return "That isn't a valid branch name."
        }
        if localBranches.contains(where: { $0.name == name }) { return "A branch with this name already exists." }
        return nil
    }

    func createBranch(_ name: String, at sha: String?, checkout: Bool) {
        let previous = checkout ? currentPosition : nil
        run("Create branch", success: "Created \(name)") { [self] in
            if checkout {
                var args = ["switch", "-c", name]
                if let sha { args.append(sha) }
                try await git.run(args)
            } else {
                try await git.run(["branch", name, sha ?? "HEAD"])
            }
            let target = try await git.string(["rev-parse", name]).trimmed
            pushUndo(.createBranch(name: name, sha: target, previous: previous))
        }
    }

    func deleteBranch(_ ref: Ref) {
        alert = AppAlert(title: "Delete branch \(ref.name)?",
                         message: "The local branch will be removed. You can undo this right after.",
                         confirmLabel: "Delete", destructive: true) { [weak self] in
            self?.deleteBranch(ref, force: false)
        }
    }

    private func deleteBranch(_ ref: Ref, force: Bool) {
        Task { await enqueue("Delete branch") { [self] in
            do {
                try await git.run(["branch", force ? "-D" : "-d", ref.name])
                pushUndo(.deleteBranch(name: ref.name, sha: ref.target))
                await refresh(full: true)
                showToast("Deleted \(ref.name)")
            } catch {
                let message = error.localizedDescription
                if !force && message.contains("not fully merged") {
                    alert = AppAlert(title: "\(ref.name) isn't fully merged",
                                     message: "Deleting it may lose commits that aren't on any other branch.",
                                     confirmLabel: "Delete Anyway", destructive: true) { [weak self] in
                        self?.deleteBranch(ref, force: true)
                    }
                } else {
                    alert = AppAlert(title: "Delete branch failed", message: message)
                }
            }
        } }
    }

    func deleteRemoteBranch(_ ref: Ref) {
        guard let remote = ref.remoteName else { return }
        alert = AppAlert(title: "Delete \(ref.name) on \(remote)?",
                         message: "This removes the branch from the remote for everyone.",
                         confirmLabel: "Delete Remote Branch", destructive: true) { [weak self] in
            guard let self else { return }
            run("Delete remote branch", success: "Deleted \(ref.name)") { [self] in
                try await self.git.run(["push", remote, "--delete", ref.branchName])
            }
        }
    }

    func promptRename(_ ref: Ref) {
        input = InputRequest(title: "Rename branch", placeholder: ref.name, initial: ref.name,
                             confirmLabel: "Rename",
                             validate: { [weak self] name in name.trimmed == ref.name ? "" : self?.branchNameProblem(name) },
                             transform: RepoStore.branchNameTyping,
                             action: { [weak self] name in
            guard let self else { return }
            run("Rename branch", success: "Renamed to \(name.trimmed)") { [self] in
                try await self.git.run(["branch", "-m", ref.name, name.trimmed])
            }
        })
    }

    func setUpstream(_ ref: Ref, to upstream: String) {
        run("Set upstream", success: "\(ref.name) now tracks \(upstream)") { [self] in
            try await git.run(["branch", "--set-upstream-to", upstream, ref.name])
        }
    }

    // MARK: Merge / rebase / cherry-pick

    private func moveHead(_ title: String, success: String, args: [String], undoMode: String = "keep") {
        let before = headSha
        let branch = headBranch
        run(title, success: success) { [self] in
            try await git.run(args)
            if let before, let after = await git.headSha(), after != before {
                pushUndo(.moveHead(before: before, after: after, label: title, mode: undoMode, branch: branch))
            }
        }
    }

    func merge(_ target: String) {
        moveHead("Merge", success: "Merged \(target) into \(headBranch ?? "HEAD")", args: ["merge", "--no-edit", target])
    }

    func rebaseCurrent(onto target: String) {
        moveHead("Rebase", success: "Rebased \(headBranch ?? "HEAD") onto \(target)", args: ["rebase", target])
    }

    /// True when `branch` is an ancestor of `target`, i.e. it can move forward without a merge.
    func canFastForward(_ branch: String, to target: String) async -> Bool {
        // Exit 0 = ancestor; 1 = not; anything else (bad ref) also means no.
        (try? await git.run(["merge-base", "--is-ancestor", "refs/heads/\(branch)", target])) != nil
    }

    func fastForward(_ branch: String, to target: String) {
        run("Fast-forward", success: "Fast-forwarded \(branch)") { [self] in
            if branch == headBranch {
                try await git.run(["merge", "--ff-only", target])
            } else {
                try await git.run(["fetch", ".", "\(target):\(branch)"])
            }
        }
    }

    /// Drag-and-drop: merge `source` into `target` (checking out target first when needed).
    func merge(_ source: String, into target: String) {
        let before = currentPosition
        run("Merge", success: "Merged \(source) into \(target)") { [self] in
            if target != headBranch {
                try await git.run(["checkout", target, "--"])
                if let before { pushUndo(.checkout(before: before, after: target)) }
            }
            let head = await git.headSha()
            try await git.run(["merge", "--no-edit", source])
            if let head, let after = await git.headSha(), after != head {
                pushUndo(.moveHead(before: head, after: after, label: "Merge", mode: "keep", branch: target))
            }
        }
    }

    func rebase(_ branch: String, onto target: String) {
        let before = currentPosition
        run("Rebase", success: "Rebased \(branch) onto \(target)") { [self] in
            let tip = try await git.string(["rev-parse", "refs/heads/\(branch)"]).trimmed
            try await git.run(["rebase", target, branch])
            if let before, before != branch { pushUndo(.checkout(before: before, after: branch)) }
            if let after = await git.headSha(), after != tip {
                pushUndo(.moveHead(before: tip, after: after, label: "Rebase", mode: "keep", branch: branch))
            }
        }
    }

    func cherryPick(_ commit: Commit) {
        var args = ["cherry-pick"]
        if commit.isMerge { args += ["-m", "1"] }
        moveHead("Cherry-pick", success: "Cherry-picked \(commit.shortSha)", args: args + [commit.sha])
    }

    func revert(_ commit: Commit) {
        var args = ["revert", "--no-edit"]
        if commit.isMerge { args += ["-m", "1"] }
        moveHead("Revert", success: "Reverted \(commit.shortSha)", args: args + [commit.sha])
    }

    func reset(to sha: String, mode: String) {
        let doReset = { [weak self] in
            guard let self else { return }
            self.moveHead("Reset", success: "Reset \(self.headBranch ?? "HEAD") to \(String(sha.prefix(7)))",
                          args: ["reset", "--\(mode)", sha], undoMode: mode == "hard" ? "keep" : mode)
        }
        _ = mode
        if mode == "hard" {
            alert = AppAlert(title: "Hard reset to \(String(sha.prefix(7)))?",
                             message: "Uncommitted changes will be discarded. Committed work stays reachable via Undo.",
                             confirmLabel: "Reset Hard", destructive: true, action: doReset)
        } else {
            doReset()
        }
    }

    func continueOperation() {
        guard let op = ongoing else { return }
        run("Continue \(op.command)", success: "\(op.command.capitalized) finished") { [self] in
            switch op {
            case .merge: try await git.run(["commit", "--no-edit"])
            default: try await git.run([op.command, "--continue"])
            }
        }
    }

    func abortOperation() {
        guard let op = ongoing else { return }
        alert = AppAlert(title: "Abort \(op.command)?", message: "Your branch returns to where it was before the \(op.command).",
                         confirmLabel: "Abort", destructive: true) { [weak self] in
            guard let self else { return }
            run("Abort \(op.command)", success: "\(op.command.capitalized) aborted") { [self] in
                try await self.git.run([op.command, "--abort"])
            }
        }
    }

    // MARK: Tags

    func promptCreateTag(at sha: String) {
        input = InputRequest(title: "Create tag", message: "At \(String(sha.prefix(7)))", placeholder: "v1.0.0",
                             confirmLabel: "Create Tag",
                             validate: { [weak self] name in
            let n = name.trimmed
            if n.isEmpty { return "" }
            if n.contains(" ") { return "Tag names can't contain spaces." }
            if self?.tags.contains(where: { $0.name == n }) == true { return "That tag already exists." }
            return nil
        }, action: { [weak self] name in
            guard let self else { return }
            run("Create tag", success: "Tagged \(name.trimmed)") { [self] in
                try await self.git.run(["tag", name.trimmed, sha])
            }
        })
    }

    func deleteTag(_ ref: Ref) {
        alert = AppAlert(title: "Delete tag \(ref.name)?", message: "Only the local tag is removed.",
                         confirmLabel: "Delete", destructive: true) { [weak self] in
            guard let self else { return }
            run("Delete tag", success: "Deleted tag \(ref.name)") { [self] in
                try await self.git.run(["tag", "-d", ref.name])
            }
        }
    }

    func pushTag(_ ref: Ref) {
        guard let remote = defaultRemote else { return }
        run("Push tag", success: "Pushed \(ref.name) to \(remote)") { [self] in
            try await git.run(["push", remote, "refs/tags/\(ref.name)"])
        }
    }

    // MARK: Remotes

    var defaultRemote: String? { remotes.contains("origin") ? "origin" : remotes.first }

    func fetch() {
        run("Fetch", success: "Fetched all remotes") { [self] in
            try await git.run(["fetch", "--all", "--prune"])
        }
        Task { await loadGitHub() }
    }

    func pull(_ mode: PullMode? = nil) {
        let mode = mode ?? PullMode(rawValue: UserDefaults.standard.string(forKey: "pullMode") ?? "") ?? .ffIfPossible
        guard let branch = headBranch else {
            alert = AppAlert(title: "Can't pull", message: "You're in detached HEAD. Check out a branch first.")
            return
        }
        guard headRef?.upstream != nil else {
            alert = AppAlert(title: "\(branch) has no upstream",
                             message: "Push the branch first, or set an upstream from the branch's context menu.")
            return
        }
        let before = headSha
        run("Pull", success: "Pulled \(branch)") { [self] in
            try await git.run(mode.args)
            if let before, let after = await git.headSha(), before != after {
                pushUndo(.moveHead(before: before, after: after, label: "Pull", mode: "keep", branch: branch))
            }
        }
    }

    func push(force: Bool = false) {
        guard let branch = headBranch else {
            alert = AppAlert(title: "Can't push", message: "You're in detached HEAD. Create a branch first.")
            return
        }
        push(branch: branch, force: force)
    }

    /// Where `git push` should send a branch: its upstream's remote and branch when it has one
    /// (fork workflows track `fork/feature`), otherwise the default remote with `-u`.
    func pushArguments(for branch: String, force: Bool) -> [String]? {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        let ref = localBranches.first { $0.name == branch }
        if let remote = ref?.upstreamRemote, remote != ".", let upstream = ref?.upstreamBranch {
            return args + [remote, "refs/heads/\(branch):refs/heads/\(upstream)"]
        }
        guard let remote = defaultRemote else { return nil }
        return args + ["-u", remote, branch]
    }

    func push(branch: String, force: Bool = false) {
        guard let args = pushArguments(for: branch, force: force) else {
            alert = AppAlert(title: "No remote", message: "Add a remote with `git remote add origin <url>` first.")
            return
        }
        Task { await enqueue("Push") { [self] in
            do {
                try await git.run(args)
                await refresh(full: true)
                let target = localBranches.first { $0.name == branch }?.upstream ?? branch
                showToast(force ? "Force pushed \(branch)" : "Pushed \(branch) → \(target)")
                Task { await loadGitHub() }
            } catch {
                await refresh(full: true)
                if cancelled { cancelled = false; showToast("Push cancelled", warning: true); return }
                let message = error.localizedDescription
                if !force && (message.contains("rejected") || message.contains("non-fast-forward")) {
                    alert = AppAlert(
                        title: "Push rejected",
                        message: "The remote has commits you don't have. Pull first, or force push (with lease) to overwrite them.\n\n\(message)",
                        confirmLabel: "Force Push", destructive: true) { [weak self] in
                        self?.push(branch: branch, force: true)
                    }
                } else {
                    alert = AppAlert(title: "Push failed", message: message)
                }
            }
        } }
    }

    // MARK: Stash

    func stash(message: String? = nil) {
        run("Stash", success: "Stashed changes") { [self] in
            var args = ["stash", "push", "--include-untracked"]
            if let message, !message.trimmed.isEmpty { args += ["-m", message.trimmed] }
            try await git.run(args)
        }
    }

    func popStash(_ stash: Stash? = nil) {
        run("Pop stash", success: "Popped \(stash?.ref ?? "stash@{0}")") { [self] in
            var args = ["stash", "pop"]
            if let stash { args.append(stash.ref) }
            try await git.run(args)
        }
    }

    func applyStash(_ stash: Stash) {
        run("Apply stash", success: "Applied \(stash.ref)") { [self] in
            try await git.run(["stash", "apply", stash.ref])
        }
    }

    func dropStash(_ stash: Stash) {
        alert = AppAlert(title: "Delete \(stash.ref)?", message: stash.message, confirmLabel: "Delete Stash",
                         destructive: true) { [weak self] in
            guard let self else { return }
            run("Delete stash", success: "Deleted \(stash.ref)") { [self] in
                try await self.git.run(["stash", "drop", stash.ref])
            }
        }
    }

    // MARK: Staging

    private var hasHead: Bool { headSha != nil }

    func stage(_ change: FileChange) {
        run("Stage") { [self] in try await git.run(["add", "-A", "--", change.path]) }
    }

    func unstage(_ change: FileChange) {
        run("Unstage") { [self] in
            if hasHead {
                var paths = [change.path]
                if let old = change.oldPath { paths.append(old) }
                try await git.run(["restore", "--staged", "--"] + paths)
            } else {
                try await git.run(["rm", "--cached", "-q", "--", change.path])
            }
        }
    }

    func stageAll() {
        run("Stage all") { [self] in try await git.run(["add", "-A"]) }
    }

    func unstageAll() {
        run("Unstage all") { [self] in
            if hasHead { try await git.run(["reset", "-q"]) } else { try await git.run(["rm", "-r", "--cached", "-q", "."]) }
        }
    }

    func discard(_ change: FileChange) {
        alert = AppAlert(title: "Discard changes to \(change.fileName)?",
                         message: change.kind == .untracked ? "The new file will be moved to the Trash."
                            : "Unstaged changes in this file will be lost.",
                         confirmLabel: "Discard", destructive: true) { [weak self] in
            guard let self else { return }
            run("Discard") { [self] in try await self.discardNow(change) }
        }
    }

    private func discardNow(_ change: FileChange) async throws {
        if change.kind == .untracked {
            try FileManager.default.trashItem(at: url.appendingPathComponent(change.path), resultingItemURL: nil)
        } else {
            try await git.run(["restore", "--", change.path])
        }
    }

    func discardAll() {
        alert = AppAlert(title: "Discard all unstaged changes?",
                         message: "Changes in tracked files are lost and new files go to the Trash. Staged changes are kept.",
                         confirmLabel: "Discard All", destructive: true) { [weak self] in
            guard let self else { return }
            let changes = status.unstaged
            run("Discard all") { [self] in
                let untracked = changes.filter { $0.kind == .untracked }
                for change in untracked { try? FileManager.default.trashItem(at: self.url.appendingPathComponent(change.path), resultingItemURL: nil) }
                if changes.contains(where: { $0.kind != .untracked }) {
                    try await self.git.run(["restore", "--", "."])
                }
            }
        }
    }

    enum HunkAction { case stage, unstage, discard }

    func apply(_ action: HunkAction, diff: FileDiff, hunk: DiffHunk, lines: Set<Int>) {
        let selected = lines.isEmpty ? hunk.changeIDs : lines
        let patch: String
        do {
            guard let built = try PatchBuilder.patch(header: diff.header, hunk: hunk, selected: selected,
                                                     reverse: action != .stage) else { return }
            patch = built
        } catch {
            alert = AppAlert(title: "Can't apply these lines", message: error.localizedDescription)
            return
        }
        let perform = { [weak self] in
            guard let self else { return }
            run(action == .stage ? "Stage lines" : action == .unstage ? "Unstage lines" : "Discard lines") { [self] in
                try await self.git.apply(patch: patch, cached: action != .discard, reverse: action != .stage)
            }
        }
        if action == .discard {
            alert = AppAlert(title: "Discard \(lines.isEmpty ? "this hunk" : "\(lines.count) selected line\(lines.count == 1 ? "" : "s")")?",
                             message: "These changes will be lost.", confirmLabel: "Discard", destructive: true,
                             action: perform)
        } else {
            perform()
        }
    }

    // MARK: Commit

    func setAmend(_ on: Bool) {
        amend = on
        guard on, commitSummary.trimmed.isEmpty, commitBody.trimmed.isEmpty else { return }
        Task {
            let message = await git.lastCommitMessage()
            let parts = message.components(separatedBy: "\n")
            commitSummary = parts.first ?? ""
            commitBody = parts.dropFirst().joined(separator: "\n").trimmed
        }
    }

    var canCommit: Bool {
        !commitSummary.trimmed.isEmpty && (amend || !status.staged.isEmpty) && status.conflicted.isEmpty && busy == nil
    }

    func commit() {
        guard canCommit else { return }
        var message = commitSummary.trimmed
        if !commitBody.trimmed.isEmpty { message += "\n\n" + commitBody.trimmed }
        let before = headSha
        let isAmend = amend
        run(isAmend ? "Amend" : "Commit", success: isAmend ? "Amended last commit" : "Committed") { [self] in
            var args = ["commit", "-F", "-"]
            if isAmend { args.append("--amend") }
            try await git.run(args, input: Data(message.utf8))
            commitSummary = ""
            commitBody = ""
            amend = false
            if let after = await git.headSha() {
                pushUndo(isAmend && before != nil
                         ? .moveHead(before: before!, after: after, label: "Amend", mode: "soft", branch: headBranch)
                         : .commit(before: before, after: after, branch: headBranch))
            }
        }
    }

    // MARK: Conflicts

    func resolveConflict(_ change: FileChange, content: String) {
        run("Resolve", success: "Resolved \(change.fileName)") { [self] in
            try content.write(to: url.appendingPathComponent(change.path), atomically: true, encoding: .utf8)
            try await git.run(["add", "--", change.path])
            fileFocus = nil
        }
    }

    func takeSide(_ change: FileChange, ours: Bool) {
        run("Resolve", success: "Took \(ours ? "current" : "incoming") version of \(change.fileName)") { [self] in
            let code = change.conflictCode ?? "UU"
            // Deleted-on-one-side conflicts have no file content for that side.
            // UA = added by them (no "ours"), AU = added by us (no "theirs").
            let deletedOurs = code == "DU" || code == "DD" || code == "UA"
            let deletedTheirs = code == "UD" || code == "DD" || code == "AU"
            if (ours && deletedOurs) || (!ours && deletedTheirs) {
                try await git.run(["rm", "-q", "--", change.path])
            } else {
                try await git.run(["checkout", ours ? "--ours" : "--theirs", "--", change.path])
                try await git.run(["add", "--", change.path])
            }
            fileFocus = nil
        }
    }

    func markResolved(_ change: FileChange) {
        run("Mark resolved", success: "Marked \(change.fileName) as resolved") { [self] in
            try await git.run(["add", "--", change.path])
            fileFocus = nil
        }
    }

    // MARK: Undo / redo

    var undoLabel: String? { undoStack.last.map { "Undo \($0.label)" } }
    var redoLabel: String? { redoStack.last.map { "Redo \($0.label)" } }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        run("Undo", success: "Undid \(action.label.lowercased())") { [self] in
            do {
                try await revert(action, undo: true)
                redoStack.append(action)
            } catch {
                undoStack.append(action)
                throw error
            }
        }
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        run("Redo", success: "Redid \(action.label.lowercased())") { [self] in
            do {
                try await revert(action, undo: false)
                undoStack.append(action)
            } catch {
                redoStack.append(action)
                throw error
            }
        }
    }

    /// Refuses to undo/redo when HEAD is no longer where the action left it — otherwise a reset
    /// would land on whatever branch is checked out now.
    private func ensureHead(_ sha: String?, branch: String?) async throws {
        let head = await git.headSha()
        let current = await git.currentBranch()
        guard head == sha, branch == nil || current == branch else {
            throw GitError(command: "undo",
                           message: "The repository changed since this action (HEAD is now \(current ?? head.map { String($0.prefix(7)) } ?? "unborn")). Nothing was changed.",
                           exitCode: 1)
        }
    }

    private func revert(_ action: UndoAction, undo: Bool) async throws {
        switch action {
        case .commit(let before, let after, let branch):
            if undo {
                try await ensureHead(after, branch: branch)
                if let before { try await git.run(["reset", "--soft", before]) }
                else { try await git.run(["update-ref", "-d", "HEAD"]) }
            } else {
                try await ensureHead(before, branch: branch)
                try await git.run(["reset", "--soft", after])
            }
        case .moveHead(let before, let after, _, let mode, let branch):
            try await ensureHead(undo ? after : before, branch: branch)
            try await git.run(["reset", "--\(mode)", undo ? before : after])
        case .checkout(let before, let after):
            let branchNow = await git.currentBranch()
            let shaNow = await git.headSha()
            let expected = undo ? after : before
            guard branchNow == expected || shaNow == expected else {
                throw GitError(command: "undo", message: "You're no longer on \(undo ? after : before). Nothing was changed.", exitCode: 1)
            }
            try await git.run(["checkout", undo ? before : after, "--"])
        case .createBranch(let name, let sha, let previous):
            if undo {
                if let previous, headBranch == name { try await git.run(["checkout", previous, "--"]) }
                // Only deletes if the branch still points where Dal created it.
                try await git.run(["update-ref", "-d", "refs/heads/\(name)", sha])
            } else if previous != nil {
                try await git.run(["switch", "-c", name, sha])
            } else {
                try await git.run(["branch", name, sha])
            }
        case .deleteBranch(let name, let sha):
            if undo { try await git.run(["branch", name, sha]) }
            else { try await git.run(["update-ref", "-d", "refs/heads/\(name)", sha]) }
        }
    }

    // MARK: GitHub

    func openCreatePR(head: String? = nil) {
        createPRHead = head ?? headBranch
        showCreatePR = true
    }

    /// Returns an error message to show in the sheet, or nil on success.
    func createPullRequest(title: String, body: String, base: String, head: String, draft: Bool) async -> String? {
        var failure: String?
        await enqueue("Create pull request") { [self] in
            failure = await createPullRequestNow(title: title, body: body, base: base, head: head, draft: draft)
        }
        return failure
    }

    private func createPullRequestNow(title: String, body: String, base: String, head: String, draft: Bool) async -> String? {
        do {
            let ref = localBranches.first { $0.name == head }
            if let ref, ref.upstream == nil || ref.ahead > 0, let args = pushArguments(for: head, force: false) {
                try await git.run(args)
            }
            var args = ["pr", "create", "--title", title, "--body", body, "--base", base, "--head", head]
            if draft { args.append("--draft") }
            let out = try await GitHub.run(args, in: url, env: githubEnv).utf8.trimmed
            if let link = out.split(separator: "\n").last, let prURL = URL(string: String(link)) {
                NSWorkspace.shared.open(prURL)
            }
            showToast("Pull request created")
            await refresh(full: true)
            await loadGitHub()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func checkoutPullRequest(_ pr: PullRequest) {
        let before = currentPosition
        run("Checkout PR", success: "Checked out #\(pr.number)") { [self] in
            _ = try await GitHub.run(["pr", "checkout", "\(pr.number)"], in: url, env: self.githubEnv)
            if let before, let after = await git.currentBranch(), after != before {
                pushUndo(.checkout(before: before, after: after))
            }
        }
    }

    // MARK: Misc

    func openTerminal() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.path]
        try? process.run()
    }

    func revealInFinder(_ path: String? = nil) {
        let target = path.map { url.appendingPathComponent($0) } ?? url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openFile(_ path: String) {
        NSWorkspace.shared.open(url.appendingPathComponent(path))
    }

    func ignore(_ change: FileChange) {
        run("Ignore", success: "Added \(change.path) to .gitignore") { [self] in
            let ignoreURL = url.appendingPathComponent(".gitignore")
            var text = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            // Anchor to the repo root and escape glob characters so only this exact file matches.
            let escaped = change.path.reduce(into: "") { out, ch in
                if "[]*?!#\\".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            text += "/" + escaped + "\n"
            try text.write(to: ignoreURL, atomically: true, encoding: .utf8)
        }
    }

    func copy(_ text: String, label: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(label)
    }
}
