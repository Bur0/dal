import SwiftUI

@main
struct DalApp: App {
    @State private var app = AppState.shared
    @StateObject private var updater = Updater()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// True when launched as the host for unit tests.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if Self.isTestHost {
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        // Folder paths on the command line are handled by AppState, not as AppKit "open document"
        // events (those suppress the main window at launch).
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        AppState.shared.openCommandLineFolders()
        #if DEBUG
        DebugSnapshot.startIfRequested()
        #endif
    }

    var body: some Scene {
        Window("Dal", id: "main") {
            MainWindow()
                .environment(app)
                .environmentObject(updater)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(app: app, updater: updater) }

        Settings {
            SettingsView(updater: updater)
        }
    }
}

/// Handles folders opened from Finder, the Dock icon, or `open -a Dal <folder>`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowItemTitle = "Main Window"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !DalApp.isTestHost else { return }
        // SwiftUI restores "no windows" if the app last quit with its window closed; Dal is a
        // single-window app, so make sure the window is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { Self.showMainWindowIfNeeded() } }
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Self.showMainWindowIfNeeded() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppState.shared.open(url) }
            Self.showMainWindowIfNeeded()
        }
    }

    @MainActor static func showMainWindowIfNeeded() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        guard !hasWindow else { return }
        // Window ▸ Main Window calls SwiftUI's openWindow(id: "main").
        let item = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).flatMap(\.items).first { $0.title == mainWindowItemTitle }
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct AppCommands: Commands {
    let app: AppState
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    private var store: RepoStore? { app.current }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.select(nil) }
                .keyboardShortcut("t")
            Button("Go to Repository…") { app.showSwitcher = true }
                .keyboardShortcut("p")
                .disabled(app.tabs.isEmpty && app.recent.isEmpty)
            Button("Next Tab") { app.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { app.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Open Repository…") { app.openPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { app.showClone = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Init Repository…") { app.initPanel() }
        }

        // ⌘W closes the tab (like Chrome); ⇧⌘W closes the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let store { app.close(store) } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandGroup(after: .windowArrangement) {
            Button(AppDelegate.mainWindowItemTitle) { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            ForEach(1..<10) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { app.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(app.tabs.isEmpty)
            }
        }

        CommandMenu("Repository") {
            Button("Refresh") { Task { await store?.refresh() } }
                .keyboardShortcut("r")
            Divider()
            Button("Fetch All") { store?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Pull") { store?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Push") { store?.push() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Create Branch…") { store?.promptCreateBranch() }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Button("Stash Changes") { store?.stash() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(store?.status.isEmpty ?? true)
            Button("Pop Stash") { store?.popStash() }
                .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(store?.stashes.isEmpty ?? true)
            Button("Create Pull Request…") { store?.openCreatePR() }
                .disabled(store?.headBranch == nil)
            Divider()
            Button(store?.undoLabel ?? "Undo") { store?.undo() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(store?.undoLabel == nil)
            Button(store?.redoLabel ?? "Redo") { store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                .disabled(store?.redoLabel == nil)
            Divider()
            Button("Find Commit") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                .keyboardShortcut("f")
            Button("Show Working Changes") { store?.selectWIP() }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Write Commit Message") {
                store?.selectWIP()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: .focusCommitMessage, object: nil)
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Open in Terminal") { store?.openTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Reveal in Finder") { store?.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("dal.focusSearch")
    static let focusCommitMessage = Notification.Name("dal.focusCommitMessage")
}
