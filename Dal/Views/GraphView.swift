import SwiftUI
import UniformTypeIdentifiers

struct GraphView: View {
    @Bindable var store: RepoStore
    @AppStorage("refColumnWidth") private var refWidth: Double = 200
    @AppStorage("graphColumnWidth") private var graphMax: Double = 170
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            content(columns: GraphColumns(available: geo.size.width, laneCount: store.laneCount, refWidth: refWidth, graphMax: graphMax))
        }
    }

    private func content(columns: GraphColumns) -> some View {
        VStack(spacing: 0) {
            header(columns)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            GraphRowView(store: store, item: item, columns: columns)
                                .id(item.id)
                        }
                        if store.hasMore {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading more commits…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            }
                            .frame(height: 40)
                            .onAppear { store.loadMore() }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
                .onKeyPress(.pageUp) { store.moveSelection(-20); return .handled }
                .onKeyPress(.pageDown) { store.moveSelection(20); return .handled }
                .onKeyPress(.home) { store.moveSelection(-store.items.count); return .handled }
                .onKeyPress(.end) { store.moveSelection(store.items.count); return .handled }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: store.scrollCentered ? .center : nil)
                    }
                    store.scrollTarget = nil
                }
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            }
        }
        .confirmationDialog(dropTitle, isPresented: Binding(get: { store.drop != nil }, set: { if !$0 { store.drop = nil } }),
                            presenting: store.drop) { drop in
            if drop.canFastForward {
                Button("Fast-forward \(drop.target) to \(drop.source)") { store.fastForward(drop.target, to: drop.source) }
            }
            Button(drop.target == store.headBranch ? "Merge \(drop.source) into \(drop.target)"
                                                   : "Check out \(drop.target) and merge \(drop.source) into it") {
                store.merge(drop.source, into: drop.target)
            }
            if store.localBranches.contains(where: { $0.name == drop.source }) {
                Button("Rebase \(drop.source) onto \(drop.target)") { store.rebase(drop.source, onto: drop.target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { drop in
            Text(drop.target == store.headBranch ? "" : "\(drop.target) isn't checked out; merging checks it out first.")
        }
    }

    private var dropTitle: String {
        guard let drop = store.drop else { return "" }
        return "\(drop.source) → \(drop.target)"
    }

    private func header(_ columns: GraphColumns) -> some View {
        HStack(spacing: 0) {
            Text("Branch / tag")
                .padding(.leading, 10)
                .frame(width: columns.refWidth, alignment: .leading)
                .overlay(alignment: .trailing) { ColumnResizer(width: $refWidth, range: 90...360) }
            Text("Graph")
                .padding(.leading, 6)
                .frame(width: columns.graphWidth, alignment: .leading)
                .overlay(alignment: .trailing) { ColumnResizer(width: $graphMax, range: 40...600) }
            Text("Commit message")
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            if columns.showAuthor { Text("Author").frame(width: GraphColumns.authorWidth, alignment: .leading) }
            if columns.showDate { Text("Date").frame(width: GraphColumns.dateWidth, alignment: .leading) }
            if columns.showSha { Text("SHA").frame(width: GraphColumns.shaWidth, alignment: .leading) }
        }
        .lineLimit(1)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .frame(height: 28)
        .background(.bar)
    }
}

/// Column widths for the graph table. Optional columns drop out (SHA, then date, then author)
/// before the commit message gets squeezed below a readable width.
struct GraphColumns: Equatable {
    static let authorWidth: CGFloat = 130
    static let dateWidth: CGFloat = 92
    static let shaWidth: CGFloat = 62
    static let minMessage: CGFloat = 260

    var refWidth: CGFloat
    var graphWidth: CGFloat
    var showAuthor = true
    var showDate = true
    var showSha = true

    init(available: CGFloat, laneCount: Int, refWidth: Double, graphMax: Double) {
        let wanted = CGFloat(laneCount) * Theme.laneWidth + 14
        let cap = max(40, min(CGFloat(graphMax), available * 0.4))
        self.refWidth = min(CGFloat(refWidth), max(110, available * 0.22))
        self.graphWidth = min(wanted, cap)
        var rest = available - self.refWidth - graphWidth - 10
        rest -= Self.authorWidth + Self.dateWidth + Self.shaWidth
        if rest < Self.minMessage { showSha = false; rest += Self.shaWidth }
        if rest < Self.minMessage { showDate = false; rest += Self.dateWidth }
        if rest < Self.minMessage { showAuthor = false; rest += Self.authorWidth }
    }
}

private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
    }
}

// MARK: Row

private struct GraphRowView: View {
    let store: RepoStore
    let item: GraphItem
    let columns: GraphColumns

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var refsExpanded = false
    @State private var refsHoverTask: Task<Void, Never>?

