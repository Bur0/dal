import Foundation
import AppKit

/// The extra actions of the commit/branch context menu: history edits, worktrees, patches,
/// web links, annotated tags and Solo.
extension RepoStore {
    // MARK: History edits

    /// Drop, move or reword a commit on the checked-out branch. Refuses when the work tree has
    /// tracked changes, an operation is in progress or the range has merges; asks first when the
    /// commit is already on a remote; leaves an Undo entry.
    func editHistory(_ edit: Git.HistoryEdit, _ commit: Commit) {
        Task {
            guard let problem = await historyProblem(edit, commit) else {
                if edit == .reword { promptReword(commit) } else { await confirmRewrite(edit, commit, message: nil) }
                return
            }
            if !problem.isEmpty { alert = AppAlert(title: Self.historyTitle(edit), message: problem) }
        }
    }

    static func historyTitle(_ edit: Git.HistoryEdit) -> String {
        switch edit {
        case .drop: "Drop commit"
        case .reword: "Edit commit message"
        case .down: "Move commit down"
        case .up: "Move commit up"
        }
    }

    /// nil = allowed. Rewording HEAD only amends the message, so it skips the tree checks.
    private func historyProblem(_ edit: Git.HistoryEdit, _ commit: Commit) async -> String? {
        if ongoing != nil { return "Finish or abort the current \(ongoing!.command) first." }
        if edit == .reword, commit.sha == headSha { return nil }
        let dirty = (try? await git.string(["status", "--porcelain", "--untracked-files=no"]))?.trimmed ?? ""
        if !dirty.isEmpty { return "Commit or stash your changes first — this rewrites the branch." }
        return await git.rewriteProblem(edit, target: commit.sha)
    }

    private func promptReword(_ commit: Commit) {
        Task {
            let current = (try? await git.string(["log", "-1", "--format=%B", "--end-of-options", commit.sha]))?.trimmed
                ?? commit.fullMessage
            input = InputRequest(title: "Edit commit message", message: "\(commit.shortSha) · \(commit.authorName)",
                                 placeholder: "Summary", initial: current, confirmLabel: "Save Message",
                                 validate: { $0.trimmed == current ? "" : nil },
                                 multiline: true,
                                 action: { [weak self] text in
                guard let self else { return }
                Task { await self.confirmRewrite(.reword, commit, message: text.trimmed) }
            })
        }
    }

    private func confirmRewrite(_ edit: Git.HistoryEdit, _ commit: Commit, message: String?) async {
        let pushed = await git.remotesContaining(commit.sha)
        let go = { [weak self] in self?.rewrite(edit, commit, message: message) ?? () }
        if pushed.isEmpty {
            if edit == .drop {
                alert = AppAlert(title: "Drop \(commit.shortSha)?",
                                 message: "“\(commit.subject)” is removed from \(headBranch ?? "HEAD") and the commits after it are replayed. You can undo this right after.",
                                 confirmLabel: "Drop Commit", destructive: true, action: go)
            } else {
                go()
            }
            return
        }
        let names = pushed.prefix(3).joined(separator: ", ") + (pushed.count > 3 ? ", …" : "")
        alert = AppAlert(title: "\(commit.shortSha) is already pushed",
                         message: "It's on \(names). After rewriting, the branch needs a force push, and anyone who pulled it will have to reset.",
                         confirmLabel: Self.historyTitle(edit), destructive: true, action: go)
    }

    private func rewrite(_ edit: Git.HistoryEdit, _ commit: Commit, message: String?) {
        let before = headSha
        let branch = headBranch
        let title = Self.historyTitle(edit)
        let success: String = switch edit {
        case .drop: "Dropped \(commit.shortSha)"
        case .reword: "Updated the message of \(commit.shortSha)"
        case .down: "Moved \(commit.shortSha) down"
        case .up: "Moved \(commit.shortSha) up"
        }
        run(title, success: success) { [self] in
            if edit == .reword, commit.sha == before, let message {
                try await git.run(["commit", "--amend", "--only", "--allow-empty", "-F", "-"], input: Data(message.utf8))
            } else {
                try await git.rewrite(edit, target: commit.sha, message: message)
            }
            if let before, let after = await git.headSha(), after != before {
                pushUndo(.moveHead(before: before, after: after, label: title, mode: "keep", branch: branch))
            }
        }
    }

    // MARK: Pull / push any branch

    /// "Pull (fast-forward if possible)": the checked-out branch pulls normally; another branch
    /// is moved forward to its upstream without checking it out (refused if it diverged).
    func pullFastForward(_ ref: Ref) {
        if ref.name == headBranch { pull(.ffIfPossible); return }
        guard let remote = ref.upstreamRemote, let upstream = ref.upstreamBranch else {
            alert = AppAlert(title: "\(ref.name) has no upstream", message: "Set an upstream from this menu first.")
            return
        }
        run("Pull", success: "Fast-forwarded \(ref.name)") { [self] in
            try await git.run(["fetch", "--end-of-options", remote, "refs/heads/\(upstream):refs/heads/\(ref.name)"])
        }
    }

    // MARK: Delete branch and remote

    func deleteBranchAndRemote(_ local: Ref, _ remote: Ref) {
        guard let remoteName = remote.remoteName else { return }
        alert = AppAlert(title: "Delete \(local.name) and \(remote.name)?",
                         message: "The local branch is removed, and the branch on \(remoteName) is removed for everyone.",
                         confirmLabel: "Delete Both", destructive: true) { [weak self] in
            guard let self else { return }
            run("Delete branches", success: "Deleted \(local.name) and \(remote.name)") { [self] in
                try await self.git.run(["push", remoteName, "--delete", "refs/heads/\(remote.branchName)"])
                try await self.git.run(["branch", "-D", "--end-of-options", local.name])
                self.pushUndo(.deleteBranch(name: local.name, sha: local.target))
            }
        }
    }

