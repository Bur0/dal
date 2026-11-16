import SwiftUI

/// Branch names grouped into folders by "/" (feature/login → feature ▸ login).
struct BranchNode: Identifiable, Hashable {
    let id: String
    let name: String
    var ref: Ref?
    var children: [BranchNode]?

    var containsHead: Bool {
        (ref?.isHead ?? false) || (children ?? []).contains(where: \.containsHead)
    }

    static func tree(_ refs: [Ref], nameOf: (Ref) -> String) -> [BranchNode] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var leaves: [Ref] = []
        }
        let root = Folder()
        for ref in refs {
            let parts = nameOf(ref).split(separator: "/").map(String.init)
            var folder = root
            for part in parts.dropLast() {
                if folder.folders[part] == nil { folder.folders[part] = Folder() }
                folder = folder.folders[part]!
            }
            folder.leaves.append(ref)
        }
        func build(_ folder: Folder, prefix: String) -> [BranchNode] {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
                BranchNode(id: "dir:" + prefix + key, name: key, ref: nil,
                           children: build(folder.folders[key]!, prefix: prefix + key + "/"))
            }
            let leaves = folder.leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { ref in
                BranchNode(id: ref.fullName, name: String(nameOf(ref).split(separator: "/").last ?? ""), ref: ref, children: nil)
            }
            return folders + leaves
        }
        return build(root, prefix: "")
    }
}

struct SidebarView: View {
    @Bindable var store: RepoStore
    @State private var filter = ""
    @AppStorage("sidebar.local") private var localOpen = true
    @AppStorage("sidebar.remote") private var remoteOpen = true
    @AppStorage("sidebar.stash") private var stashOpen = true
    @AppStorage("sidebar.tags") private var tagsOpen = false
    @AppStorage("sidebar.worktrees") private var worktreesOpen = false
    @AppStorage("sidebar.prs") private var prsOpen = true
    @AppStorage("sidebar.issues") private var issuesOpen = false

