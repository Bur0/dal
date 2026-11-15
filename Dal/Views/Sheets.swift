import SwiftUI

struct InputSheet: View {
    let request: InputRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var problem: String? { request.validate?(text) }
    private var canSubmit: Bool { !text.trimmed.isEmpty && problem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(.system(size: 15, weight: .semibold))
                if let message = request.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            field
                .onChange(of: text) { _, new in
                    if let transform = request.transform {
                        let cleaned = transform(new)
                        if cleaned != new { text = cleaned }
                    }
                }
                .padding(.top, 12)
            // One status line: the validation problem in red, otherwise a quiet hint.
            Group {
                if let problem, !problem.isEmpty {
                    Text(problem).foregroundStyle(Theme.deleted)
                } else {
                    Text(request.hint ?? (request.multiline ? "⌘Return to save" : " ")).foregroundStyle(Theme.mutedText)
                }
            }
            .font(.system(size: 11))
            .padding(.top, 6)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, action: submit)
                    .keyboardShortcut(request.multiline ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: request.multiline ? 520 : 400)
        .onAppear {
            text = request.initial
            focused = true
        }
    }

    @ViewBuilder private var field: some View {
        if request.multiline {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: request.placeholder).font(.system(size: 13)).foregroundStyle(Theme.mutedText)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .focused($focused)
        } else {
            TextField("", text: $text, prompt: Text(verbatim: request.placeholder))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        dismiss()
        request.action(text)
    }
}

struct CloneSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cloneParent") private var parentPath = (NSHomeDirectory() as NSString).appendingPathComponent("repos")
    @State private var remote = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var cloning = false
    @State private var error: String?

    private var derivedName: String {
        let trimmed = remote.trimmed.replacingOccurrences(of: ".git", with: "")
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return last
    }

    private var destination: String { (parentPath as NSString).appendingPathComponent(name) }
    private var exists: Bool { !name.isEmpty && FileManager.default.fileExists(atPath: destination) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone a repository").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("URL").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                HStack {
                    TextField("", text: $remote, prompt: Text(verbatim: "https://github.com/owner/repo.git"))
                        .textFieldStyle(.roundedBorder)
                    // The clipboard is read only when asked — never in the background.
                    Button("Paste") {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmed { remote = clip }
                    }
                }
                    .onChange(of: remote) { _, _ in if !nameEdited { name = derivedName } }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Where").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                HStack {
                    Text((parentPath as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.subtleFill))
                    Button("Choose…") { choose() }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Folder name").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                TextField("repo", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    .textFieldStyle(.roundedBorder)
                if exists {
                    Text("A folder with this name already exists.").font(.system(size: 11)).foregroundStyle(Theme.deleted)
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.deleted).textSelection(.enabled)
                    .lineLimit(6)
            }
            HStack {
                if cloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(cloning)
                Button("Clone") { clone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote.trimmed.isEmpty || name.isEmpty || exists || cloning)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parentPath)
        if panel.runModal() == .OK, let url = panel.url { parentPath = url.path }
    }

    private func clone() {
        cloning = true
        error = nil
        try? FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
        Task {
            let failure = await app.clone(url: remote.trimmed, into: URL(fileURLWithPath: parentPath), name: name)
            cloning = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}

struct CreatePRSheet: View {
    let store: RepoStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var head = ""
    @State private var draft = false
    @State private var working = false
    @State private var error: String?

    private var branchNames: [String] { store.localBranches.map(\.name) }
    private var remoteBranchNames: [String] {
        Array(Set(store.remoteBranches.map(\.branchName))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.system(size: 15, weight: .semibold))
            // Labels outside the pickers so both pickers share the width equally.
            HStack(spacing: 8) {
                Text("From").foregroundStyle(Theme.secondaryText)
                Picker("From", selection: $head) {
                    ForEach(branchNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right").foregroundStyle(Theme.secondaryText).padding(.horizontal, 4)
                Text("Into").foregroundStyle(Theme.secondaryText)
                Picker("Into", selection: $base) {
                    if remoteBranchNames.isEmpty { Text("No remote branches").tag("") }
                    ForEach(remoteBranchNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(remoteBranchNames.isEmpty)
            }
            .font(.system(size: 13))
            if remoteBranchNames.isEmpty {
                Text("This repository has no remote branches yet. Add a remote and push a branch first.")
                    .font(.system(size: 11)).foregroundStyle(Theme.modified)
            }
            TextField("", text: $title, prompt: Text("Title"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $bodyText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if bodyText.isEmpty {
                    Text("Description (Markdown)").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                        .padding(.horizontal, 9).padding(.vertical, 5).allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator))
            Toggle("Create as draft", isOn: $draft).toggleStyle(.checkbox)
            Text("The branch is pushed first if it isn't on the remote yet. Uses the GitHub CLI (gh).")
                .font(.system(size: 11)).foregroundStyle(Theme.mutedText)
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.deleted)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Pull Request") {
                    working = true
                    error = nil
                    Task {
                        let failure = await store.createPullRequest(title: title.trimmed, body: bodyText, base: base,
                                                                    head: head, draft: draft)
                        working = false
                        if let failure { error = failure } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || head.isEmpty || base.isEmpty || head == base || working)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            head = store.createPRHead ?? store.headBranch ?? branchNames.first ?? ""
            if let commit = store.localBranches.first(where: { $0.name == head }).flatMap({ store.commit($0.target) }) {
                title = commit.subject
                bodyText = commit.body
            }
            let fallback = ["main", "master", "develop"].first { remoteBranchNames.contains($0) } ?? remoteBranchNames.first ?? ""
            base = fallback
            if let remoteDefault = await GitHub.defaultBranch(in: store.url, env: store.githubEnv), remoteBranchNames.contains(remoteDefault) {
                base = remoteDefault
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var updater: Updater
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ProfilesSettings()
                .tabItem { Label("Profiles", systemImage: "person.2") }
                .tag("profiles")
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var updater: Updater
    @AppStorage("useGravatar") private var useGravatar = true
    @AppStorage("commitLimit") private var commitLimit = 2000
    @AppStorage("pullMode") private var pullMode = PullMode.ffIfPossible.rawValue
    @AppStorage(AppTheme.key) private var theme = AppTheme.system.rawValue

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, value in AppTheme.apply(AppTheme(rawValue: value) ?? .system) }
            }
            Section("Graph") {
                Toggle("Show avatars from Gravatar / GitHub", isOn: $useGravatar)
                Text("Sends a hash of each author's email to gravatar.com. Turn off to use initials only.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Picker("Commits loaded at a time", selection: $commitLimit) {
                    Text("1,000").tag(1000)
                    Text("2,000").tag(2000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                }
            }
            Section("Pull") {
                Picker("Default pull", selection: $pullMode) {
                    ForEach(PullMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("Download updates in the background", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                Text("When an update is ready, “Update ready · Restart Dal” appears at the top right. It also installs when you quit.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                HStack {
                    Text("Version \(updater.version)").foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
