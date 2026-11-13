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
    private var laneColor: Color { Theme.lane(item.row.color, head: store.headLaneColor) }
    private var isHeadCommit: Bool { item.commit != nil && item.commit?.sha == store.headSha }
    private var dimmed: Bool {
        guard !store.searchText.trimmed.isEmpty else { return false }
        guard let commit = item.commit else { return true }
        return !store.matchesSearch(commit)
    }

    var body: some View {
        HStack(spacing: 0) {
            refCell
                .frame(width: columns.refWidth, alignment: .leading)
            GraphCell(row: item.row, commit: item.commit, isWIP: item.isWIP, connector: connectorOpacity, width: columns.graphWidth,
                      headLane: store.headLaneColor)
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
        // A hairline under the text columns keeps long rows easy to follow; the graph stays clean.
        .overlay(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Theme.rowDivider)
                .frame(height: 1)
                .padding(.leading, columns.refWidth + columns.graphWidth)
                .allowsHitTesting(false)
        }
        .opacity(dimmed ? 0.35 : 1)
        .contentShape(Rectangle())
        .onClick({
            if let commit = item.commit { store.select(commit: commit.sha) } else { store.selection = .wip; store.fileFocus = nil }
        }, double: item.commit.map { commit in { store.checkoutBranch(onCommit: commit.sha) } })
        .onHover { hovering = $0 }
        .pointingHandCursor()
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

    private var isHovered: Bool {
        #if DEBUG
        return hovering || store.debugHoveredRow == item.id
        #else
        return hovering
        #endif
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
        } else if isHeadCommit {
            // Where you are, findable even when the branch label scrolls out of sight.
            Color.accentColor.opacity(0.08)
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
                    .layoutPriority(2)   // the name wins space over the connector line
                if badges.count > 1 {
                    Menu {
                        ForEach(badges.dropFirst()) { badge in
                            Menu(badge.name) { BadgeMenu(store: store, badge: badge) }
                        }
                    } label: {
                        Text("+\(badges.count - 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 6)
                            .frame(height: 21)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.badgeFill))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.badgeStroke))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .layoutPriority(2)
                    .help(badges.dropFirst().map(\.name).joined(separator: "\n"))
                }
                connectorLine
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
        } else if isHovered, !item.isWIP, let owner = store.laneOwners[item.row.color] {
            // Which branch this commit belongs to, shown faintly like GitKraken.
            HStack(spacing: 4) {
                RefBadgeView(badge: owner, color: laneColor)
                    .opacity(0.5)
                    .layoutPriority(2)
                connectorLine
            }
            .padding(.leading, 8)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    /// From the end of the label to the edge of the column; GraphCell carries it on to the node.
    private var connectorLine: some View {
        Rectangle()
            .fill(laneColor.opacity(connectorOpacity))
            .frame(height: 2)
            .frame(minWidth: 6, maxWidth: .infinity)
    }

    private var connectorOpacity: Double {
        if let first = badges.first { return first.isHead ? 1 : 0.8 }
        if isHovered, !item.isWIP, store.laneOwners[item.row.color] != nil { return 0.3 }
        return 0
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
    /// Opacity of the line from the branch label to this row's node (0 = none).
    let connector: Double
    let width: CGFloat
    /// The checked-out branch's lane: drawn in the accent colour, the others dimmed.
    var headLane: Int? = nil

    static func x(_ lane: Int) -> CGFloat { 12 + CGFloat(lane) * Theme.laneWidth }

    var body: some View {
        let height = Theme.rowHeight
        let nodeX = Self.x(row.lane)
        let color = Theme.lane(row.color, head: headLane)
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let mid = size.height / 2
                if connector > 0 {
                    // Continues the line drawn after the label in the branch column, so label
                    // and node read as one connected thing.
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: mid))
                    path.addLine(to: CGPoint(x: nodeX, y: mid))
                    context.stroke(path, with: .color(color.opacity(connector)), lineWidth: 2)
                }
                // The current branch's lines go on top where lanes cross.
                for line in row.lines.filter({ $0.color != headLane }) + row.lines.filter({ $0.color == headLane }) {
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
                    let onHead = headLane != nil && line.color == headLane
                    context.stroke(path, with: .color(Theme.lane(line.color, head: headLane)),
                                   style: StrokeStyle(lineWidth: onHead ? 2.5 : 2, lineCap: .round,
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

/// Right-click on a commit row: the menu of its first branch label (or just the commit).
struct CommitMenu: View {
    let store: RepoStore
    let commit: Commit
    let badges: [RefBadge]

    var body: some View {
        RefMenu(store: store, commit: commit, badge: badges.first { $0.local != nil || !$0.remotes.isEmpty } ?? badges.first,
                badges: badges)
    }
}

/// Right-click on a branch or tag label (graph, sidebar).
struct BadgeMenu: View {
    let store: RepoStore
    let badge: RefBadge

    var body: some View {
        let target = badge.primary?.target ?? ""
        RefMenu(store: store, commit: store.commit(target), badge: badge, badges: store.badges[target] ?? [badge])
    }
}

/// One menu for branches, tags and commits, in GitKraken's order: sync, checkout, commit
/// edits, pull request and patch, rename/delete, copy, Solo, tags. Items that don't apply
/// to what was clicked are left out rather than disabled.
private struct RefMenu: View {
    let store: RepoStore
    let commit: Commit?
    let badge: RefBadge?
    let badges: [RefBadge]

    private var local: Ref? { badge?.local }
    private var remotes: [Ref] { badge?.remotes ?? [] }
    private var tag: Ref? { badge?.tag }
    private var branch: String { store.headBranch ?? "HEAD" }

    var body: some View {
        syncSection
        checkoutSection
        commitSection
        Divider()
        if let local { Button("Start a Pull Request…") { store.openCreatePR(head: local.name) } }
        Button("Apply Patch…") { store.applyPatch() }
        refSection
        copySection
        soloSection
        if let commit {
            Divider()
            Button("Create Tag Here…") { store.promptCreateTag(at: commit.sha) }
            Button("Create Annotated Tag Here…") { store.promptCreateAnnotatedTag(at: commit.sha) }
        }
    }

    // MARK: Pull, push, upstream

    @ViewBuilder private var syncSection: some View {
        if let local {
            if local.upstream != nil {
                Button("Pull (Fast-forward if Possible)") { store.pullFastForward(local) }
            }
            Button("Push") { store.push(branch: local.name) }
            Menu("Set Upstream") {
                ForEach(store.remoteBranches.filter { !$0.name.hasSuffix("/HEAD") }) { remote in
                    Toggle(remote.name, isOn: .init(get: { local.upstream == remote.name },
                                                    set: { _ in store.setUpstream(local, to: remote.name) }))
                }
                if store.remoteBranches.isEmpty { Text("No remote branches") }
            }
            Divider()
        } else if let remote = remotes.first, let head = store.headRef, head.upstream == nil {
            Button("Set as Upstream of \(head.name)") { store.setUpstream(head, to: remote.name) }
            Divider()
        }
    }

    // MARK: Checkout, worktree, merge

    @ViewBuilder private var checkoutSection: some View {
        let locals = badges.compactMap(\.local)
        let remoteRefs = badges.flatMap(\.remotes)
        let tags = badges.compactMap(\.tag)
        if let local, !local.isHead, locals.count == 1, remoteRefs.allSatisfy({ $0.branchName == local.name }) {
            Button("Checkout \(local.name)") { store.checkout(local.name) }
        }
        Menu("Checkout") {
            ForEach(locals.filter { !$0.isHead }) { ref in
                Button(ref.name) { store.checkout(ref.name) }
            }
            ForEach(remoteRefs) { ref in
                Button(ref.name) { store.checkout(remote: ref) }
            }
            ForEach(tags) { ref in
                Button("Tag \(ref.name)") { store.checkout(ref.name) }
            }
            if let commit {
                if !locals.isEmpty || !remoteRefs.isEmpty || !tags.isEmpty { Divider() }
                Button("This Commit (Detached HEAD)") { store.checkout(commit.sha) }
            }
        }
        if let commit {
            Menu("Create Worktree From") {
                ForEach(locals.filter { !$0.isHead }) { ref in
                    Button(ref.name) { store.createWorktree(ref: ref, sha: commit.sha) }
                }
                ForEach(remoteRefs) { ref in
                    Button(ref.name) { store.createWorktree(ref: ref, sha: commit.sha) }
                }
                if locals.contains(where: { !$0.isHead }) || !remoteRefs.isEmpty { Divider() }
                Button("This Commit (Detached)") { store.createWorktree(ref: nil, sha: commit.sha) }
            }
        }
        mergeItems
        Divider()
    }

    @ViewBuilder private var mergeItems: some View {
        if let current = store.headBranch {
            if let ref = local ?? remotes.first, !(local?.isHead ?? false) {
                Button("Merge \(ref.name) Into \(current)") { store.merge(ref.name) }
                Button("Rebase \(current) Onto \(ref.name)") { store.rebaseCurrent(onto: ref.name) }
            } else if badge == nil || badge?.tag != nil, let commit, commit.sha != store.headSha {
                Button("Merge Into \(current)") { store.merge(commit.sha) }
                Button("Rebase \(current) Onto This Commit") { store.rebaseCurrent(onto: commit.sha) }
            }
        }
        if let local, let up = local.upstream, local.behind > 0, local.ahead == 0, !local.isHead {
            Button("Fast-forward to \(up)") { store.fastForward(local.name, to: up) }
        }
    }

    // MARK: Commit edits

    @ViewBuilder private var commitSection: some View {
        if let commit {
            let isHead = commit.sha == store.headSha
            Button("Create Branch Here…") { store.promptCreateBranch(at: commit.sha) }
            Menu("Reset \(branch) to This Commit") {
                Button("Soft — keep all changes staged") { store.reset(to: commit.sha, mode: "soft") }
                Button("Mixed — keep changes unstaged") { store.reset(to: commit.sha, mode: "mixed") }
                Button("Hard — discard all changes") { store.reset(to: commit.sha, mode: "hard") }
            }
            if store.headSha != nil {
                Button("Edit Commit Message…") { store.editHistory(.reword, commit) }
            }
            if !isHead { Button("Cherry-pick Commit") { store.cherryPick(commit) } }
            Button("Revert Commit") { store.revert(commit) }
            if !commit.isMerge, store.headSha != nil {
                Button("Drop Commit…", role: .destructive) { store.editHistory(.drop, commit) }
                Button("Move Commit Down") { store.editHistory(.down, commit) }
                if !isHead { Button("Move Commit Up") { store.editHistory(.up, commit) } }
            }
        }
    }

    // MARK: Rename, delete

    @ViewBuilder private var refSection: some View {
        if local != nil || !remotes.isEmpty || tag != nil { Divider() }
        if let local {
            Button("Rename \(local.name)…") { store.promptRename(local) }
            if !local.isHead {
                Button("Delete \(local.name)", role: .destructive) { store.deleteBranch(local) }
            }
        }
        ForEach(remotes) { remote in
            Button("Delete \(remote.name)", role: .destructive) { store.deleteRemoteBranch(remote) }
        }
        if let local, !local.isHead, let remote = remotes.first(where: { $0.branchName == local.name }) {
            Button("Delete \(local.name) and \(remote.name)", role: .destructive) { store.deleteBranchAndRemote(local, remote) }
        }
        if let tag {
            Button("Push Tag \(tag.name)") { store.pushTag(tag) }
            Button("Delete Tag \(tag.name)", role: .destructive) { store.deleteTag(tag) }
        }
    }

    // MARK: Copy

    @ViewBuilder private var copySection: some View {
        Divider()
        if let ref = local ?? remotes.first {
            Button("Copy Branch Name") { store.copy(ref.name, label: "Copied \(ref.name)") }
        }
        if let tag { Button("Copy Tag Name") { store.copy(tag.name, label: "Copied \(tag.name)") } }
        if let commit {
            Button("Copy Commit SHA") { store.copy(commit.sha, label: "Copied \(commit.shortSha)") }
            Button("Copy Commit Message") { store.copy(commit.fullMessage, label: "Copied message") }
        }
        if !store.remotes.isEmpty {
            if let ref = local ?? remotes.first {
                Button("Copy Link to Branch") { store.copyBranchLink(ref) }
            }
            if let commit { Button("Copy Link to Commit") { store.copyCommitLink(commit) } }
        }
        if let commit { Button("Create Patch From Commit…") { store.createPatch(commit) } }
    }

    // MARK: Solo

    @ViewBuilder private var soloSection: some View {
        let branches = badges.filter { $0.local != nil || !$0.remotes.isEmpty }
        if !branches.isEmpty || store.soloRefs != nil {
            Divider()
            Menu("Solo") {
                ForEach(branches) { b in
                    Button(b.name) {
                        store.solo([b.local].compactMap { $0 } + b.remotes, label: b.name)
                    }
                }
                if store.soloRefs != nil {
                    if !branches.isEmpty { Divider() }
                    Button("Show All Branches") { store.clearSolo() }
                }
            }
        }
    }
}
