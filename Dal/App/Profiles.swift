import Foundation
import AppKit
import Observation

/// An identity Dal uses for git and GitHub. Applied only to commands Dal runs, through
/// environment variables — the user's ~/.gitconfig and gh login are never modified.
struct GitProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    var authorName: String = ""
    var authorEmail: String = ""
    /// A login from `gh auth status`; its token is used for GitHub API calls and HTTPS pushes.
    var githubAccount: String?
    /// Private key used for SSH remotes (e.g. ~/.ssh/id_ed25519_work).
    var sshKeyPath: String?

    var displayEmail: String { authorEmail.isEmpty ? "git config email" : authorEmail }
}

@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    var profiles: [GitProfile] = []
    /// nil = use the system git config as-is.
    var activeID: UUID?
    /// repository path → profile id (overrides the global choice)
    var repoOverrides: [String: UUID] = [:]

    var ghAccounts: [String] = []
    var ghActiveAccount: String?
    var ghAvailable = true
    var systemName = ""
    var systemEmail = ""

    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var ghPath: String?

    private let key = "gitProfiles"
    private let activeKey = "activeProfile"
    private let overridesKey = "repoProfiles"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([GitProfile].self, from: data) {
            profiles = saved
        }
        activeID = defaults.string(forKey: activeKey).flatMap(UUID.init)
        if let data = defaults.data(forKey: overridesKey),
           let saved = try? JSONDecoder().decode([String: UUID].self, from: data) {
            repoOverrides = saved
        }
        Task { await reload() }
    }

    var active: GitProfile? { activeID.flatMap { id in profiles.first { $0.id == id } } }

    func profile(for path: String) -> GitProfile? {
        if let id = repoOverrides[path], let p = profiles.first(where: { $0.id == id }) { return p }
        return active
    }

    func hasOverride(_ path: String) -> Bool { repoOverrides[path] != nil }

    var globalIdentity: (name: String, email: String) {
        let name = active?.authorName.isEmpty == false ? active!.authorName : systemName
        let email = active?.authorEmail.isEmpty == false ? active!.authorEmail : systemEmail
        return (name, email)
    }

    /// Name and email git will record for commits in this repository.
    func identity(for path: String) -> (name: String, email: String) {
        let p = profile(for: path)
        let name = p?.authorName.isEmpty == false ? p!.authorName : systemName
        let email = p?.authorEmail.isEmpty == false ? p!.authorEmail : systemEmail
        return (name, email)
    }

    /// Environment for git. The GitHub token is NOT in it: hooks, filters and anything else git
    /// starts inherit git's environment. Instead a credential helper asks gh for the token only
    /// when git actually needs a GitHub HTTPS credential.
    func environment(for path: String) -> [String: String] {
        guard let p = profile(for: path) else { return [:] }
        var env: [String: String] = [:]
        if !p.authorName.isEmpty {
            env["GIT_AUTHOR_NAME"] = p.authorName
            env["GIT_COMMITTER_NAME"] = p.authorName
        }
        if !p.authorEmail.isEmpty {
            env["GIT_AUTHOR_EMAIL"] = p.authorEmail
            env["GIT_COMMITTER_EMAIL"] = p.authorEmail
        }
        if let keyPath = p.sshKeyPath, !keyPath.isEmpty {
            let expanded = (keyPath as NSString).expandingTildeInPath
            env["GIT_SSH_COMMAND"] = "ssh -i \(Self.shellQuote(expanded)) -o IdentitiesOnly=yes"
        }
        if let account = p.githubAccount, let ghPath {
            env["GIT_CONFIG_COUNT"] = "2"
            env["GIT_CONFIG_KEY_0"] = "credential.https://github.com.helper"
            env["GIT_CONFIG_VALUE_0"] = ""        // drop any other helper for github.com
            env["GIT_CONFIG_KEY_1"] = "credential.https://github.com.helper"
            env["GIT_CONFIG_VALUE_1"] = Self.credentialHelper(ghPath: ghPath, account: account)
        }
        return env
    }

    /// Environment for gh commands: the selected account's token.
    func githubEnvironment(for path: String) -> [String: String] {
        guard let account = profile(for: path)?.githubAccount, let token = tokens[account] else { return [:] }
        return ["GH_TOKEN": token]
    }

    /// `git credential` helper (run by git through sh) that prints the account's token on "get".
    static func credentialHelper(ghPath: String, account: String) -> String {
        "!f() { test \"$1\" = get || exit 0; echo username=x-access-token; "
            + "printf 'password=%s\\n' \"$(\(shellQuote(ghPath)) auth token --hostname github.com --user \(shellQuote(account)))\"; }; f"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Editing

    func setActive(_ id: UUID?) {
        activeID = id
        save()
        AppState.shared.profileChanged()
    }

    func setOverride(_ id: UUID?, for path: String) {
        repoOverrides[path] = id
        save()
        AppState.shared.profileChanged()
    }

    func add() -> GitProfile {
        var p = GitProfile(label: profiles.isEmpty ? "Personal" : "Profile \(profiles.count + 1)")
        if profiles.isEmpty {
            p.authorName = systemName
            p.authorEmail = systemEmail
            p.githubAccount = ghActiveAccount
        }
        profiles.append(p)
        save()
        return p
    }

    func update(_ profile: GitProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
        if let account = profile.githubAccount, tokens[account] == nil { Task { await loadToken(account) } }
    }

    func remove(_ profile: GitProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeID == profile.id { activeID = nil }
        repoOverrides = repoOverrides.filter { $0.value != profile.id }
        save()
        AppState.shared.profileChanged()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(profiles), forKey: key)
        defaults.set(activeID?.uuidString, forKey: activeKey)
        defaults.set(try? JSONEncoder().encode(repoOverrides), forKey: overridesKey)
    }

    // MARK: Discovery

    func reload() async {
        async let name = Shell.run("git", ["config", "--global", "user.name"], cwd: nil)
        async let email = Shell.run("git", ["config", "--global", "user.email"], cwd: nil)
        systemName = (try? await name)?.stdout.utf8.trimmed ?? ""
        systemEmail = (try? await email)?.stdout.utf8.trimmed ?? ""

        let which = try? await Shell.run("which", ["gh"], cwd: nil)
        let path = which?.stdout.utf8.trimmed ?? ""
        ghPath = path.isEmpty ? nil : path
        ghAvailable = ghPath != nil
        guard ghAvailable, let status = try? await Shell.run("gh", ["auth", "status", "--hostname", "github.com"], cwd: nil) else {
            return
        }
        let parsed = Self.parseAccounts(status.stdout.utf8 + "\n" + status.stderr.utf8)
        ghAccounts = parsed.accounts
        ghActiveAccount = parsed.active
        for account in Set(profiles.compactMap(\.githubAccount)) { await loadToken(account) }
    }

    private func loadToken(_ account: String) async {
        guard let result = try? await Shell.run("gh", ["auth", "token", "--hostname", "github.com", "--user", account], cwd: nil),
              result.status == 0 else { return }
        let token = result.stdout.utf8.trimmed
        if !token.isEmpty { tokens[account] = token }
    }

    /// Parses `gh auth status` lines like "✓ Logged in to github.com account octocat (keyring)"
    /// followed by "- Active account: true".
    static func parseAccounts(_ text: String) -> (accounts: [String], active: String?) {
        var accounts: [String] = []
        var active: String?
        var last: String?
        for line in text.split(separator: "\n") {
            if let range = line.range(of: " account ") {
                let rest = line[range.upperBound...]
                if let name = rest.split(separator: " ").first {
                    let login = String(name)
                    if !accounts.contains(login) { accounts.append(login) }
                    last = login
                }
            } else if line.contains("Active account: true"), let last {
                active = last
            }
        }
        return (accounts, active)
    }
}