    private func matches(_ text: String) -> Bool {
        filter.trimmed.isEmpty || text.localizedCaseInsensitiveContains(filter.trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onExitCommand { filter = "" }
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.mutedText)
                        .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
            .padding(8)

            List {
                Section(isExpanded: forced($localOpen)) {
                    let locals = store.localBranches.filter { matches($0.name) }
                    // A checked-out branch inside a folder (feature/x) would hide in a collapsed
                    // folder; keep it on top so "where am I" never needs a click.
                    if let head = store.headRef, head.name.contains("/"), filter.isEmpty {
                        BranchRow(store: store, node: BranchNode(id: "current:" + head.fullName, name: head.name, ref: head))
                    }
                    OutlineGroup(BranchNode.tree(locals, nameOf: \.name), children: \.children) { node in
                        BranchRow(store: store, node: node)
                    }
                    if locals.isEmpty { emptyRow(filter.isEmpty ? "No branches" : "No matches") }
                } header: {
                    header("Local", count: store.localBranches.count, symbol: "laptopcomputer")
                }

                Section(isExpanded: forced($remoteOpen)) {
                    ForEach(store.remotes, id: \.self) { remote in
                        let refs = store.remoteBranches.filter { $0.remoteName == remote && matches($0.name) }
                        DisclosureGroup {
                            OutlineGroup(BranchNode.tree(refs, nameOf: \.branchName), children: \.children) { node in
                                BranchRow(store: store, node: node)
                            }
                        } label: {
                            Label(remote, systemImage: "server.rack")
                                .font(.system(size: 12))
                                .contextMenu {
                                    Button("Fetch \(remote)") {
                                        store.run("Fetch", success: "Fetched \(remote)") { try await store.git.run(["fetch", remote, "--prune"]) }
                                    }
                                }
                        }
                    }
                    if store.remotes.isEmpty { emptyRow("No remotes") }
                } header: {
                    header("Remote", count: store.remotes.count, symbol: "cloud")
                }

                Section(isExpanded: forced($stashOpen)) {
                    ForEach(store.stashes.filter { matches($0.message) }) { stash in
                        StashRow(store: store, stash: stash)
                    }
                    if store.stashes.isEmpty { emptyRow("No stashes") }
                } header: {
                    header("Stashes", count: store.stashes.count, symbol: "tray.full")
                }

                Section(isExpanded: forced($tagsOpen)) {
                    ForEach(store.tags.filter { matches($0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }) { tag in
                        SidebarItem(symbol: "tag", title: tag.name, selected: false,
                                    highlighted: store.selection == .commit(tag.target)) {
                            store.select(commit: tag.target, scroll: true)
                        }
                        .contextMenu { BadgeMenu(store: store, badge: RefBadge(id: tag.fullName, name: tag.name, tag: tag)) }
                    }
                    if store.tags.isEmpty { emptyRow("No tags") }
                } header: {
                    header("Tags", count: store.tags.count, symbol: "tag")
                }

                Section(isExpanded: forced($worktreesOpen)) {
                    let trees = store.worktrees.filter { matches($0.name) || matches($0.branch ?? "") || matches($0.agent ?? "") }
                    ForEach(trees.filter { $0.agent == nil }) { tree in
                        WorktreeRow(store: store, tree: tree)
                    }
                    let agentTrees = trees.filter { $0.agent != nil }
                    if !agentTrees.isEmpty {
                        // Worktrees made by coding agents (Claude Code, Codex, Cursor…), kept apart
                        // so a dozen agent runs don't bury your own.
                        Text("Agents").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.mutedText)
                            .padding(.leading, 20).padding(.top, 4)
                        ForEach(agentTrees) { tree in
                            WorktreeRow(store: store, tree: tree)
                        }
                    }
                } header: {
                    HStack {
                        header("Worktrees", count: store.worktrees.count, symbol: "square.stack.3d.up")
                        Spacer()
                        Button { store.promptNewWorktree() } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain)
                            .help("New worktree on a new branch")
                            .accessibilityLabel("New worktree")
                            .disabled(store.headSha == nil)
                        Menu {
                            Button("New Worktree…") { store.promptNewWorktree() }
                            Divider()
                            Button("Prune Stale Worktrees") { store.pruneWorktrees() }
                            Button("Repair Worktree Links") { store.repairWorktrees() }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Worktree actions")
                            .accessibilityLabel("Worktree actions")
                    }
                }

                Section(isExpanded: forced($prsOpen)) {
                    if let error = store.githubError {
                        githubHint(error)
                    } else {
                        ForEach(store.pullRequests.filter { matches($0.title) || matches($0.headRefName) }) { pr in
                            PullRequestRow(store: store, pr: pr)
                        }
                        if store.pullRequests.isEmpty {
                            emptyRow(store.githubLoading ? "Loading…" : "No open pull requests")
                        }
                    }
                } header: {
                    HStack {
                        header("Pull requests", count: store.pullRequests.count, symbol: "arrow.triangle.pull")
                        Spacer()
                        Button { store.openCreatePR() } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain)
                            .help("Create pull request")
                            .accessibilityLabel("Create pull request")
                            .disabled(store.headBranch == nil)
                        Button { Task { await store.loadGitHub() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                            .help("Reload from GitHub")
                            .accessibilityLabel("Reload pull requests")
                    }
                }

                Section(isExpanded: forced($issuesOpen)) {
                    if store.githubError == nil {
                        ForEach(store.issues.filter { matches($0.title) }) { issue in
                            SidebarItem(symbol: "smallcircle.filled.circle", title: issue.title,
                                        detail: "#\(issue.number)", selected: false) {
                                if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                            }
                            .help("Open #\(issue.number) on GitHub")
                        }
                        if store.issues.isEmpty { emptyRow("No open issues") }
                    } else {
                        emptyRow("GitHub unavailable")
                    }
                } header: {
                    header("Issues", count: store.issues.count, symbol: "smallcircle.filled.circle")
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            // The sidebar list style is translucent and tints with the desktop wallpaper;
            // keep it opaque like the other panes.
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
            .environment(\.defaultMinListRowHeight, 24)
        }
    }

    /// While filtering, every section is shown expanded so matches aren't hidden.
    private func forced(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { filter.trimmed.isEmpty ? binding.wrappedValue : true },
                set: { binding.wrappedValue = $0 })
    }

    /// Section headers are plain text, like Finder's sidebar: the rows carry the icons.
    private func header(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if count > 0 {
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.mutedText)
            }
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private func emptyRow(_ text: String) -> some View {
        // Lines up with item labels (icon column 14 + gap 6).
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.mutedText).padding(.leading, 20)
    }

