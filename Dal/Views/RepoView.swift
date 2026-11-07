import SwiftUI

struct RepoView: View {
    @Bindable var store: RepoStore

    var body: some View {
        VStack(spacing: 0) {
            RepoToolbar(store: store)
            Divider()
            if let op = store.ongoing {
                OngoingBanner(store: store, operation: op)
                Divider()
            }
            HSplitView {
                SidebarView(store: store)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 380)
                CenterView(store: store)
                    .frame(minWidth: 460, maxWidth: .infinity)
                    .layoutPriority(1)
                DetailPanel(store: store)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            }
        }
        .overlay(alignment: .bottom) { ToastView(text: store.toast) }
        .alert(item: $store.alert) { alert in
            if let label = alert.confirmLabel, let action = alert.action {
                return Alert(title: Text(alert.title), message: Text(alert.message),
                             primaryButton: alert.destructive ? .destructive(Text(label), action: action)
                                                              : .default(Text(label), action: action),
                             secondaryButton: .cancel())
            }
            return Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(item: $store.input) { request in InputSheet(request: request) }
        .sheet(isPresented: $store.showCreatePR) { CreatePRSheet(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.scheduleRefresh()
        }
    }
}

private struct CenterView: View {
    @Bindable var store: RepoStore

    var body: some View {
        Group {
            if let focus = store.fileFocus {
                switch focus {
                case .conflict(let change):
                    ConflictView(store: store, change: change)
                default:
                    DiffView(store: store, focus: focus)
                }
            } else if !store.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.items.isEmpty {
                EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No commits yet",
                           message: "Stage some files and make your first commit.")
            } else {
                GraphView(store: store)
            }
        }
        .background(Theme.panel)
    }
}

private struct DetailPanel: View {
    @Bindable var store: RepoStore

    var body: some View {
        Group {
            switch store.selection {
            case .commit(let sha):
                if let commit = store.commit(sha) {
                    CommitDetailView(store: store, commit: commit)
                } else if let stash = store.stashes.first(where: { $0.sha == sha }) {
                    StashDetailView(store: store, stash: stash)
                } else {
                    EmptyState(symbol: "questionmark.circle", title: "Commit not loaded")
                }
            default:
                WorkingChangesView(store: store)
            }
        }
        .background(Theme.window)
    }
}

// MARK: Toolbar

struct RepoToolbar: View {
    @Bindable var store: RepoStore
    @Environment(AppState.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            repoAndBranch
            Spacer(minLength: 12)

            ToolbarButton(title: "Undo", symbol: "arrow.uturn.backward", help: store.undoLabel ?? "Nothing to undo") { store.undo() }
                .disabled(store.undoStack.isEmpty || store.busy != nil)
            ToolbarButton(title: "Redo", symbol: "arrow.uturn.forward", help: store.redoLabel ?? "Nothing to redo") { store.redo() }
                .disabled(store.redoStack.isEmpty || store.busy != nil)

            divider

            HStack(spacing: 0) {
                ToolbarButton(title: "Pull", symbol: "arrow.down.to.line",
                              help: "Pull (⌥⌘L)", badge: store.headRef?.behind ?? 0) { store.pull() }
                Menu {
                    Button("Fetch All") { store.fetch() }
                    Divider()
                    ForEach(PullMode.allCases) { mode in
                        Button(mode.title) { store.pull(mode) }
                    }
                    Divider()
                    Picker("Default Pull", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "pullMode") ?? PullMode.ffIfPossible.rawValue },
                        set: { UserDefaults.standard.set($0, forKey: "pullMode") })) {
                        ForEach(PullMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            .disabled(store.busy != nil)

            ToolbarButton(title: "Push", symbol: "arrow.up.to.line", help: "Push (⌥⌘P)",
                          badge: store.headRef?.ahead ?? 0) { store.push() }
                .disabled(store.busy != nil)
            ToolbarButton(title: "Fetch", symbol: "arrow.triangle.2.circlepath", help: "Fetch all remotes (⌥⌘F)") { store.fetch() }
                .disabled(store.busy != nil)

            divider

            ToolbarButton(title: "Branch", symbol: "arrow.triangle.branch", help: "Create branch (⌥⌘B)") { store.promptCreateBranch() }
            ToolbarButton(title: "Stash", symbol: "tray.and.arrow.down", help: "Stash all changes (⌥⌘S)") { store.stash() }
                .disabled(store.status.isEmpty || store.busy != nil)
            ToolbarButton(title: "Pop", symbol: "tray.and.arrow.up", help: "Pop latest stash (⇧⌥⌘S)") { store.popStash() }
                .disabled(store.stashes.isEmpty || store.busy != nil)

            divider

            ToolbarButton(title: "PR", symbol: "arrow.triangle.pull", help: "Create pull request") { store.openCreatePR() }
                .disabled(store.headBranch == nil || store.remotes.isEmpty)
            ToolbarButton(title: "Terminal", symbol: "terminal", help: "Open in Terminal (⌥⌘T)") { store.openTerminal() }

            Spacer(minLength: 12)

            if let busy = store.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy + "…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            searchField
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: store.busy)
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 26).padding(.horizontal, 4)
    }

    private var repoAndBranch: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("repository").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
                Menu {
                    ForEach(app.recent.filter { $0 != store.url.path }.prefix(10), id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { app.open(URL(fileURLWithPath: path)) }
                    }
                    Divider()
                    Button("Open Repository…") { app.openPanel() }
                    Button("Clone Repository…") { app.showClone = true }
                    Divider()
                    Button("Reveal in Finder") { store.revealInFinder() }
                    Button("Copy Path") { store.copy(store.url.path, label: "Copied path") }
                } label: {
                    Text(store.name).font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 1) {
                Text("branch").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
                Menu {
                    ForEach(store.localBranches) { ref in
                        Button {
                            if !ref.isHead { store.checkout(ref.name) }
                        } label: {
                            if ref.isHead { Label(ref.name, systemImage: "checkmark") } else { Text(ref.name) }
                        }
                    }
                    Divider()
                    Button("New Branch…") { store.promptCreateBranch() }
                } label: {
                    Text(store.headBranch ?? (store.headSha.map { "detached @ \(String($0.prefix(7)))" } ?? "no commits"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search commits", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { store.nextMatch(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { store.searchText = ""; searchFocused = false }
            if !store.searchText.isEmpty {
                Text("\(store.searchMatches.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 210, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : .clear))
        .help("Search by message, author, SHA or branch. Enter = next, ⇧Enter = previous.")
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
    }
}

// MARK: Banner & toast

private struct OngoingBanner: View {
    let store: RepoStore
    let operation: OngoingOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.modified)
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title).font(.system(size: 12, weight: .semibold))
                Text(store.status.conflicted.isEmpty
                     ? "All conflicts resolved. Continue to finish."
                     : "\(store.status.conflicted.count) conflicted file\(store.status.conflicted.count == 1 ? "" : "s"). Resolve them, then continue.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort", role: .destructive) { store.abortOperation() }
            Button("Continue") { store.continueOperation() }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.status.conflicted.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.modified.opacity(0.12))
    }
}

private struct ToastView: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.added)
                    Text(text).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
        .allowsHitTesting(false)
    }
}
