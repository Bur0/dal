import Foundation

/// A repository's own `.git/config` can make git run programs: `core.fsmonitor` runs on every
/// `git status`, `filter.*` on status/checkout, `diff.*.textconv` on diffs, hooks on commits.
/// Dal runs git on its own (when a repo opens and on every file change), so for a repository
/// the user hasn't trusted it neutralises those settings with `-c` overrides.
enum RepoTrust {
    struct Finding: Hashable, Identifiable {
        let key: String
        let value: String
        var id: String { key }
    }

    /// Keys whose values git executes (or that hand credentials to a program).
    static let riskyPattern = #"^(core\.(fsmonitor|hookspath|sshcommand|askpass|gitproxy|pager)|filter\..+\..+|diff\..+\.(textconv|command)|merge\..+\.driver|gpg\..+|credential\..+|sequence\.editor|interactive\.difffilter)$"#

    private static let trustedKey = "trustedRepositories"

    static func isTrusted(_ path: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: trustedKey) ?? []).contains(path)
    }

    static func trust(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: trustedKey) ?? []
        if !list.contains(path) { list.append(path) }
        UserDefaults.standard.set(list, forKey: trustedKey)
    }

    /// Reading config never executes anything, so this is safe to run before anything else.
    static func findings(in dir: URL) async -> [Finding] {
        guard let result = try? await Shell.run("git", ["config", "--local", "--includes", "--get-regexp", riskyPattern],
                                                cwd: dir),
              result.status == 0 else { return [] }
        return parse(result.stdout.utf8)
    }

    static func parse(_ text: String) -> [Finding] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { return nil }
            return Finding(key: key, value: parts.count > 1 ? parts[1] : "")
        }
    }

    /// `-c` arguments that switch off what the findings would run.
    /// - Parameter globalHelpers: the user's global credential helpers, restored after the
    ///   repository's own helpers are cleared.
    static func overrides(for findings: [Finding], globalHelpers: [String]) -> [String] {
        var config: [String] = ["core.fsmonitor=false", "core.hooksPath=/dev/null"]
        var filters = Set<String>(), diffs = Set<String>(), merges = Set<String>()
        var clearCredentials = false
        for finding in findings {
            let key = finding.key
            // Subsection names may contain dots; the section is the first part, the variable the last.
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !key.contains("="), !key.contains("\n") else { continue }
            let section = parts[0]
            let name = parts.count >= 3 ? parts[1..<(parts.count - 1)].joined(separator: ".") : ""
            switch section {
            case "core":
                switch parts.last {
                case "sshcommand": config.append("core.sshCommand=ssh")
                case "askpass": config.append("core.askPass=")
                case "gitproxy": config.append("core.gitProxy=")
                case "pager": config.append("core.pager=cat")
                default: break
                }
            case "filter" where !name.isEmpty: filters.insert(name)
            case "diff" where !name.isEmpty: diffs.insert(name)
            case "merge" where !name.isEmpty: merges.insert(name)
            case "gpg":
                config += ["gpg.program=gpg", "gpg.ssh.program=ssh-keygen", "gpg.x509.program=gpgsm"]
            case "credential": clearCredentials = true
            case "sequence": config.append("sequence.editor=true")
            case "interactive": config.append("interactive.diffFilter=")
            default: break
            }
        }
        for name in filters.sorted() {
            config += ["filter.\(name).clean=", "filter.\(name).smudge=", "filter.\(name).process=", "filter.\(name).required=false"]
        }
        for name in diffs.sorted() { config += ["diff.\(name).textconv=", "diff.\(name).command="] }
        for name in merges.sorted() { config.append("merge.\(name).driver=false") }
        if clearCredentials {
            config.append("credential.helper=")
            config += globalHelpers.map { "credential.helper=\($0)" }
        }
        var seen = Set<String>()
        return config.filter { seen.insert($0).inserted }.flatMap { ["-c", $0] }
    }

    static func globalCredentialHelpers() async -> [String] {
        let result = try? await Shell.run("git", ["config", "--global", "--get-all", "credential.helper"], cwd: nil)
        return result?.stdout.utf8.split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
    }
}
