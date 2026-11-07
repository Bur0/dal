import SwiftUI

struct WorkingChangesView: View {
    @Bindable var store: RepoStore
    private enum Field { case summary, body }
    @FocusState private var focus: Field?
    @AppStorage("changes.unstagedOpen") private var unstagedOpen = true
    @AppStorage("changes.stagedOpen") private var stagedOpen = true

    private var status: WorkingStatus { store.status }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                // Lazy, so a working tree with thousands of changed files stays responsive.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !status.conflicted.isEmpty {
                        conflictSection
                    }
                    fileSection(title: "Unstaged files", files: status.unstaged, staged: false, isOpen: $unstagedOpen)
                    fileSection(title: "Staged files", files: status.staged, staged: true, isOpen: $stagedOpen)
                    if status.isEmpty && store.loaded {
                        EmptyState(symbol: "checkmark.circle", title: "Working tree clean",
                                   message: "Edit files in this repository and they'll appear here.")
                            .padding(.top, 30)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: store.fileFocus) { _, focus in
                guard let focus else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(focus) }
            }
            }
            Divider()
            composer
        }
        .onAppear(perform: updateFileOrder)
        .onChange(of: status) { _, _ in updateFileOrder() }
        .onChange(of: unstagedOpen) { _, _ in updateFileOrder() }
        .onChange(of: stagedOpen) { _, _ in updateFileOrder() }
    }

    /// The order ↑/↓ follows in a diff: what's visible here, top to bottom. Conflicts are left
    /// out; the merge tool uses ⌘↑/⌘↓ for its own conflicts.
    private func updateFileOrder() {
        store.fileOrder = (unstagedOpen ? status.unstaged.map { FileFocus.working($0, staged: false) } : [])
            + (stagedOpen ? status.staged.map { FileFocus.working($0, staged: true) } : [])
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.isEmpty ? "No changes" : "\(status.fileCount) file change\(status.fileCount == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Text("on \(store.headBranch ?? "detached HEAD")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !status.isEmpty {
                Button {
                    store.stash()
                } label: {
                    Label("Stash", systemImage: "tray.and.arrow.down")
                }
                .controlSize(.small)
                .help("Stash all changes including new files")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionTitle(title: "Conflicts", count: status.conflicted.count)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            ForEach(status.conflicted) { change in
                FileRow(change: change, selected: store.fileFocus == .conflict(change),
                        actionTitle: "Resolve", actionSymbol: "wand.and.stars", action: {
                    store.fileFocus = .conflict(change)
                }) {
                    store.fileFocus = .conflict(change)
                }
                .contextMenu {
                    Button("Take Current (Ours)") { store.takeSide(change, ours: true) }
                    Button("Take Incoming (Theirs)") { store.takeSide(change, ours: false) }
                    Button("Mark as Resolved") { store.markResolved(change) }
                    Divider()
                    Button("Open File") { store.openFile(change.path) }
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func fileSection(title: String, files: [FileChange], staged: Bool, isOpen: Binding<Bool>) -> some View {
        Group {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isOpen.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                            .foregroundStyle(Theme.mutedText)
                        SectionTitle(title: title, count: files.count)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !files.isEmpty {
                    if !staged {
                        // Destructive actions live one click away, not next to "Stage All".
                        Menu {
                            Button("Stash All Changes") { store.stash() }
                            Divider()
                            Button("Discard All Changes…", role: .destructive) { store.discardAll() }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                                .frame(width: 22, height: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(Theme.secondaryText)
                        .help("More actions")
                        .accessibilityLabel("More actions for unstaged files")
                    }
                    Button(staged ? "Unstage All" : "Stage All") {
                        staged ? store.unstageAll() : store.stageAll()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(staged ? nil : KeyboardShortcut("a", modifiers: [.command, .shift]))
                    .help(staged ? "Unstage everything" : "Stage all changes (⇧⌘A)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if isOpen.wrappedValue {
                ForEach(files) { change in
                    FileRow(change: change,
                            selected: store.fileFocus == .working(change, staged: staged),
                            actionTitle: staged ? "Unstage" : "Stage",
                            actionSymbol: staged ? "minus" : "plus",
                            action: { staged ? store.unstage(change) : store.stage(change) },
                            onDoubleClick: { staged ? store.unstage(change) : store.stage(change) }) {
                        store.fileFocus = .working(change, staged: staged)
                    }
                    .id(FileFocus.working(change, staged: staged))
                    .contextMenu { fileMenu(change, staged: staged) }
                }
                if files.isEmpty {
                    Text(staged ? "Staged files go into the next commit" : "Nothing to stage")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
            Color.clear.frame(height: 8)
        }
    }

    @ViewBuilder private func fileMenu(_ change: FileChange, staged: Bool) -> some View {
        if staged {
            Button("Unstage") { store.unstage(change) }
        } else {
            Button("Stage") { store.stage(change) }
            Button("Discard Changes", role: .destructive) { store.discard(change) }
            if change.kind == .untracked {
                Button("Ignore") { store.ignore(change) }
            }
        }
        Divider()
        Button("Open File") { store.openFile(change.path) }
        Button("Reveal in Finder") { store.revealInFinder(change.path) }
        Button("Copy Path") { store.copy(change.path, label: "Copied path") }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Amend", isOn: Binding(get: { store.amend }, set: { store.setAmend($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Rewrite the last commit with the staged changes and this message")
            }
            HStack(spacing: 6) {
                TextField("Summary", text: $store.commitSummary)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .summary)
                    .onSubmit { focus = .body }   // ⌘↩ commits; Return moves on to the description
                // Shown once you type: amber past 50 (git's soft limit), red past 72.
                if !store.commitSummary.isEmpty {
                    Text("\(72 - store.commitSummary.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(store.commitSummary.count > 72 ? Theme.deleted
                                         : store.commitSummary.count > 50 ? Theme.modified : Theme.mutedText)
                        .help("Summaries read best under 50 characters; 72 is the limit most tools show in full")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus == .summary ? Color.accentColor.opacity(0.7) : Theme.separator))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.commitBody)
                    .focused($focus, equals: .body)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
                if store.commitBody.isEmpty {
                    Text("Description (optional)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.mutedText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator))

            CommitIdentityLine(store: store)

            Button {
                store.commit()
            } label: {
                Text(commitButtonTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canCommit)
            .keyboardShortcut(.return, modifiers: .command)
            .help(commitHelp)
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: .focusCommitMessage)) { _ in focus = .summary }
    }

    /// The button says what's missing instead of just going grey.
    private var commitButtonTitle: String {
        if !status.conflicted.isEmpty { return "Resolve conflicts to commit" }
        let n = status.staged.count
        if !store.amend && n == 0 { return "Stage files to commit" }
        if store.commitSummary.trimmed.isEmpty { return "Write a summary to commit" }
        if store.amend { return "Amend Previous Commit" }
        return "Commit \(n) File\(n == 1 ? "" : "s")"
    }

    private var commitHelp: String {
        if !status.conflicted.isEmpty { return "Resolve conflicts first" }
        if store.commitSummary.trimmed.isEmpty { return "Write a summary to commit" }
        return "Commit (⌘↩)"
    }
}
