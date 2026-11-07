import XCTest
@testable import Dal

/// Runs the real git binary against a throwaway repository.
final class GitIntegrationTests: XCTestCase {
    private var dir: URL!
    private var git: Git { Git(dir: dir) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "user.email", "test@example.com"])
        try "a\nb\nc\nd\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "init"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStagingSelectedLinesOnly() async throws {
        try "a\nB\nc\nd\nE\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let status = try await git.status()
        let change = try XCTUnwrap(status.unstaged.first)
        let diff = try await git.diffWorking(change, staged: false)
        let hunk = try XCTUnwrap(diff.hunks.first)
        // Stage only the appended "E" line.
        let line = try XCTUnwrap(hunk.lines.first { $0.kind == .addition && $0.text == "E" })
        let patch = try XCTUnwrap(PatchBuilder.patch(header: diff.header, hunk: hunk, selected: [line.id], reverse: false))
        try await git.apply(patch: patch, cached: true, reverse: false)

        let staged = try await git.string(["diff", "--cached"])
        XCTAssertTrue(staged.contains("+E"))
        XCTAssertFalse(staged.contains("+B"))
        let unstaged = try await git.string(["diff"])
        XCTAssertTrue(unstaged.contains("+B"))
        XCTAssertFalse(unstaged.contains("+E"))

        // Now unstage it again via a reverse patch built from the staged diff.
        let stagedDiff = try await git.diffWorking(change, staged: true)
        let stagedHunk = try XCTUnwrap(stagedDiff.hunks.first)
        let reverse = try XCTUnwrap(PatchBuilder.patch(header: stagedDiff.header, hunk: stagedHunk,
                                                       selected: stagedHunk.changeIDs, reverse: true))
        try await git.apply(patch: reverse, cached: true, reverse: true)
        let afterUnstage = try await git.string(["diff", "--cached"])
        XCTAssertTrue(afterUnstage.isEmpty)
    }

    func testDiscardSelectedLineFromWorktree() async throws {
        try "a\nB\nc\nd\nE\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let status = try await git.status()
        let change = try XCTUnwrap(status.unstaged.first)
        let diff = try await git.diffWorking(change, staged: false)
        let hunk = try XCTUnwrap(diff.hunks.first)
        let ids = Set(hunk.lines.filter { $0.text == "B" || $0.text == "b" }.map(\.id))
        let patch = try XCTUnwrap(PatchBuilder.patch(header: diff.header, hunk: hunk, selected: ids, reverse: true))
        try await git.apply(patch: patch, cached: false, reverse: true)
        let content = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(content, "a\nb\nc\nd\nE\n")
    }

    /// Review finding: staging only "+c" after a last line without newline must not glue lines.
    func testStagingAfterLastLineWithoutNewline() async throws {
        let file = dir.appendingPathComponent("f.txt")
        try "a\nb".write(to: file, atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "no newline"])
        try "a\nb\nc\n".write(to: file, atomically: true, encoding: .utf8)
        let status = try await git.status()
        let change = try XCTUnwrap(status.unstaged.first)
        let diff = try await git.diffWorking(change, staged: false)
        let hunk = try XCTUnwrap(diff.hunks.first)
        let c = try XCTUnwrap(hunk.lines.first { $0.kind == .addition && $0.text == "c" })
        let patch = try XCTUnwrap(try PatchBuilder.patch(header: diff.header, hunk: hunk, selected: [c.id], reverse: false))
        try await git.apply(patch: patch, cached: true, reverse: false)
        let index = try await git.string(["show", ":f.txt"])
        XCTAssertEqual(index, "a\nb\nc\n")
        // Worktree untouched; nothing left to stage.
        let remaining = try await git.string(["diff"])
        XCTAssertTrue(remaining.isEmpty, remaining)
    }

    /// Review finding: paths are literal, so restoring `a[1].txt` leaves `a1.txt` alone.
    func testPathsAreLiteral() async throws {
        for name in ["a[1].txt", "a1.txt"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "two files"])
        for name in ["a[1].txt", "a1.txt"] {
            try "changed".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git.run(["restore", "--", "a[1].txt"])
        let status = try await git.status()
        XCTAssertEqual(status.unstaged.map(\.path), ["a1.txt"])
    }

    func testLogRefsAndStashes() async throws {
        try await git.run(["checkout", "-qb", "feature"])
        try "x".write(to: dir.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "feature work"])
        try "y".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await git.run(["stash", "push", "-m", "my idea"])

        let commits = try await git.log(limit: 100, includeHead: true)
        XCTAssertEqual(commits.map(\.subject), ["feature work", "init"])
        let refs = try await git.refs()
        XCTAssertEqual(Set(refs.map(\.name)), ["feature", "main"])
        XCTAssertTrue(refs.first { $0.name == "feature" }!.isHead)
        let stashes = try await git.stashes()
        XCTAssertEqual(stashes.first?.message, "my idea")
    }
}

final class ProfileTests: XCTestCase {
    func testProfileEnvironmentSetsCommitAuthor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = Git(dir: dir)
        try await plain.run(["init", "-q", "-b", "main"])
        try await plain.run(["config", "user.name", "Repo Default"])
        try await plain.run(["config", "user.email", "default@example.com"])
        let work = Git(dir: dir, env: ["GIT_AUTHOR_NAME": "Work Me", "GIT_AUTHOR_EMAIL": "me@work.example",
                                       "GIT_COMMITTER_NAME": "Work Me", "GIT_COMMITTER_EMAIL": "me@work.example"])
        try await work.run(["commit", "-q", "--allow-empty", "-m", "as work"])
        let author = try await plain.string(["log", "-1", "--format=%an <%ae> / %cn <%ce>"]).trimmed
        XCTAssertEqual(author, "Work Me <me@work.example> / Work Me <me@work.example>")
    }

    @MainActor
    func testParseGhAccounts() {
        let text = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: false
          ✓ Logged in to github.com account work-bot (keyring)
          - Active account: true
        """
        let parsed = ProfileStore.parseAccounts(text)
        XCTAssertEqual(parsed.accounts, ["octocat", "work-bot"])
        XCTAssertEqual(parsed.active, "work-bot")
    }

    @MainActor
    func testFuzzySwitcherPrefersNameMatches() {
        let a = QuickSwitcher.fuzzyScore("adm", in: "memurjet-admin /x/memurjet-admin", nameLength: 14)
        let b = QuickSwitcher.fuzzyScore("adm", in: "random-app /x/random-app", nameLength: 10)
        XCTAssertNotNil(a)
        XCTAssertGreaterThan(a ?? 0, b ?? 0)
        XCTAssertNil(QuickSwitcher.fuzzyScore("zzz", in: "abc", nameLength: 3))
    }
}
