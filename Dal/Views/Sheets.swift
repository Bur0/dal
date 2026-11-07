import SwiftUI

struct InputSheet: View {
    let request: InputRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var problem: String? { request.validate?(text) }
    private var canSubmit: Bool { !text.trimmed.isEmpty && problem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.system(size: 15, weight: .semibold))
            if let message = request.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextField(request.placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(submit)
            Text(problem?.isEmpty == false ? problem! : " ")
                .font(.system(size: 11))
                .foregroundStyle(Theme.deleted)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            text = request.initial
            focused = true
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
                Text("URL").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("https://github.com/owner/repo.git  or  git@github.com:owner/repo.git", text: $remote)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: remote) { _, _ in if !nameEdited { name = derivedName } }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Where").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                Text("Folder name").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                    Text("Cloning…").font(.system(size: 12)).foregroundStyle(.secondary)
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

    private var branchNames: [String] { store.localBranches.map(\.name) }
    private var remoteBranchNames: [String] {
        Array(Set(store.remoteBranches.map(\.branchName))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create pull request").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Picker("From", selection: $head) {
                    ForEach(branchNames, id: \.self) { Text($0).tag($0) }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("Into", selection: $base) {
                    ForEach(remoteBranchNames, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $bodyText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if bodyText.isEmpty {
                    Text("Description (Markdown)").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 5).allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator))
            Toggle("Create as draft", isOn: $draft).toggleStyle(.checkbox)
            Text("The branch is pushed first if it isn't on the remote yet. Uses the GitHub CLI (gh).")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Pull Request") {
                    working = true
                    Task {
                        let ok = await store.createPullRequest(title: title.trimmed, body: bodyText, base: base,
                                                               head: head, draft: draft)
                        working = false
                        if ok { dismiss() }
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

    var body: some View {
        Form {
            Section("Graph") {
                Toggle("Show avatars from Gravatar / GitHub", isOn: $useGravatar)
                Text("Sends a hash of each author's email to gravatar.com. Turn off to use initials only.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                HStack {
                    Text("Version \(updater.version)").foregroundStyle(.secondary)
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
