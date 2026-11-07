import XCTest
@testable import Dal

/// Regression tests for the security review (Nov 2026). Each test shows the attack works without
/// the fix, then that the fix stops it — using the real git binary in a throwaway repository.
final class SecurityTests: XCTestCase {
    private var dir: URL!
    private var git: Git { Git(dir: dir) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "user.email", "test@example.com"])
        try "a\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "init"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A repo's core.fsmonitor runs on every `git status`. Restricted mode must stop it.
    func testRestrictedModeStopsFsmonitor() async throws {
        let marker = dir.appendingPathComponent("pwned")
        let hook = try script("fsmon.sh", "touch '\(marker.path)'; exit 1")
        try await git.run(["config", "core.fsmonitor", hook.path])

        // Without protection the setting runs.
        _ = try await git.status()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "precondition: fsmonitor runs")
        try FileManager.default.removeItem(at: marker)

        let findings = await RepoTrust.findings(in: dir)
        XCTAssertTrue(findings.contains { $0.key == "core.fsmonitor" })
        let safe = Git(dir: dir, safety: RepoTrust.overrides(for: findings, globalHelpers: []))
        _ = try await safe.status()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "fsmonitor must not run in restricted mode")
    }

    /// A clean filter runs on status when stat info is stale. Restricted mode must neutralise it.
    func testRestrictedModeStopsFilters() async throws {
        let marker = dir.appendingPathComponent("filtered")
        let filter = try script("clean.sh", "touch '\(marker.path)'; cat")
        try await git.run(["config", "filter.evil.clean", filter.path])
        try "*.txt filter=evil\n".write(to: dir.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let findings = await RepoTrust.findings(in: dir)
        let safe = Git(dir: dir, safety: RepoTrust.overrides(for: findings, globalHelpers: []))
        _ = try await safe.status()
        _ = try await safe.run(["add", "a.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "clean filter must not run in restricted mode")
    }

    /// A tag named "-f" must be checked out as a tag, not read as `--force` (which drops local changes).
    func testDashNamedTagIsNotAnOption() async throws {
        try await git.run(["update-ref", "refs/tags/-f", "HEAD"])
        try "local work\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["checkout", "--end-of-options", "-f", "--"])
        let content = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "local work\n", "uncommitted work must survive")
    }

    /// The GitHub token is handed to git by a credential helper on demand, not via the environment.
    @MainActor
    func testCredentialHelperSuppliesTokenWithoutEnvironment() async throws {
        let fakeGh = try script("gh", #"[ "$1 $2" = "auth token" ] && echo tok-123"#)
        let helper = ProfileStore.credentialHelper(ghPath: fakeGh.path, account: "octo cat'")
        let env = ["GIT_CONFIG_COUNT": "2",
                   "GIT_CONFIG_KEY_0": "credential.https://github.com.helper", "GIT_CONFIG_VALUE_0": "",
                   "GIT_CONFIG_KEY_1": "credential.https://github.com.helper", "GIT_CONFIG_VALUE_1": helper]
        let out = try await Git(dir: dir, env: env).string(["credential", "fill"],
                                                            input: Data("protocol=https\nhost=github.com\n\n".utf8))
        XCTAssertTrue(out.contains("password=tok-123"), out)
        XCTAssertTrue(out.contains("username=x-access-token"), out)
        XCTAssertNil(env["GH_TOKEN"])
    }

    @MainActor
    func testOpenFileRefusesExecutables() throws {
        let command = dir.appendingPathComponent("run.command")
        try "echo hi".write(to: command, atomically: true, encoding: .utf8)
        let tool = try script("tool", "echo hi")
        let source = dir.appendingPathComponent("main.swift")
        try "print(1)".write(to: source, atomically: true, encoding: .utf8)
        let app = dir.appendingPathComponent("Evil.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertTrue(RepoStore.mightExecute(command))
        XCTAssertTrue(RepoStore.mightExecute(tool))
        XCTAssertTrue(RepoStore.mightExecute(app))
        XCTAssertFalse(RepoStore.mightExecute(source))
    }

    func testTrustFindingsParse() {
        let found = RepoTrust.parse("core.fsmonitor /tmp/x.sh\nfilter.lfs.clean git-lfs clean -- %f\ndiff.img.textconv exiftool\n")
        XCTAssertEqual(found.map(\.key), ["core.fsmonitor", "filter.lfs.clean", "diff.img.textconv"])
        let args = RepoTrust.overrides(for: found, globalHelpers: ["osxkeychain"])
        XCTAssertTrue(args.contains("filter.lfs.clean="))
        XCTAssertTrue(args.contains("diff.img.textconv="))
        XCTAssertTrue(args.contains("core.hooksPath=/dev/null"))
    }
}
