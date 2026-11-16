import XCTest
@testable import Dal

/// Worktree parsing, agent recognition and the exact git commands the worktree actions run.
final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var dir: URL { root.appendingPathComponent("repo") }
    private var git: Git { Git(dir: dir) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dal-wt-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "user.email", "test@example.com"])
        try "a\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "a"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testParsesLockPruneAndDetached() {
        let text = """
        worktree /r
        HEAD 1111
        branch refs/heads/main

        worktree /r-x
        HEAD 2222
        branch refs/heads/feature/x
        locked on a USB disk

        worktree /r-y
        HEAD 3333
        detached
        locked

        worktree /gone
        HEAD 4444
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let trees = Parse.worktrees(text)
        XCTAssertEqual(trees.count, 4)
        XCTAssertTrue(trees[0].isMain)
        XCTAssertEqual(trees[1].branch, "feature/x")
        XCTAssertEqual(trees[1].lockReason, "on a USB disk")
        XCTAssertTrue(trees[2].isDetached)
        XCTAssertEqual(trees[2].lockReason, "", "locked without a reason is still locked")
        XCTAssertTrue(trees[2].isLocked)
        XCTAssertTrue(trees[3].isPrunable)
        XCTAssertFalse(trees[1].isPrunable)
    }

    func testRecognisesAgentWorktrees() {
        XCTAssertEqual(Worktree.agent(path: "/Users/me/app/.claude/worktrees/fix-login", branch: "fix-login"), "Claude Code")
        XCTAssertEqual(Worktree.agent(path: "/Users/me/.codex/worktrees/a1b2/app", branch: nil), "Codex")
        XCTAssertEqual(Worktree.agent(path: "/Users/me/.cursor/worktrees/app/x", branch: nil), "Cursor")
        XCTAssertEqual(Worktree.agent(path: "/Users/me/conductor/workspaces/app/tokyo", branch: nil), "Conductor")
        XCTAssertEqual(Worktree.agent(path: "/Users/me/app-wt", branch: "claude/refactor"), "Claude Code")
        XCTAssertNil(Worktree.agent(path: "/Users/me/app-feature", branch: "feature/x"))
    }

    func testLockMoveRemoveAndPruneCommands() async throws {
        let first = root.appendingPathComponent("wt-one").path
        try await git.run(["worktree", "add", "-b", "one", "--end-of-options", first, "HEAD"])

        try await git.run(["worktree", "lock", "--reason", "agent busy", "--end-of-options", first])
        var trees = try await git.worktrees()
        XCTAssertEqual(trees.first { $0.branch == "one" }?.lockReason, "agent busy")
        try await git.run(["worktree", "unlock", "--end-of-options", first])
        trees = try await git.worktrees()
        XCTAssertFalse(trees.first { $0.branch == "one" }?.isLocked ?? true)

        let moved = root.appendingPathComponent("wt-moved").path
        try await git.run(["worktree", "move", "--end-of-options", first, moved])
        trees = try await git.worktrees()
        XCTAssertTrue(trees.contains { RepoStore.samePath($0.path, moved) })

        // A dirty worktree needs --force.
        try "dirty\n".write(toFile: moved + "/a.txt", atomically: true, encoding: .utf8)
        do {
            try await git.run(["worktree", "remove", "--end-of-options", moved])
            XCTFail("removing a dirty worktree without --force should fail")
        } catch {}
        try await git.run(["worktree", "remove", "--force", "--end-of-options", moved])
        trees = try await git.worktrees()
        XCTAssertEqual(trees.count, 1)
        let branches = try await git.string(["branch", "--list", "one"])
        XCTAssertTrue(branches.contains("one"), "the branch stays")

        // A folder deleted by hand shows up as prunable, and prune drops it.
        let second = root.appendingPathComponent("wt-two").path
        try await git.run(["worktree", "add", "-b", "two", "--end-of-options", second, "HEAD"])
        try FileManager.default.removeItem(atPath: second)
        trees = try await git.worktrees()
        XCTAssertTrue(trees.first { $0.branch == "two" }?.isPrunable ?? false)
        try await git.run(["worktree", "prune"])
        trees = try await git.worktrees()
        XCTAssertEqual(trees.count, 1)
    }
}