    // MARK: Worktrees

    /// Asks where to put the new working tree, creates it and opens it in a tab.
    /// A remote branch gets a local tracking branch (unless one exists); a commit is detached.
    func createWorktree(ref: Ref?, sha: String) {
        let panel = NSSavePanel()
        panel.title = "Create Worktree"
        panel.prompt = "Create"
        panel.message = "Choose a folder for the new working tree"
        panel.directoryURL = url.deletingLastPathComponent()
        let label = ref?.branchName ?? String(sha.prefix(7))
        panel.nameFieldStringValue = "\(url.lastPathComponent)-\(label.replacingOccurrences(of: "/", with: "-"))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let path = dest.path
        run("Create worktree", success: "Created worktree at \(dest.lastPathComponent)") { [self] in
            var args = ["worktree", "add"]
            switch ref?.kind {
            case .localBranch?:
                args += ["--end-of-options", path, ref!.name]
            case .remoteBranch? where !localBranches.contains(where: { $0.name == ref!.branchName }):
                args += ["--track", "-b", ref!.branchName, "--end-of-options", path, ref!.fullName]
            default:
                args += ["--detach", "--end-of-options", path, sha]
            }
            try await git.run(args)
            AppState.shared.open(dest)
        }
    }

    // MARK: Patches

    func createPatch(_ commit: Commit) {
        let panel = NSSavePanel()
        panel.title = "Create Patch"
        let slug = commit.subject.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(50)
        panel.nameFieldStringValue = "\(commit.shortSha)-\(slug).patch"
        panel.allowedContentTypes = [.init(filenameExtension: "patch") ?? .plainText]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                try await git.formatPatch(commit.sha).write(to: dest)
                showToast("Saved \(dest.lastPathComponent)")
            } catch {
                alert = AppAlert(title: "Create patch failed", message: error.localizedDescription)
            }
        }
    }

    /// A mailbox patch (from format-patch) becomes a commit; a plain diff lands in the work tree.
    func applyPatch() {
        let panel = NSOpenPanel()
        panel.title = "Apply Patch"
        panel.prompt = "Apply"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let before = headSha
        let branch = headBranch
        run("Apply patch", success: "Applied \(file.lastPathComponent)") { [self] in
            try await git.applyPatch(at: file)
            if let before, let after = await git.headSha(), after != before {
                pushUndo(.moveHead(before: before, after: after, label: "Apply patch", mode: "keep", branch: branch))
            }
        }
    }

    // MARK: Links

    /// The web page of a branch: a local branch uses its upstream, a remote branch its remote.
    func copyBranchLink(_ ref: Ref) {
        let remote: String?, branch: String
        switch ref.kind {
        case .remoteBranch: remote = ref.remoteName; branch = ref.branchName
        default: remote = ref.upstreamRemote ?? defaultRemote; branch = ref.upstreamBranch ?? ref.name
        }
        copyWebLink(remote: remote, label: "Copied link to \(ref.name)") { RemoteWeb.branch($0, branch) }
    }

    func copyCommitLink(_ commit: Commit) {
        Task {
            // Prefer a remote that has the commit, so the link isn't a 404.
            let containing = await git.remotesContaining(commit.sha).compactMap { $0.split(separator: "/").first.map(String.init) }
            let remote = containing.first(where: { $0 == defaultRemote }) ?? containing.first ?? defaultRemote
            copyWebLink(remote: remote, label: "Copied link to \(commit.shortSha)") { RemoteWeb.commit($0, commit.sha) }
        }
    }

    private func copyWebLink(remote: String?, label: String, _ make: @escaping (String) -> URL?) {
        Task {
            guard let remote, let remoteURL = await git.remoteURL(remote), let link = make(remoteURL) else {
                alert = AppAlert(title: "No web link", message: "This repository has no remote with a web address.")
                return
            }
            copy(link.absoluteString, label: label)
        }
    }

    // MARK: Annotated tags

    func promptCreateAnnotatedTag(at sha: String) {
        input = InputRequest(title: "Create annotated tag", message: "At \(String(sha.prefix(7)))", placeholder: "v1.0.0",
                             confirmLabel: "Next",
                             validate: { [weak self] name in self?.tagNameProblem(name) },
                             action: { [weak self] name in
            guard let self else { return }
            let tag = name.trimmed
            // The sheet closes before the next one can be shown.
            DispatchQueue.main.async {
                self.input = InputRequest(title: "Message for \(tag)", placeholder: "Release notes", confirmLabel: "Create Tag",
                                          multiline: true,
                                          action: { [weak self] message in
                    guard let self else { return }
                    run("Create tag", success: "Tagged \(tag)") { [self] in
                        try await self.git.run(["tag", "-a", "-F", "-", "--end-of-options", tag, sha], input: Data(message.trimmed.utf8))
                    }
                })
            }
        })
    }

    func tagNameProblem(_ name: String) -> String? {
        let n = name.trimmed
        if n.isEmpty { return "" }
        if n.contains(" ") { return "Tag names can't contain spaces." }
        if n.hasPrefix("-") { return "Tag names can't start with a dash." }
        if tags.contains(where: { $0.name == n }) { return "That tag already exists." }
        return nil
    }

    // MARK: Solo

    /// Shows only these refs' history in the graph (GitKraken's "Solo").
    func solo(_ refs: [Ref], label: String) {
        soloRefs = refs.map(\.fullName)
        soloLabel = label
        Task { await refresh(full: true) }
    }

    func clearSolo() {
        soloRefs = nil
        soloLabel = nil
        Task { await refresh(full: true) }
    }
}
