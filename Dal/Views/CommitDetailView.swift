import SwiftUI

struct CommitDetailView: View {
    let store: RepoStore
    let commit: Commit

    @State private var changes: [FileChange] = []
    @State private var loading = true
    @State private var loadError: String?
    @AppStorage("detail.tree") private var treeMode = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    shaBar
                    message
                    people
                    Divider()
                    filesHeader
                    files
                }
                .padding(14)
            }
        }
        .task(id: commit.sha) {
            loading = true
            do {
                changes = try await store.git.changes(sha: commit.sha, parent: commit.parents.first)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
            loading = false
        }
    }

    private var shaBar: some View {
        HStack(spacing: 6) {
            Text("commit").font(.system(size: 11)).foregroundStyle(.secondary)
            Button {
                store.copy(commit.sha, label: "Copied \(commit.shortSha)")
            } label: {
                HStack(spacing: 4) {
                    Text(commit.shortSha).font(.system(size: 11.5, design: .monospaced))
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Copy full SHA")
            Spacer()
            if commit.isMerge {
                Text("MERGE").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).frame(height: 17)
                    .background(Capsule().fill(Theme.subtleFill))
            }
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.system(size: 15, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refs = store.badges[commit.sha], !refs.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(refs) { badge in
                        RefBadgeView(badge: badge, color: Theme.lane(store.laneColor(for: commit.sha)))
                    }
                }
            }
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(name: commit.authorName, email: commit.authorEmail, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.authorName).font(.system(size: 12.5, weight: .semibold))
                    Text(commit.authorEmail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("authored \(Formatters.full.string(from: commit.authorDate))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if commit.committerEmail != commit.authorEmail || commit.committerName != commit.authorName {
                HStack(spacing: 6) {
                    AvatarView(name: commit.committerName, email: commit.committerEmail, size: 18)
                    Text("committed by \(commit.committerName)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !commit.parents.isEmpty {
                HStack(spacing: 6) {
                    Text(commit.parents.count > 1 ? "parents" : "parent")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(commit.parents, id: \.self) { parent in
                        Button(String(parent.prefix(7))) { store.select(commit: parent, scroll: true) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .help("Jump to parent")
                    }
                }
            }
        }
    }

    private var filesHeader: some View {
        HStack(spacing: 10) {
            let modified = changes.filter { $0.kind == .modified || $0.kind == .typeChanged }.count
            let added = changes.filter { $0.kind == .added }.count
            let deleted = changes.filter { $0.kind == .deleted }.count
            let renamed = changes.filter { $0.kind == .renamed || $0.kind == .copied }.count
            if modified > 0 { stat("pencil", modified, "modified", Theme.modified) }
            if added > 0 { stat("plus", added, "added", Theme.added) }
            if deleted > 0 { stat("minus", deleted, "deleted", Theme.deleted) }
            if renamed > 0 { stat("arrow.right", renamed, "renamed", Theme.renamed) }
            Spacer()
            Picker("", selection: $treeMode) {
                Image(systemName: "list.bullet").tag(false).help("Path")
                Image(systemName: "list.bullet.indent").tag(true).help("Tree")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func stat(_ symbol: String, _ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text("\(count) \(label)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var files: some View {
        if loading && changes.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
        } else if let loadError {
            Text(loadError).font(.system(size: 11)).foregroundStyle(Theme.deleted).textSelection(.enabled)
        } else if changes.isEmpty {
            Text("No file changes").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            LazyVStack(alignment: .leading, spacing: 1) {
                if treeMode {
                    ForEach(groupedByDirectory, id: \.0) { dir, items in
                        if !dir.isEmpty {
                            Label(dir, systemImage: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .padding(.leading, 6)
                        }
                        ForEach(items) { row($0, nameOnly: true).padding(.leading, dir.isEmpty ? 0 : 12) }
                    }
                } else {
                    ForEach(changes) { row($0, nameOnly: false) }
                }
            }
            .padding(.horizontal, -10)
        }
    }

    private var groupedByDirectory: [(String, [FileChange])] {
        let groups = Dictionary(grouping: changes) { $0.directory }
        return groups.keys.sorted().map { ($0, groups[$0]!) }
    }

    private func row(_ change: FileChange, nameOnly: Bool) -> some View {
        let focus = FileFocus.commit(sha: commit.sha, parent: commit.parents.first, change: change)
        let display = nameOnly ? FileChange(path: change.fileName, oldPath: change.oldPath, kind: change.kind) : change
        return FileRow(change: display, selected: store.fileFocus == focus) {
            store.fileFocus = focus
        }
        .contextMenu {
            Button("Open File") { store.openFile(change.path) }
            Button("Reveal in Finder") { store.revealInFinder(change.path) }
            Button("Copy Path") { store.copy(change.path, label: "Copied path") }
        }
    }
}

struct StashDetailView: View {
    let store: RepoStore
    let stash: Stash
    @State private var changes: [FileChange] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(stash.ref).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.full.string(from: stash.date)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(stash.message).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Apply") { store.applyStash(stash) }
                    Button("Pop") { store.popStash(stash) }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Delete", role: .destructive) { store.dropStash(stash) }
                }
                .controlSize(.small)
                Divider()
                SectionTitle(title: "Files", count: changes.count)
                VStack(spacing: 1) {
                    ForEach(changes) { change in
                        let focus = FileFocus.commit(sha: stash.sha, parent: stash.sha + "^1", change: change)
                        FileRow(change: change, selected: store.fileFocus == focus) { store.fileFocus = focus }
                    }
                }
                .padding(.horizontal, -10)
                Text("New (untracked) files in a stash aren't listed here.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .task(id: stash.sha) {
            changes = (try? await store.git.changes(sha: stash.sha, parent: stash.sha + "^1")) ?? []
        }
    }
}

/// Simple wrapping layout for badges.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
