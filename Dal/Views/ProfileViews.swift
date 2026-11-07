import SwiftUI

/// Tab-bar control for switching the global git identity.
struct ProfileMenu: View {
    @State private var profiles = ProfileStore.shared
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let identity = profiles.globalIdentity
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                AvatarView(name: identity.name, email: identity.email, size: 18)
                Text(profiles.active?.label ?? "Git config")
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering || open ? Theme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch the identity used for commits, pushes and GitHub")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProfilePicker(title: "Commit and push as",
                          selectedID: profiles.activeID,
                          noneTitle: "Git config",
                          noneDetail: profiles.systemEmail.isEmpty ? "System default" : "\(profiles.systemName) · \(profiles.systemEmail)") { id in
                profiles.setActive(id)
                open = false
            }
        }
    }
}

/// "Committing as …" line in the commit composer, with a per-repository override.
struct CommitIdentityLine: View {
    let store: RepoStore
    @State private var profiles = ProfileStore.shared
    @State private var open = false

    var body: some View {
        let identity = profiles.identity(for: store.url.path)
        let override = profiles.hasOverride(store.url.path)
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                AvatarView(name: identity.name, email: identity.email, size: 16)
                Text(identity.email.isEmpty ? "No git identity set" : "\(identity.name) <\(identity.email)>")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if override {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(identity.email.isEmpty ? Theme.deleted : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(override ? "This repository uses its own profile" : "Commits are recorded with this name and email")
        .popover(isPresented: $open, arrowEdge: .top) {
            ProfilePicker(title: "Identity for \(store.name)",
                          selectedID: override ? profiles.repoOverrides[store.url.path] : nil,
                          noneTitle: "Same as global",
                          noneDetail: profiles.active?.label ?? "Git config") { id in
                profiles.setOverride(id, for: store.url.path)
                open = false
            }
        }
    }
}

private struct ProfilePicker: View {
    let title: String
    let selectedID: UUID?
    let noneTitle: String
    let noneDetail: String
    let choose: (UUID?) -> Void
    @State private var profiles = ProfileStore.shared
    @AppStorage("settingsTab") private var settingsTab = "general"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            PickerRow(name: profiles.systemName, email: profiles.systemEmail, title: noneTitle, detail: noneDetail,
                      selected: selectedID == nil) { choose(nil) }
            ForEach(profiles.profiles) { profile in
                PickerRow(name: profile.authorName.isEmpty ? profiles.systemName : profile.authorName,
                          email: profile.authorEmail.isEmpty ? profiles.systemEmail : profile.authorEmail,
                          title: profile.label,
                          detail: [profile.authorEmail.isEmpty ? nil : profile.authorEmail,
                                   profile.githubAccount.map { "@\($0)" }].compactMap { $0 }.joined(separator: " · "),
                          selected: selectedID == profile.id) { choose(profile.id) }
            }
            Divider().padding(.vertical, 4)
            SettingsLink {
                Label(profiles.profiles.isEmpty ? "Add a Profile…" : "Manage Profiles…", systemImage: "person.badge.plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { settingsTab = "profiles" })
        }
        .padding(8)
        .frame(width: 300)
    }
}

private struct PickerRow: View {
    let name: String
    let email: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AvatarView(name: name, email: email, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Settings

struct ProfilesSettings: View {
    @State private var profiles = ProfileStore.shared
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(profiles.profiles) { profile in
                        HStack(spacing: 8) {
                            AvatarView(name: profile.authorName, email: profile.authorEmail, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.label).font(.system(size: 12, weight: .medium))
                                Text(profile.displayEmail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if profiles.activeID == profile.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    .help("Active profile")
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button {
                        selection = profiles.add().id
                    } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    .help("Add profile")
                    .accessibilityLabel("Add profile")
                    Button {
                        if let p = profiles.profiles.first(where: { $0.id == selection }) {
                            profiles.remove(p)
                            selection = profiles.profiles.first?.id
                        }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .help("Remove profile")
                    .accessibilityLabel("Remove profile")
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 210)

            Divider()

            Group {
                if let profile = profiles.profiles.first(where: { $0.id == selection }) {
                    ProfileEditor(profile: profile)
                        .id(profile.id)
                } else {
                    EmptyState(symbol: "person.2", title: "Git profiles",
                               message: "Add a profile for each identity you use — e.g. Personal and Work — and switch between them from the tab bar.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 400)
        .onAppear { selection = selection ?? profiles.profiles.first?.id }
        .task { await profiles.reload() }
    }
}

private struct ProfileEditor: View {
    @State var profile: GitProfile
    @State private var profiles = ProfileStore.shared

    var body: some View {
        Form {
            TextField("Profile name", text: $profile.label)
            Section("Commit identity") {
                TextField("Name", text: $profile.authorName, prompt: Text(profiles.systemName.isEmpty ? "Your Name" : profiles.systemName))
                TextField("Email", text: $profile.authorEmail, prompt: Text(profiles.systemEmail.isEmpty ? "you@example.com" : profiles.systemEmail))
                Text("Leave empty to use your global git config.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Authentication") {
                if profiles.ghAvailable {
                    Picker("GitHub account", selection: $profile.githubAccount) {
                        Text("Default gh login").tag(String?.none)
                        ForEach(profiles.ghAccounts, id: \.self) { Text("@\($0)").tag(String?.some($0)) }
                    }
                    Text(profiles.ghAccounts.count > 1 ? "Used for pull requests, issues and HTTPS pushes to GitHub."
                         : "Sign in to more accounts with `gh auth login` in Terminal; they'll appear here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Install the GitHub CLI (`brew install gh`) to switch GitHub accounts.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("SSH key", text: Binding(get: { profile.sshKeyPath ?? "" },
                                                       set: { profile.sshKeyPath = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Default ssh-agent key"))
                    Button("Choose…") { chooseKey() }
                }
            }
            HStack {
                Spacer()
                if profiles.activeID == profile.id {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                } else {
                    Button("Use This Profile") { profiles.setActive(profile.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile) { _, new in profiles.update(new) }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = "Choose the private key for this profile"
        if panel.runModal() == .OK, let url = panel.url {
            profile.sshKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