    private func githubHint(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitHub isn't connected").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
            Text(error.contains("auth login") || error.contains("not logged")
                 ? "Run `gh auth login` in Terminal, then reload."
                 : error.contains("No such file") || error.contains("not found")
                 ? "Install the GitHub CLI: `brew install gh`"
                 : error)
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedText)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Rows

private struct SidebarItem: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var trailing: AnyView? = nil
    let selected: Bool
    var bold = false
    var highlighted = false
    var double: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(selected ? Color.accentColor : Theme.secondaryText)
            Text(title)
                .font(.system(size: 12, weight: bold ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 2)
            if let trailing { trailing }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.mutedText).lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor.opacity(0.2) : .clear))
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onClick(action, double: double)
    }
}

private struct BranchRow: View {
    let store: RepoStore
    let node: BranchNode

    var body: some View {
        if let ref = node.ref {
            let tree = ref.kind == .localBranch ? store.worktree(holding: ref.name) : nil
            SidebarItem(symbol: ref.isHead ? "checkmark.circle.fill" : ref.kind == .remoteBranch ? "cloud" : "arrow.triangle.branch",
                        title: node.name,
                        trailing: AnyView(HStack(spacing: 4) {
                            if let tree {
                                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(Theme.mutedText)
                                    .help("Checked out in worktree “\(tree.name)”")
                            }
                            TrackingPill(ref: ref)
                        }),
                        selected: ref.isHead, bold: ref.isHead,
                        highlighted: store.selection == .commit(ref.target),
                        double: {
                            if ref.kind == .remoteBranch { store.checkout(remote: ref) }
                            else if let tree { store.openWorktree(tree) }
                            else if !ref.isHead { store.checkout(ref.name) }
                        }) {
                store.select(commit: ref.target, scroll: true)
            }
            .help(ref.kind == .remoteBranch ? "\(ref.name)\nDouble-click to check out" :
                    "\(ref.name)\(ref.upstream.map { " → \($0)" } ?? "")\n"
                    + (tree.map { "Checked out in worktree “\($0.name)” — double-click to open it" } ?? "Double-click to check out"))
            .draggable(ref.name)
            .contextMenu {
                if ref.kind == .remoteBranch {
                    BadgeMenu(store: store, badge: RefBadge(id: ref.fullName, name: ref.name, remotes: [ref]))
                } else {
                    BadgeMenu(store: store, badge: RefBadge(id: ref.fullName, name: ref.name, local: ref, isHead: ref.isHead))
                }
            }
        } else {
            HStack(spacing: 6) {
                Label(node.name, systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                if node.containsHead {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help("The checked-out branch is in this folder")
                }
            }
        }
    }
}

/// One worktree: folder, branch, uncommitted count, ahead/behind, lock and missing-folder state.
private struct WorktreeRow: View {
    let store: RepoStore
    let tree: Worktree

    private var changes: Int { store.worktreeChanges[tree.path] ?? 0 }
    private var branchRef: Ref? { tree.branch.flatMap { name in store.localBranches.first { $0.name == name } } }

    private var symbol: String {
        if tree.isPrunable { return "exclamationmark.triangle" }
        if tree.isLocked { return "lock" }
        if tree.isMain { return "folder.fill" }
        return "folder"
    }

    /// "app-feature-x" next to a repository called "app" reads as "feature-x".
    private var displayName: String {
        guard !tree.isMain, let main = store.worktrees.first(where: \.isMain)?.name else { return tree.name }
        for separator in ["-", "_", "."] where tree.name.hasPrefix(main + separator) && tree.name.count > main.count + 1 {
            return String(tree.name.dropFirst(main.count + 1))
        }
        return tree.name
    }

    private var detail: String {
        if tree.isBare { return "bare" }
        if tree.isPrunable { return "missing" }
        return tree.branch ?? "detached @ \(String(tree.head.prefix(7)))"
    }

