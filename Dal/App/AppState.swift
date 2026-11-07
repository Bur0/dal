import Foundation
import AppKit
import Observation

/// A Chrome-style tab group. Membership is stored by repository path so it survives restarts.
struct TabGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: Int
    var collapsed = false
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var tabs: [RepoStore] = []
    var selectedID: UUID?
    var recent: [String] = []
    var showClone = false
    var showSwitcher = false
    var alert: AppAlert?
    var input: InputRequest?

    var groups: [TabGroup] = []
    /// repository path → group id
    var membership: [String: UUID] = [:]

    var current: RepoStore? { tabs.first { $0.id == selectedID } }

    private let recentKey = "recentRepositories"
    private let openKey = "openRepositories"
    private let selectedKey = "selectedRepository"
    private let groupsKey = "tabGroups"
    private let membershipKey = "tabGroupMembership"

    init() {
        recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        // A unit-test host must not open (and run git in) the user's repositories.
        let openPaths = DalApp.isTestHost ? [] : (UserDefaults.standard.stringArray(forKey: openKey) ?? [])
        let selectedPath = UserDefaults.standard.string(forKey: selectedKey)
        if let data = UserDefaults.standard.data(forKey: groupsKey),
           let saved = try? JSONDecoder().decode([TabGroup].self, from: data) { groups = saved }
        if let data = UserDefaults.standard.data(forKey: membershipKey),
           let saved = try? JSONDecoder().decode([String: UUID].self, from: data) { membership = saved }
        for path in openPaths where FileManager.default.fileExists(atPath: path) {
            let store = RepoStore(url: URL(fileURLWithPath: path))
            tabs.append(store)
            if path == selectedPath { selectedID = store.id }
        }
        if selectedID == nil { selectedID = tabs.first?.id }
        // Only the visible tab watches the disk; background tabs refresh when selected.
        current?.activate()
    }

    /// `Dal.app/Contents/MacOS/Dal <folder>` or `open -a Dal --args <folder>`
    func openCommandLineFolders() {
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                open(URL(fileURLWithPath: arg))
            }
        }
    }

    func select(_ store: RepoStore?) {
        guard store?.id != selectedID else { return }
        current?.deactivate()
        selectedID = store?.id
        store?.activate()
        if let store, store.githubStale {
            store.githubStale = false
            Task { await store.loadGitHub() }
        }
        persist()
    }

    func open(_ url: URL) {
        Task {
            let result = try? await Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: url)
            guard let result, result.status == 0 else {
                alert = AppAlert(title: "Not a Git repository",
                                 message: "\(url.path) isn't inside a Git repository. Use Init to create one.")
                return
            }
            let root = URL(fileURLWithPath: result.stdout.utf8.trimmed)
            if let existing = tabs.first(where: { $0.url.standardizedFileURL == root.standardizedFileURL }) {
                select(existing)
                return
            }
            let store = RepoStore(url: root)
            // New tabs open next to the current one, inside its group (like Chrome).
            if let current, let index = tabs.firstIndex(where: { $0.id == current.id }) {
                tabs.insert(store, at: index + 1)
                if let group = membership[current.url.path], membership[root.path] == nil {
                    membership[root.path] = group
                }
            } else {
                tabs.append(store)
            }
            select(store)
            addRecent(root.path)
            normalizeGroups()
            persist()
        }
    }

    func close(_ store: RepoStore) {
        guard let index = tabs.firstIndex(where: { $0.id == store.id }) else { return }
        store.deactivate()
        tabs.remove(at: index)
        if selectedID == store.id {
            selectedID = nil
            select(tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)])
        }
        membership[store.url.path] = nil
        pruneEmptyGroups()
        persist()
    }

    /// ⌘1…⌘8 pick the nth visible tab, ⌘9 the last one (Chrome behaviour).
    func selectTab(number: Int) {
        let visible = tabs.filter { group(of: $0)?.collapsed != true }
        guard !visible.isEmpty else { return }
        select(number == 9 ? visible[visible.count - 1] : visible[min(number, visible.count) - 1])
    }

    /// Drag-and-drop reordering in the tab bar. The moved tab joins the group of the tab it was
    /// dropped on (or leaves its group when dropped on an ungrouped tab).
    func moveTab(path: String, before target: RepoStore) {
        guard let from = tabs.firstIndex(where: { $0.url.path == path }), tabs[from].id != target.id else { return }
        let moved = tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0.id == target.id }) ?? tabs.count
        tabs.insert(moved, at: to)
        membership[path] = membership[target.url.path]
        pruneEmptyGroups()
        normalizeGroups()
        persist()
    }

    /// ⇧⌘] / ⇧⌘[ — skips tabs hidden inside collapsed groups.
    func selectAdjacent(_ delta: Int) {
        let visible = tabs.filter { group(of: $0)?.collapsed != true }
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedID } ?? -1
        select(visible[(index + delta + visible.count) % visible.count])
    }

    /// Identity changed: the visible repo reloads GitHub data with the new account.
    func profileChanged() {
        for store in tabs where store.loaded { store.githubStale = true }
        if let current {
            current.githubStale = false
            Task { await current.loadGitHub() }
        }
    }

    // MARK: Tab groups

    func group(of store: RepoStore) -> TabGroup? {
        membership[store.url.path].flatMap { id in groups.first { $0.id == id } }
    }

    func tabs(in group: TabGroup) -> [RepoStore] {
        tabs.filter { membership[$0.url.path] == group.id }
    }

    func promptNewGroup(with store: RepoStore) {
        input = InputRequest(title: "New tab group", message: "Groups keep related repositories together in the tab bar.",
                             placeholder: "Work, Personal, Client…", confirmLabel: "Create Group") { [weak self] name in
            guard let self else { return }
            let used = Set(groups.map(\.color))
            let color = (0..<Theme.lanes.count).first { !used.contains($0) } ?? groups.count
            let group = TabGroup(name: name.trimmed, color: color)
            groups.append(group)
            add(store, to: group)
        }
    }

    func add(_ store: RepoStore, to group: TabGroup) {
        membership[store.url.path] = group.id
        normalizeGroups()
        persist()
    }

    func removeFromGroup(_ store: RepoStore) {
        membership[store.url.path] = nil
        pruneEmptyGroups()
        normalizeGroups()
        persist()
    }

    func toggleCollapsed(_ group: TabGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i].collapsed.toggle()
        // Collapsing the group that holds the visible tab moves focus to a tab outside it.
        if groups[i].collapsed, let current, membership[current.url.path] == group.id,
           let other = tabs.first(where: { membership[$0.url.path] != group.id }) {
            select(other)
        }
        persist()
    }

    func updateGroup(_ group: TabGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i] = group
        persist()
    }

    func promptRename(_ group: TabGroup) {
        input = InputRequest(title: "Rename group", placeholder: "Group name", initial: group.name,
                             confirmLabel: "Rename") { [weak self] name in
            var g = group
            g.name = name.trimmed
            self?.updateGroup(g)
        }
    }

    func ungroup(_ group: TabGroup) {
        for (path, id) in membership where id == group.id { membership[path] = nil }
        groups.removeAll { $0.id == group.id }
        persist()
    }

    func closeGroup(_ group: TabGroup) {
        for store in tabs(in: group) { close(store) }
        groups.removeAll { $0.id == group.id }
        persist()
    }

    /// Keeps each group's tabs next to each other, anchored at the group's first tab.
    private func normalizeGroups() {
        var result: [RepoStore] = []
        var placed = Set<UUID>()
        for store in tabs {
            if let id = membership[store.url.path] {
                guard !placed.contains(id) else { continue }
                placed.insert(id)
                result += tabs.filter { membership[$0.url.path] == id }
            } else {
                result.append(store)
            }
        }
        tabs = result
    }

    private func pruneEmptyGroups() {
        let openPaths = Set(tabs.map(\.url.path))
        groups.removeAll { group in !membership.contains { $0.value == group.id && openPaths.contains($0.key) } }
        let ids = Set(groups.map(\.id))
        membership = membership.filter { ids.contains($0.value) }
    }

    func move(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func addRecent(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 15 { recent.removeLast(recent.count - 15) }
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    func removeRecent(_ path: String) {
        recent.removeAll { $0 == path }
        UserDefaults.standard.set(recent, forKey: recentKey)
    }

    private func persist() {
        UserDefaults.standard.set(tabs.map(\.url.path), forKey: openKey)
        UserDefaults.standard.set(current?.url.path, forKey: selectedKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: groupsKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(membership), forKey: membershipKey)
    }

    // MARK: Panels

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func initPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Initialize"
        panel.message = "Choose a folder to turn into a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = try? await Shell.run("git", ["init"], cwd: url)
            if result?.status == 0 { open(url) } else {
                alert = AppAlert(title: "Init failed", message: result?.stderr.utf8 ?? "git init failed")
            }
        }
    }

    func clone(url remote: String, into parent: URL, name: String) async -> String? {
        let result: Shell.Result
        do {
            // Use the active profile so private repos clone with its SSH key / GitHub account.
            result = try await Shell.run("git", ["clone", "--", remote, name], cwd: parent,
                                         env: ProfileStore.shared.environment(for: ""))
        } catch {
            return error.localizedDescription
        }
        guard result.status == 0 else { return Git.clean(result.stderr.utf8) }
        open(parent.appendingPathComponent(name))
        return nil
    }
}
