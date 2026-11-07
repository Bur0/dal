import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            TabBar()
            Divider()
            if let store = app.current {
                RepoView(store: store)
                    .id(store.id)
            } else {
                WelcomeView()
            }
        }
        .background(Theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $app.showClone) { CloneSheet() }
        .sheet(isPresented: $app.showSwitcher) { QuickSwitcher() }
        .sheet(item: $app.input) { request in InputSheet(request: request) }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

// MARK: Tabs

struct TabBar: View {
    @Environment(AppState.self) private var app
    @State private var tabsWidth: CGFloat = 0

    /// Tabs in display order, split into runs: an ungrouped tab, or a group with its tabs.
    private enum Segment: Identifiable {
        case tab(RepoStore)
        case group(TabGroup, [RepoStore])
        var id: String {
            switch self {
            case .tab(let s): s.id.uuidString
            case .group(let g, _): g.id.uuidString
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for store in app.tabs {
            if let group = app.group(of: store) {
                if case .group(let g, var members) = result.last, g.id == group.id {
                    members.append(store)
                    result[result.count - 1] = .group(g, members)
                } else {
                    result.append(.group(group, [store]))
                }
            } else {
                result.append(.tab(store))
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78) // traffic lights
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            switch segment {
                            case .tab(let store):
                                TabItem(store: store, selected: store.id == app.selectedID)
                                    .id(store.id)
                            case .group(let group, let members):
                                GroupChip(group: group, count: members.count)
                                if !group.collapsed {
                                    ForEach(members) { store in
                                        TabItem(store: store, selected: store.id == app.selectedID, groupColor: Theme.lane(group.color))
                                            .id(store.id)
                                    }
                                }
                            }
                        }
                        Button {
                            app.select(nil)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 28, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New tab (⌘T)")
                    }
                    .padding(.vertical, 5)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabsWidthKey.self, value: geo.size.width)
                    })
                }
                // The strip is only as wide as its tabs; the rest of the bar drags the window.
                .frame(maxWidth: tabsWidth > 0 ? tabsWidth : nil)
                .layoutPriority(1)
                .onPreferenceChange(TabsWidthKey.self) { tabsWidth = $0 }
                .onChange(of: app.selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
            WindowDragArea().frame(minWidth: 24, maxWidth: .infinity)
            if app.tabs.count > 1 {
                Button {
                    app.showSwitcher = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                        Text("\(app.tabs.count)").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("All repositories (⌘P)")
            }
            VersionBadge()
            ProfileMenu()
                .padding(.horizontal, 10)
        }
        .frame(height: 38)
        .background(WindowDragArea())
        .background(Theme.chrome)
    }
}

/// Drag payload for reordering tabs (a distinct type so branch drags don't land on tabs).
struct TabDragItem: Codable, Transferable {
    let path: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

private struct TabsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The running version, always visible in the tab bar; its menu checks for updates.
struct VersionBadge: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Menu {
            Text("Dal \(updater.version)")
            Divider()
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Button("Release Notes") {
                if let url = URL(string: "https://github.com/Bur0/dal-releases/releases") { NSWorkspace.shared.open(url) }
            }
        } label: {
            Text("v\(updater.shortVersion)")
                .font(.system(size: 11).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.tertiary)
        .help("Dal \(updater.version) — click to check for updates")
        .accessibilityLabel("Dal version \(updater.version)")
    }
}

private struct GroupChip: View {
    @Environment(AppState.self) private var app
    let group: TabGroup
    let count: Int
    @State private var hovering = false

    var body: some View {
        let color = Theme.lane(group.color)
        HStack(spacing: 5) {
            if group.name.isEmpty {
                Circle().fill(color).frame(width: 10, height: 10)
            } else {
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if group.collapsed {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .opacity(0.85)
            }
        }
        .foregroundStyle(Theme.onLane(group.color))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(hovering ? 1 : 0.88)))
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { app.toggleCollapsed(group) } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab group \(group.name), \(count) tabs, \(group.collapsed ? "collapsed" : "expanded")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.toggleCollapsed(group) }
        .help(group.collapsed ? "Expand \(group.name) (\(count) tabs)" : "Collapse \(group.name)")
        .contextMenu {
            Button("Rename Group…") { app.promptRename(group) }
            Menu("Color") {
                ForEach(Theme.lanes.indices, id: \.self) { index in
                    Button {
                        var g = group
                        g.color = index
                        app.updateGroup(g)
                    } label: {
                        if index == group.color { Label(Theme.laneNames[index], systemImage: "checkmark") }
                        else { Text(Theme.laneNames[index]) }
                    }
                }
            }
            Button(group.collapsed ? "Expand" : "Collapse") { app.toggleCollapsed(group) }
            Divider()
            Button("Ungroup") { app.ungroup(group) }
            Button("Close Group", role: .destructive) { app.closeGroup(group) }
        }
    }
}