    private var helpText: String {
        var lines = [tree.path]
        if let agent = tree.agent { lines.append("Made by \(agent)") }
        if let reason = tree.lockReason { lines.append(reason.isEmpty ? "Locked" : "Locked: \(reason)") }
        if let reason = tree.prunableReason { lines.append("Folder is gone\(reason.isEmpty ? "" : " (\(reason))") — prune to clean up") }
        if changes > 0 { lines.append("\(changes) uncommitted \(changes == 1 ? "change" : "changes")") }
        if !store.isCurrent(tree) && !tree.isPrunable { lines.append("Double-click to open in a new tab") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        SidebarItem(symbol: symbol, title: displayName, detail: detail,
                    trailing: AnyView(trailing), selected: store.isCurrent(tree),
                    double: tree.isPrunable ? nil : { store.openWorktree(tree) }) {}
            .foregroundStyle(tree.isPrunable ? Theme.mutedText : Color.primary)
            .help(helpText)
            .contextMenu { menu }
    }

    private var trailing: some View {
        HStack(spacing: 4) {
            if changes > 0 {
                HStack(spacing: 2) {
                    Circle().fill(Theme.modified).frame(width: 5, height: 5)
                    Text("\(changes)")
                }
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            }
            if let branchRef { TrackingPill(ref: branchRef) }
        }
    }

    @ViewBuilder private var menu: some View {
        if !tree.isPrunable {
            Button(store.isCurrent(tree) ? "Open (This Tab)" : "Open in New Tab") { store.openWorktree(tree) }
                .disabled(store.isCurrent(tree))
            Button("Open in Terminal") { store.openTerminal(at: tree.path) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path)]) }
        }
        Button("Copy Path") { store.copy(tree.path, label: "Copied path") }
        if let branch = tree.branch {
            Button("Show \(branch) in Graph") {
                if let ref = branchRef { store.select(commit: ref.target, scroll: true) }
            }
            .disabled(branchRef == nil)
        }
        if !tree.isMain {
            Divider()
            if tree.isLocked {
                Button("Unlock") { store.unlockWorktree(tree) }
            } else if !tree.isPrunable {
                Button("Lock…") { store.promptLockWorktree(tree) }
                Button("Move…") { store.moveWorktree(tree) }
            }
            if tree.isPrunable {
                Button("Prune") { store.pruneWorktrees() }
            } else {
                Button("Remove Worktree…", role: .destructive) { store.removeWorktree(tree) }
            }
        }
    }
}

private struct TrackingPill: View {
    let ref: Ref
    var body: some View {
        HStack(spacing: 4) {
            if ref.upstreamGone {
                Image(systemName: "icloud.slash").font(.system(size: 9)).help("Upstream branch was deleted")
            }
            if ref.ahead > 0 {
                Text("↑\(ref.ahead)").help("\(ref.ahead) commit(s) to push")
            }
            if ref.behind > 0 {
                Text("↓\(ref.behind)").help("\(ref.behind) commit(s) to pull")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct StashRow: View {
    let store: RepoStore
    let stash: Stash

    var body: some View {
        let selected = store.selection == .commit(stash.sha)
        SidebarItem(symbol: "tray", title: stash.message.isEmpty ? stash.ref : stash.message,
                    detail: Formatters.relative(stash.date), selected: selected) {
            store.selection = .commit(stash.sha)
            store.fileFocus = nil
        }
        .help("\(stash.ref): \(stash.message)")
        .contextMenu {
            Button("Apply Stash") { store.applyStash(stash) }
            Button("Pop Stash") { store.popStash(stash) }
            Divider()
            Button("Delete Stash", role: .destructive) { store.dropStash(stash) }
        }
    }
}

private struct PullRequestRow: View {
    let store: RepoStore
    let pr: PullRequest

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: pr.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(pr.isDraft ? Theme.secondaryText : Theme.added)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title).font(.system(size: 12)).lineLimit(2)
                Text("#\(pr.number) · \(pr.headRefName) → \(pr.baseRefName)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onClick({
            if let ref = store.localBranches.first(where: { $0.name == pr.headRefName })
                ?? store.remoteBranches.first(where: { $0.branchName == pr.headRefName }) {
                store.select(commit: ref.target, scroll: true)
            }
        }, double: { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } })
        .help("\(pr.title)\nby \(pr.author?.login ?? "unknown")\nDouble-click to open on GitHub")
        .contextMenu {
            Button("Open on GitHub") { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
            Button("Checkout Pull Request") { store.checkoutPullRequest(pr) }
            Button("Copy Link") { store.copy(pr.url, label: "Copied PR link") }
        }
    }
}
