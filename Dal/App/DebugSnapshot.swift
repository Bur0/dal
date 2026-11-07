#if DEBUG
import AppKit

/// Development helper: `DAL_SNAPSHOT=/tmp/shot.png` writes a PNG of the main window after launch,
/// and `DAL_SCRIPT="select:1;focus:file:0;wait:1;shot:/tmp/b.png"` drives a few UI states.
/// Lets UI changes be checked without screen-recording permission. Not compiled into releases.
@MainActor
enum DebugSnapshot {
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        var steps: [String] = []
        if let script = env["DAL_SCRIPT"] { steps += script.split(separator: ";").map(String.init) }
        if let path = env["DAL_SNAPSHOT"] { steps += ["wait:\(env["DAL_SNAPSHOT_DELAY"] ?? "4")", "shot:\(path)"] }
        guard !steps.isEmpty else { return }
        // A background app gets App Nap'd and its timers stall; keep it awake while scripted.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Debug snapshot script")
        Task {
            await run(steps)
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private static func run(_ steps: [String]) async {
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            let store = AppState.shared.current
            switch parts[0] {
            case "wait":
                try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "shot":
                capture(to: arg)
            case "select":
                if let store, let index = Int(arg), index < store.items.count {
                    let item = store.items[index]
                    if item.isWIP { store.selection = .wip } else { store.select(commit: item.id) }
                }
            case "wip":
                store?.selectWIP()
            case "unstaged":
                if let store, let index = Int(arg), index < store.status.unstaged.count {
                    store.fileFocus = .working(store.status.unstaged[index], staged: false)
                }
            case "search":
                store?.searchText = arg
            case "size":
                let dims = arg.split(separator: "x").compactMap { Double($0) }
                if dims.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                    window.setContentSize(NSSize(width: dims[0], height: dims[1]))
                }
            case "appearance":
                NSApp.appearance = NSAppearance(named: arg == "dark" ? .darkAqua : .aqua)
            case "group":
                // group:Name:0,1  → put tabs 0 and 1 in a new group
                let bits = arg.split(separator: ":", maxSplits: 1).map(String.init)
                let app = AppState.shared
                var group = TabGroup(name: bits[0], color: app.groups.count + 1)
                app.groups.append(group)
                for i in (bits.count > 1 ? bits[1] : "").split(separator: ",").compactMap({ Int($0) }) where i < app.tabs.count {
                    app.add(app.tabs[i], to: group)
                }
                group = app.groups.last!
                _ = group
            case "collapse":
                let app = AppState.shared
                if let i = Int(arg), i < app.groups.count { app.toggleCollapsed(app.groups[i]) }
            case "hoverrow":
                if let store, let index = Int(arg), index < store.items.count {
                    store.debugHoveredRow = store.items[index].id
                }
            case "expandrefs":
                if let store, let index = Int(arg), index < store.items.count {
                    store.debugExpandedRefs = store.items[index].id
                }
            case "conflictpick":
                store?.debugConflictPick = arg
            case "filemove":
                if let delta = Int(arg) { store?.moveFileFocus(delta) }
            case "tab":
                let app = AppState.shared
                if let i = Int(arg), i < app.tabs.count { app.select(app.tabs[i]) }
            case "open":
                AppState.shared.open(URL(fileURLWithPath: arg))
            case "welcome":
                AppState.shared.select(nil)
            case "conflict":
                if let store, let index = Int(arg), index < store.status.conflicted.count {
                    store.fileFocus = .conflict(store.status.conflicted[index])
                }
            case "commitfile":
                // Opens the diff of the selected commit's first file.
                if let store, case .commit(let sha) = store.selection, let commit = store.commit(sha) {
                    Task {
                        let changes = (try? await store.git.changes(sha: sha, parent: commit.parents.first)) ?? []
                        if let first = changes.first {
                            store.fileFocus = .commit(sha: sha, parent: commit.parents.first, change: first)
                        }
                    }
                }
            case "dumpeffects":
                // Lists translucent views that blend with the desktop (invisible in snapshots).
                var found: [String] = []
                func walk(_ view: NSView) {
                    if let effect = view as? NSVisualEffectView, effect.blendingMode == .behindWindow, !effect.isHidden,
                       effect.alphaValue > 0, effect.frame.width > 1 {
                        found.append("\(effect.material.rawValue) \(NSStringFromRect(effect.convert(effect.bounds, to: nil)))")
                    }
                    view.subviews.forEach(walk)
                }
                if let root = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview { walk(root) }
                try? found.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            case "dumpwindows":
                let lines = NSApp.windows.map { "\($0.className) visible=\($0.isVisible) title=\($0.title) frame=\(NSStringFromRect($0.frame)) sheetParent=\($0.sheetParent != nil) content=\($0.contentView != nil)" }
                let header = "policy=\(NSApp.activationPolicy().rawValue) testHost=\(DalApp.isTestHost) windows=\(NSApp.windows.count)"
                try? ([header] + lines).joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            case "dumpmenu":
                let lines = NSApp.mainMenu?.items.flatMap { top in
                    (top.submenu?.items ?? []).map { "\(top.title) > \($0.title) [\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)]" }
                } ?? []
                try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            case "switcher":
                AppState.shared.showSwitcher = true
            case "branchsheet":
                store?.promptCreateBranch()
            case "clonesheet":
                AppState.shared.showClone = true
            case "prsheet":
                store?.openCreatePR()
            case "discardalert":
                if let store, let change = store.status.unstaged.first { store.discard(change) }
            case "toast":
                store?.showToast(arg.isEmpty ? "Pushed main → origin/main" : arg)
            case "dismiss":
                store?.input = nil
                store?.alert = nil
                store?.showCreatePR = false
                AppState.shared.showClone = false
                AppState.shared.showSwitcher = false
                for window in NSApp.windows where window.isVisible && window.title.contains("Settings") { window.close() }
            case "settings":
                if !arg.isEmpty { UserDefaults.standard.set(arg, forKey: "settingsTab") }
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case "shotsheet":
                // The front sheet (or alert) attached to the main window.
                if let sheet = NSApp.windows.compactMap(\.attachedSheet).first { capture(sheet, to: arg) }
            case "shotwin":
                // shotwin:Settings:/path — first visible window whose title contains the text.
                let bits = arg.split(separator: ":", maxSplits: 1).map(String.init)
                if bits.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.title.contains(bits[0]) }) {
                    capture(window, to: bits[1])
                }
            case "quit":
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }

    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) else { return }
        capture(window, to: path)
    }

    static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