private struct TabItem: View {
    @Environment(AppState.self) private var app
    let store: RepoStore
    let selected: Bool
    var groupColor: Color? = nil
    @State private var hovering = false
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(store.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
            if store.busy != nil {
                ProgressView().controlSize(.mini)
            }
            Button {
                app.close(store)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(hovering ? Theme.hoverFill : .clear))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab (⌘W)")
            .accessibilityLabel("Close \(store.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.primary.opacity(0.09) : hovering ? Theme.hoverFill : .clear)
        )
        .overlay(alignment: .bottom) {
            if let groupColor {
                RoundedRectangle(cornerRadius: 1).fill(groupColor).frame(height: 2).padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.select(store) }
        .onHover { hovering = $0 }
        .help(store.url.path)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { app.select(store) }
        // Drag tabs to reorder; dropping onto a grouped tab moves it into that group.
        .draggable(TabDragItem(path: store.url.path)) {
            Text(store.name).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        }
        .dropDestination(for: TabDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            withAnimation(.easeOut(duration: 0.15)) { app.moveTab(path: item.path, before: store) }
            return true
        } isTargeted: { dropTarget = $0 }
        .overlay(alignment: .leading) {
            if dropTarget { Rectangle().fill(Color.accentColor).frame(width: 2).padding(.vertical, 4) }
        }
        .contextMenu {
            Menu("Add to Group") {
                Button("New Group…") { app.promptNewGroup(with: store) }
                if !app.groups.isEmpty { Divider() }
                ForEach(app.groups) { group in
                    Button(group.name.isEmpty ? "Unnamed group" : group.name) { app.add(store, to: group) }
                }
            }
            if app.group(of: store) != nil {
                Button("Remove from Group") { app.removeFromGroup(store) }
            }
            Divider()
            Button("Close Tab") { app.close(store) }
            Button("Close Other Tabs") {
                for other in app.tabs where other.id != store.id { app.close(other) }
            }
            Divider()
            Button("Reveal in Finder") { store.revealInFinder() }
            Button("Open in Terminal") { store.openTerminal() }
            Button("Copy Path") { store.copy(store.url.path, label: "Copied path") }
        }
    }
}

// MARK: Quick switcher (⌘P)

struct QuickSwitcher: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let id: String
        let path: String
        let store: RepoStore?
        let group: TabGroup?
    }

    private var entries: [Entry] {
        var list: [Entry] = app.tabs.map { Entry(id: $0.url.path, path: $0.url.path, store: $0, group: app.group(of: $0)) }
        let open = Set(list.map(\.path))
        list += app.recent.filter { !open.contains($0) }.map { Entry(id: $0, path: $0, store: nil, group: nil) }
        let q = query.trimmed
        guard !q.isEmpty else { return list }
        return list
            .compactMap { entry -> (Entry, Int)? in
                let name = (entry.path as NSString).lastPathComponent
                let haystack = name + " " + (entry.group?.name ?? "") + " " + entry.path
                guard let score = Self.fuzzyScore(q, in: haystack, nameLength: name.count) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Subsequence match; consecutive characters and matches in the name rank higher.
    static func fuzzyScore(_ query: String, in text: String, nameLength: Int) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var score = 0, qi = 0, last = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += (ti == last + 1 ? 6 : 1) + (ti < nameLength ? 4 : 0) + (ti == 0 ? 8 : 0)
            last = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to repository…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { choose(list) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onExitCommand { dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                            row(entry, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { highlighted = index; choose(list) }
                        }
                        if list.isEmpty {
                            Text("No matching repositories").font(.system(size: 12)).foregroundStyle(.tertiary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
            }
            .frame(height: 360)
            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "move")
                hint("↩", "open")
                hint("esc", "close")
                Spacer()
                Text("\(list.count) repositories").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(keys: keys)
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func row(_ entry: Entry, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.store == nil ? "clock" : "folder.fill")
                .foregroundStyle(entry.store == nil ? Color.secondary : Color.accentColor.opacity(0.85))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text((entry.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                Text((entry.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let group = entry.group {
                Text(group.name.isEmpty ? "group" : group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.lane(group.color)))
            }
            if entry.store == nil {
                Text("recent").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
    }

    private func choose(_ list: [Entry]) {
        guard highlighted < list.count else { return }
        let entry = list[highlighted]
        dismiss()
        if let store = entry.store {
            if let group = entry.group, group.collapsed { app.toggleCollapsed(group) }
            app.select(store)
        } else {
            app.open(URL(fileURLWithPath: entry.path))
        }
    }
}

// MARK: Welcome

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @EnvironmentObject private var updater: Updater
    @State private var dropTargeted = false

    var body: some View {
        // Two columns that share a top edge: who/what on the left, your work on the right.
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dal").font(.system(size: 26, weight: .semibold))
                        Text("Git client for macOS")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Version \(updater.version)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 4) {
                    WelcomeAction(symbol: "folder", title: "Open repository", shortcut: "⌘O") { app.openPanel() }
                    WelcomeAction(symbol: "square.and.arrow.down", title: "Clone repository", shortcut: "⇧⌘O") { app.showClone = true }
                    WelcomeAction(symbol: "plus.square", title: "New repository", shortcut: nil) { app.initPanel() }
                }
                Text("Or drop a folder anywhere in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 12)
            }
            .frame(width: 280, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(title: "Recent")
                    Spacer()
                    if !app.recent.isEmpty {
                        HStack(spacing: 6) {
                            Text("Jump to any").font(.system(size: 11)).foregroundStyle(.tertiary)
                            KeyCap(keys: "⌘P")
                        }
                    }
                }
                .frame(height: 20)
                if app.recent.isEmpty {
                    Text("Repositories you open appear here")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(app.recent.prefix(10), id: \.self) { path in
                            RecentRow(path: path)
                        }
                    }
                }
            }
            .frame(width: 440, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.06) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { app.open(url) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct WelcomeAction: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { KeyCap(keys: shortcut) }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    @Environment(AppState.self) private var app
    let path: String
    @State private var hovering = false

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(exists ? Color.secondary : Color.secondary.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if hovering {
                Button {
                    app.removeRecent(path)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove from list")
                .accessibilityLabel("Remove from recent")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hoverFill : .clear))
        .contentShape(Rectangle())
        .opacity(exists ? 1 : 0.55)
        .onTapGesture { if exists { app.open(URL(fileURLWithPath: path)) } }
        .onHover { hovering = $0 }
        .help(exists ? path : "This folder no longer exists")
    }
}