    private var isSelected: Bool {
        switch store.selection {
        case .wip: item.isWIP
        case .commit(let sha): sha == item.id
        case nil: false
        }
    }

    private var badges: [RefBadge] { item.commit.flatMap { store.badges[$0.sha] } ?? [] }
    private var laneColor: Color { Theme.lane(item.row.color) }
    private var dimmed: Bool {
        guard !store.searchText.trimmed.isEmpty else { return false }
        guard let commit = item.commit else { return true }
        return !store.matchesSearch(commit)
    }

    var body: some View {
        HStack(spacing: 0) {
            refCell
                .frame(width: columns.refWidth, alignment: .leading)
            GraphCell(row: item.row, commit: item.commit, isWIP: item.isWIP, hasRefs: !badges.isEmpty, width: columns.graphWidth)
            messageCell
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let commit = item.commit {
                if columns.showAuthor {
                    Text(commit.authorName)
                        .lineLimit(1)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: GraphColumns.authorWidth, alignment: .leading)
                        .help(commit.authorEmail)
                }
                if columns.showDate {
                    Text(Formatters.relative(commit.authorDate))
                        .lineLimit(1)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: GraphColumns.dateWidth, alignment: .leading)
                        .help(Formatters.full.string(from: commit.authorDate))
                }
                if columns.showSha {
                    Text(commit.shortSha)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.mutedText)
                        .frame(width: GraphColumns.shaWidth, alignment: .leading)
                }
            } else {
                Color.clear.frame(width: (columns.showAuthor ? GraphColumns.authorWidth : 0)
                                  + (columns.showDate ? GraphColumns.dateWidth : 0)
                                  + (columns.showSha ? GraphColumns.shaWidth : 0))
            }
        }
        .font(.system(size: 12))
        .frame(height: Theme.rowHeight)
        .background(rowBackground)
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if let commit = item.commit { store.select(commit: commit.sha) } else { store.selection = .wip; store.fileFocus = nil }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu { if let commit = item.commit { CommitMenu(store: store, commit: commit, badges: badges) } }
        .dropDestination(for: String.self) { names, _ in
            guard let source = names.first, let target = dropTargetName, source != target else { return false }
            Task {
                let ff = await store.canFastForward(target, to: source)
                store.drop = DropRequest(source: source, target: target, canFastForward: ff)
            }
            return true
        } isTargeted: { dropTargeted = $0 && dropTargetName != nil }
        // The expanded branch list draws over the rows below it.
        .zIndex(refsExpanded || debugForcedOpen ? 10 : 0)
    }

    /// Hovering the branch/tag cell lists every ref on the commit, untruncated (GitKraken-style).
    /// Worth it when there's more than one ref or the single name doesn't fit.
    private var refsNeedExpanding: Bool {
        guard let first = badges.first else { return false }
        let approxWidth = CGFloat(first.name.count) * 7 + 44
        return badges.count > 1 || approxWidth > columns.refWidth - 16
    }

    private var debugForcedOpen: Bool {
        #if DEBUG
        return store.debugExpandedRefs == item.id
        #else
        return false
        #endif
    }

    private func hoverRefs(_ inside: Bool) {
        refsHoverTask?.cancel()
        guard refsNeedExpanding else { return }
        // Short delays: no flicker when the pointer sweeps across rows, and moving from the
        // cell into the expanded list doesn't close it.
        refsHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 120))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) { refsExpanded = inside }
        }
    }

    /// Dropping a branch on a row targets that row's local branch. Remote-only rows aren't
    /// targets: merging "into" a remote branch would only detach HEAD.
    private var dropTargetName: String? {
        badges.first(where: { $0.local != nil })?.name
    }

    private var accessibilityText: String {
        guard let commit = item.commit else { return "Work in progress, \(store.status.fileCount) changed files" }
        let refs = badges.map(\.name).joined(separator: ", ")
        return "\(commit.subject), by \(commit.authorName), \(Formatters.relative(commit.authorDate))"
            + (refs.isEmpty ? "" : ", branches \(refs)")
    }

    @ViewBuilder private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.24)
        } else if dropTargeted {
            Color.accentColor.opacity(0.16)
        } else if hovering {
            Theme.hoverFill
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var refCell: some View {
        if item.isWIP {
            HStack {
                Spacer()
            }
        } else if let first = badges.first {
            HStack(spacing: 4) {
                BadgeItem(store: store, badge: first, color: laneColor)
                if badges.count > 1 {
                    Menu {
                        ForEach(badges.dropFirst()) { badge in
                            Menu(badge.name) { BadgeMenu(store: store, badge: badge) }
                        }
                    } label: {
                        Text("+\(badges.count - 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 4)
                            .frame(height: 17)
                            .background(RoundedRectangle(cornerRadius: 4).fill(laneColor.opacity(0.18)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(badges.dropFirst().map(\.name).joined(separator: "\n"))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hoverRefs($0) }
            .overlay(alignment: .topLeading) {
                if refsExpanded || debugForcedOpen {
                    ExpandedRefs(store: store, badges: badges, color: laneColor, minWidth: columns.refWidth - 4)
                        .onHover { hoverRefs($0) }
                        .transition(.opacity)
                }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var messageCell: some View {
        if let commit = item.commit {
            // One Text so truncation ends in a clean "…" instead of a stray letter of the body.
            (Text(commit.subject).fontWeight(isSelected ? .medium : .regular)
             + Text(commit.body.isEmpty ? "" : "   " + commit.body.replacingOccurrences(of: "\n", with: " "))
                .foregroundColor(Theme.mutedText))
                .lineLimit(1)
        } else {
            HStack(spacing: 8) {
                Text("Uncommitted changes")
                    .foregroundStyle(Theme.secondaryText)
                let s = store.status
                if !s.conflicted.isEmpty {
                    countPill("exclamationmark.triangle.fill", s.conflicted.count, Theme.conflict)
                }
                if !s.unstaged.isEmpty { countPill("pencil", s.unstaged.count, Theme.modified) }
                if !s.staged.isEmpty { countPill("checkmark", s.staged.count, Theme.added) }
            }
        }
    }

    private func countPill(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Every ref on a commit, stacked and untruncated, floating over the graph while hovered.
/// Each label keeps its behaviour: click selects, double-click checks out, right-click menu, drag.
private struct ExpandedRefs: View {
    let store: RepoStore
    let badges: [RefBadge]
    let color: Color
    let minWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(badges) { badge in
                BadgeItem(store: store, badge: badge, color: color, fullWidth: true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .padding(.leading, 2)
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branches and tags on this commit")
    }
}

private struct BadgeItem: View {
    let store: RepoStore
    let badge: RefBadge
    let color: Color
    var fullWidth = false

    var body: some View {
        RefBadgeView(badge: badge, color: color, untruncated: fullWidth)
            .onClick({ store.select(commit: badge.primary?.target ?? "") }, double: checkout)
            .contextMenu { BadgeMenu(store: store, badge: badge) }
            .accessibilityLabel("Branch \(badge.name)")
            .if(badge.local != nil || !badge.remotes.isEmpty) { view in
                view.draggable(badge.name) {
                    RefBadgeView(badge: badge, color: color, compact: true)
                }
            }
    }

    private func checkout() {
        if let local = badge.local {
            if !local.isHead { store.checkout(local.name) }
        } else if let remote = badge.remotes.first {
            store.checkout(remote: remote)
        } else if let tag = badge.tag {
            store.checkout(tag.name)
        }
    }
}

// MARK: Graph drawing

struct GraphCell: View {
    let row: GraphRow
    let commit: Commit?
    let isWIP: Bool
    let hasRefs: Bool
    let width: CGFloat

    static func x(_ lane: Int) -> CGFloat { 12 + CGFloat(lane) * Theme.laneWidth }

    var body: some View {
        let height = Theme.rowHeight
        let nodeX = Self.x(row.lane)
        let color = Theme.lane(row.color)
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let mid = size.height / 2
                if hasRefs {
                    var connector = Path()
                    connector.move(to: CGPoint(x: 0, y: mid))
                    connector.addLine(to: CGPoint(x: nodeX, y: mid))
                    context.stroke(connector, with: .color(color.opacity(0.55)), lineWidth: 1.5)
                }
                for line in row.lines {
                    var path = Path()
                    switch line.kind {
                    case .pass:
                        let start = CGPoint(x: Self.x(line.from), y: 0)
                        let end = CGPoint(x: Self.x(line.to), y: size.height)
                        path.move(to: start)
                        if start.x == end.x {
                            path.addLine(to: end)
                        } else {
                            path.addCurve(to: end, control1: CGPoint(x: start.x, y: mid),
                                          control2: CGPoint(x: end.x, y: mid))
                        }
                    case .toNode:
                        let start = CGPoint(x: Self.x(line.from), y: 0)
                        let end = CGPoint(x: Self.x(line.to), y: mid)
                        path.move(to: start)
                        if start.x == end.x {
                            path.addLine(to: end)
                        } else {
                            path.addCurve(to: end, control1: CGPoint(x: start.x, y: mid * 0.9),
                                          control2: CGPoint(x: start.x + (end.x - start.x) * 0.2, y: mid))
                        }
                    case .fromNode:
                        let start = CGPoint(x: Self.x(line.from), y: mid)
                        let end = CGPoint(x: Self.x(line.to), y: size.height)
                        path.move(to: start)
                        if start.x == end.x {
                            path.addLine(to: end)
                        } else {
                            path.addCurve(to: end, control1: CGPoint(x: end.x - (end.x - start.x) * 0.2, y: mid),
                                          control2: CGPoint(x: end.x, y: mid + (size.height - mid) * 0.1))
                        }
                    }
                    let isWIPLine = isWIP && line.kind == .fromNode
                    context.stroke(path, with: .color(Theme.lane(line.color)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                      dash: isWIPLine ? [3, 3] : []))
                }
            }
            node(color: color)
                .position(x: nodeX, y: height / 2)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }

    @ViewBuilder private func node(color: Color) -> some View {
        if isWIP {
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                .background(Circle().fill(Theme.panel))
                .frame(width: 16, height: 16)
        } else if let commit, commit.isMerge {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5))
        } else if let commit {
            AvatarView(name: commit.authorName, email: commit.authorEmail, size: 20, ring: color)
        }
    }
}

// MARK: Menus

struct CommitMenu: View {
    let store: RepoStore
    let commit: Commit
    let badges: [RefBadge]

    var body: some View {
        let branch = store.headBranch ?? "HEAD"
        let isHead = commit.sha == store.headSha
        ForEach(badges.filter { $0.local != nil || !$0.remotes.isEmpty }) { badge in
            Menu(badge.name) { BadgeMenu(store: store, badge: badge) }
        }
        if !badges.isEmpty { Divider() }

        Button("Checkout This Commit (Detached)") { store.checkout(commit.sha) }
        Button("Create Branch Here…") { store.promptCreateBranch(at: commit.sha) }
        Button("Create Tag Here…") { store.promptCreateTag(at: commit.sha) }
        Divider()
        if !isHead {
            Button("Merge Into \(branch)") { store.merge(commit.sha) }
            Button("Rebase \(branch) Onto This Commit") { store.rebaseCurrent(onto: commit.sha) }
            Button("Cherry-pick Commit") { store.cherryPick(commit) }
        }
        Button("Revert Commit") { store.revert(commit) }
        Menu("Reset \(branch) to This Commit") {
            Button("Soft — keep all changes staged") { store.reset(to: commit.sha, mode: "soft") }
            Button("Mixed — keep changes unstaged") { store.reset(to: commit.sha, mode: "mixed") }
            Button("Hard — discard all changes") { store.reset(to: commit.sha, mode: "hard") }
        }
        Divider()
        Button("Copy SHA") { store.copy(commit.sha, label: "Copied \(commit.shortSha)") }
        Button("Copy Message") { store.copy(commit.fullMessage, label: "Copied message") }
    }
}

struct BadgeMenu: View {
    let store: RepoStore
    let badge: RefBadge

    var body: some View {
        let current = store.headBranch
        if let local = badge.local {
            if !local.isHead {
                Button("Checkout \(local.name)") { store.checkout(local.name) }
                if let current {
                    Button("Merge \(local.name) Into \(current)") { store.merge(local.name) }
                    Button("Rebase \(current) Onto \(local.name)") { store.rebaseCurrent(onto: local.name) }
                }
                Divider()
            }
            Button("Push \(local.name)") { store.push(branch: local.name) }
            if local.isHead, local.upstream != nil {
                Button("Pull") { store.pull() }
            }
            if let up = local.upstream, local.behind > 0, local.ahead == 0, !local.isHead {
                Button("Fast-forward to \(up)") { store.fastForward(local.name, to: up) }
            }
            Button("Create Pull Request…") { store.openCreatePR(head: local.name) }
            Divider()
            Button("Rename…") { store.promptRename(local) }
            if !local.isHead {
                Button("Delete \(local.name)", role: .destructive) { store.deleteBranch(local) }
            }
            Divider()
            Button("Copy Branch Name") { store.copy(local.name, label: "Copied \(local.name)") }
        }
        if !badge.remotes.isEmpty {
            if badge.local != nil { Divider() }
            ForEach(badge.remotes) { remote in
                if badge.local == nil {
                    Button("Checkout \(remote.name)") { store.checkout(remote: remote) }
                    if let current {
                        Button("Merge \(remote.name) Into \(current)") { store.merge(remote.name) }
                        Button("Rebase \(current) Onto \(remote.name)") { store.rebaseCurrent(onto: remote.name) }
                    }
                }
                if let local = store.headRef, local.upstream == nil {
                    Button("Set as Upstream of \(local.name)") { store.setUpstream(local, to: remote.name) }
                }
                Button("Delete \(remote.name) on Remote", role: .destructive) { store.deleteRemoteBranch(remote) }
            }
        }
        if let tag = badge.tag {
            Button("Checkout Tag \(tag.name)") { store.checkout(tag.name) }
            Button("Push Tag") { store.pushTag(tag) }
            Button("Delete Tag", role: .destructive) { store.deleteTag(tag) }
            Button("Copy Tag Name") { store.copy(tag.name, label: "Copied \(tag.name)") }
        }
    }
}
