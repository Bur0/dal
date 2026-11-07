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
        Task { await run(steps) }
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
            case "dumpmenu":
                let lines = NSApp.mainMenu?.items.flatMap { top in
                    (top.submenu?.items ?? []).map { "\(top.title) > \($0.title) [\($0.keyEquivalentModifierMask.rawValue) \($0.keyEquivalent)]" }
                } ?? []
                try? lines.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
            case "switcher":
                AppState.shared.showSwitcher = true
            case "quit":
                NSApp.terminate(nil)
            default:
                break
            }
        }
    }

    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
