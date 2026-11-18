import SwiftUI

/// The toolbar's branch switcher: type to narrow hundreds of branches and tags, ↑/↓ to move,
/// Return to check out. Replaces a plain menu that listed every local branch in one column.
struct BranchSwitcher: View {
    let store: RepoStore
    let dismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    enum Kind: Int { case local, remote, tag }

    struct Entry: Identifiable, Equatable {
        let ref: Ref
        let kind: Kind
        var id: String { ref.fullName }
    }

    /// Local branches, remote branches that have no local twin, then tags (newest names first).
    private var entries: [Entry] {
        let q = query.trimmed
        let localNames = Set(store.localBranches.map(\.name))
        func ok(_ name: String) -> Bool { Self.matches(name, q) }
        var local = store.localBranches.filter { ok($0.name) }
        local.sort { a, b in
            if a.isHead != b.isHead { return a.isHead }
            return Self.rank(a.name, q) < Self.rank(b.name, q)
                || (Self.rank(a.name, q) == Self.rank(b.name, q) && a.name.localizedStandardCompare(b.name) == .orderedAscending)
        }
        let remote = store.remoteBranches
            .filter { !$0.name.hasSuffix("/HEAD") && !localNames.contains($0.branchName) && ok($0.name) }
            .sorted { Self.rank($0.name, q) < Self.rank($1.name, q)
                || (Self.rank($0.name, q) == Self.rank($1.name, q) && $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
        var tags = store.tags.filter { ok($0.name) }.sorted { a, b in
            let ra = Self.rank(a.name, q), rb = Self.rank(b.name, q)
            if ra != rb { return ra < rb }
            // "v2.0.0" before "v2.0.0-final"; otherwise newest version first.
            if b.name.hasPrefix(a.name) != a.name.hasPrefix(b.name) { return b.name.hasPrefix(a.name) }
            return a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
        if q.isEmpty { tags = Array(tags.prefix(30)) }
        return local.map { Entry(ref: $0, kind: .local) }
            + remote.prefix(300).map { Entry(ref: $0, kind: .remote) }
            + tags.prefix(300).map { Entry(ref: $0, kind: .tag) }
    }

    /// Every space-separated word must appear (any order, any case): "11119 hub" finds
    /// feat/BLT-11119-hub-kurumsal-blok.
    static func matches(_ name: String, _ query: String) -> Bool {
        let words = query.split(separator: " ")
        return words.allSatisfy { name.localizedCaseInsensitiveContains($0) }
    }

    /// Lower is better: exact, prefix, the part after the last "/", anywhere.
    static func rank(_ name: String, _ query: String) -> Int {
        let q = query.lowercased(), n = name.lowercased()
        guard !q.isEmpty else { return 0 }
        if n == q { return 0 }
        if n.hasPrefix(q) { return 1 }
        if (n.split(separator: "/").last.map(String.init) ?? n).hasPrefix(q) { return 2 }
        return 3
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                TextField("Switch to a branch or tag", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { activate(list) }
                    .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                    .onExitCommand { dismiss() }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            if let busy = store.busy {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("\(busy)…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Cancel") { store.cancelRunning() }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            Divider()
            if list.isEmpty {
                Text(query.isEmpty ? "No branches yet" : "Nothing matches “\(query.trimmed)”")
                    .font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                                if index == 0 || list[index - 1].kind != entry.kind {
                                    sectionHeader(entry.kind, count: list.filter { $0.kind == entry.kind }.count)
                                }
                                row(entry, highlighted: index == highlighted)
                                    .id(entry.id)
                                    .onTapGesture { checkout(entry) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    // Fits the results (no empty well under one match), up to a fixed maximum.
                    .frame(height: min(380, CGFloat(list.count) * 28
                                       + CGFloat(Set(list.map(\.kind)).count) * 27 + 8))
                    .onChange(of: highlighted) { _, index in
                        if index < list.count { proxy.scrollTo(list[index].id) }
                    }
                }
            }
            Divider()
            HStack {
                Button("New Branch…") { dismiss(); store.promptCreateBranch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                KeyCap(keys: "↑↓")
                Text("move").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
                KeyCap(keys: "⏎")
                Text("check out").font(.system(size: 11)).foregroundStyle(Theme.mutedText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(width: 420)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func sectionHeader(_ kind: Kind, count: Int) -> some View {
        HStack {
            Text(kind == .local ? "Local" : kind == .remote ? "Remote" : "Tags")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.mutedText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(_ entry: Entry, highlighted: Bool) -> some View {
        let ref = entry.ref
        let current = entry.kind == .local && ref.isHead
        let tree = entry.kind == .local ? store.worktree(holding: ref.name) : nil
        return HStack(spacing: 8) {
            Image(systemName: current ? "checkmark.circle.fill"
                  : entry.kind == .remote ? "cloud" : entry.kind == .tag ? "tag" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(current ? Color.accentColor : Theme.secondaryText)
                .frame(width: 16)
            Text(ref.name)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let tree {
                Text("in \(tree.name)").font(.system(size: 11)).foregroundStyle(Theme.mutedText).lineLimit(1)
            }
            if entry.kind == .local {
                HStack(spacing: 4) {
                    if ref.ahead > 0 { Text("↑\(ref.ahead)") }
                    if ref.behind > 0 { Text("↓\(ref.behind)") }
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor.opacity(0.18) : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .help(current ? "\(ref.name) is checked out" : tree.map { "Checked out in worktree “\($0.name)” — opens it" } ?? "Check out \(ref.name)")
    }

    private func move(_ delta: Int, in list: [Entry]) {
        guard !list.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), list.count - 1)
    }

    private func activate(_ list: [Entry]) {
        guard highlighted < list.count else { return }
        checkout(list[highlighted])
    }

    private func checkout(_ entry: Entry) {
        dismiss()
        switch entry.kind {
        case .local:
            if let tree = store.worktree(holding: entry.ref.name) { store.openWorktree(tree) }
            else if !entry.ref.isHead { store.checkout(entry.ref.name) }
        case .remote:
            store.checkout(remote: entry.ref)
        case .tag:
            store.checkout(entry.ref.name)
        }
    }
}
