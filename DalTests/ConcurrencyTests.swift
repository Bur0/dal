import XCTest
@testable import Dal

/// Branch switching while something else (a coding agent, another Git client) uses the repo.
final class ConcurrencyTests: XCTestCase {
    private var dir: URL!
    private var git: Git { Git(dir: dir) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-conc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "user.email", "test@example.com"])
        try "a\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", "a"])
        try await git.run(["branch", "dev"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecognisesLockMessages() {
        let message = "fatal: Unable to create '/r/.git/index.lock': File exists.\n\nAnother git process seems to be running"
        XCTAssertTrue(Git.isLockContention(message))
        XCTAssertEqual(Git.lockPath(in: message), "/r/.git/index.lock")
        XCTAssertFalse(Git.isLockContention("error: pathspec 'x' did not match"))
    }

    func testRecognisesChangesInTheWay() {
        let message = "error: Your local changes to the following files would be overwritten by checkout:\n\tf2.txt\n\tsrc/b.swift\nPlease commit your changes or stash them before you switch branches.\nAborting"
        XCTAssertTrue(RepoStore.changesInTheWay(message))
        XCTAssertEqual(RepoStore.blockingFiles(message), ["f2.txt", "src/b.swift"])
        XCTAssertTrue(RepoStore.changesInTheWay("error: The following untracked working tree files would be overwritten by checkout:\n\tn.txt"))
    }

    /// A lock that another process releases a moment later doesn't fail the checkout.
    func testCheckoutWaitsForABriefLock() async throws {
        let lock = dir.appendingPathComponent(".git/index.lock")
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(700))
            try? FileManager.default.removeItem(at: lock)
        }
        try await git.run(["checkout", "--end-of-options", "dev", "--"])
        let branch = await git.currentBranch()
        XCTAssertEqual(branch, "dev")
    }

    /// A ref whose commit is missing must not take the whole repository down.
    func testBrokenRefIsSkipped() async throws {
        try "e3728d780a2335c846659d19ff4db15cc9da1bcb\n"
            .write(to: dir.appendingPathComponent(".git/refs/heads/broken"), atomically: true, encoding: .utf8)
        let (refs, broken) = try await git.refsTolerant()
        XCTAssertEqual(broken, ["refs/heads/broken"])
        XCTAssertEqual(Set(refs.map(\.name)), ["main", "dev"])
        let log = try await git.log(limit: 10, includeHead: true, only: refs.map(\.fullName))
        XCTAssertEqual(log.count, 1)
    }

    /// Many git processes at once (dozens of agent worktrees) all complete — no pool starvation.
    func testManyParallelGitCallsComplete() async throws {
        let g = git
        let count = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<120 {
                group.addTask { (try? await g.string(["status", "--porcelain"])) != nil }
            }
            var ok = 0
            for await result in group where result { ok += 1 }
            return ok
        }
        XCTAssertEqual(count, 120)
    }
}
