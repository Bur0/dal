import XCTest
@testable import Dal

/// The context-menu history edits, patches and links, against the real git binary.
final class HistoryTests: XCTestCase {
    private var dir: URL!
    private var git: Git { Git(dir: dir) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "Test"])
        try await git.run(["config", "user.email", "test@example.com"])
        for name in ["a", "b", "c", "d"] { try await commit(name) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func commit(_ name: String) async throws {
        try "\(name)\n".write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-qm", name])
    }

    private func subjects() async throws -> [String] {
        try await git.string(["log", "--format=%s"]).split(separator: "\n").map(String.init)
    }

    private func sha(_ rev: String) async throws -> String {
        try await git.string(["rev-parse", rev]).trimmed
    }

    func testDropRemovesOnlyThatCommit() async throws {
        try await git.rewrite(.drop, target: try await sha("HEAD~2"))   // "b"
        let list = try await subjects()
        XCTAssertEqual(list, ["d", "c", "a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    func testRewordOlderCommitKeepsTree() async throws {
        let treeBefore = try await sha("HEAD^{tree}")
        try await git.rewrite(.reword, target: try await sha("HEAD~1"), message: "c, reworded\n\nwith a body")
        let list = try await subjects()
        XCTAssertEqual(list, ["d", "c, reworded", "b", "a"])
        let body = try await git.string(["log", "-1", "--format=%b", "HEAD~1"]).trimmed
        XCTAssertEqual(body, "with a body")
        let treeAfter = try await sha("HEAD^{tree}")
        XCTAssertEqual(treeBefore, treeAfter)
    }

    func testMoveDownAndUpSwapNeighbours() async throws {
        try await git.rewrite(.down, target: try await sha("HEAD~1"))   // "c" below "b"
        var list = try await subjects()
        XCTAssertEqual(list, ["d", "b", "c", "a"])
        try await git.rewrite(.up, target: try await sha("HEAD~2"))     // "c" back above "b"
        list = try await subjects()
        XCTAssertEqual(list, ["d", "c", "b", "a"])
    }

    func testRewriteProblems() async throws {
        let root = try await sha("HEAD~3")
        let head = try await sha("HEAD")
        let rootProblem = await git.rewriteProblem(.drop, target: root)
        XCTAssertNotNil(rootProblem, "the root commit has no parent to rebase onto")
        let headUp = await git.rewriteProblem(.up, target: head)
        XCTAssertNotNil(headUp)
        let fine = await git.rewriteProblem(.down, target: head)
        XCTAssertNil(fine)

        // A commit on another branch isn't on HEAD's history.
        try await git.run(["switch", "-qc", "side", "HEAD~2"])
        try await commit("side")
        try await git.run(["switch", "-q", "main"])
        let sideTip = try await sha("side")
        let offBranch = await git.rewriteProblem(.drop, target: sideTip)
        XCTAssertNotNil(offBranch)

        // A merge after the target makes the range non-linear.
        try await git.run(["merge", "-q", "--no-edit", "--no-ff", "side"])
        let behindMerge = await git.rewriteProblem(.drop, target: try await sha("HEAD~2"))
        XCTAssertNotNil(behindMerge)
    }

    func testFormatAndApplyPatch() async throws {
        let patch = try await git.formatPatch(try await sha("HEAD"))
        XCTAssertTrue(String(decoding: patch, as: UTF8.self).hasPrefix("From "))
        let file = dir.appendingPathComponent("../\(UUID().uuidString).patch").standardizedFileURL
        try patch.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await git.run(["reset", "-q", "--hard", "HEAD~1"])
        try await git.applyPatch(at: file)
        let list = try await subjects()
        XCTAssertEqual(list, ["d", "c", "b", "a"], "a mailbox patch becomes a commit again")

        // A plain diff only changes the work tree.
        let diff = dir.appendingPathComponent("../\(UUID().uuidString).diff").standardizedFileURL
        try "a\nmore\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["diff"]).write(to: diff)
        defer { try? FileManager.default.removeItem(at: diff) }
        try await git.run(["checkout", "--", "a.txt"])
        try await git.applyPatch(at: diff)
        let content = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "a\nmore\n")
    }

    func testSoloLogShowsOnlyThatBranch() async throws {
        try await git.run(["switch", "-qc", "side", "HEAD~2"])
        try await commit("side")
        try await git.run(["switch", "-q", "main"])
        let solo = try await git.log(limit: 100, includeHead: false, only: ["refs/heads/side"])
        XCTAssertEqual(solo.map(\.subject), ["side", "b", "a"])
        let all = try await git.log(limit: 100, includeHead: true)
        XCTAssertEqual(all.count, 5)
    }

    func testRemoteWebLinks() {
        XCTAssertEqual(RemoteWeb.base("git@github.com:Bur0/dal.git")?.absoluteString, "https://github.com/Bur0/dal")
        XCTAssertEqual(RemoteWeb.base("ssh://git@gitlab.com:2222/team/app.git")?.absoluteString, "https://gitlab.com/team/app")
        XCTAssertEqual(RemoteWeb.base("https://user:secret@github.com/o/r.git")?.absoluteString, "https://github.com/o/r",
                       "credentials in the URL must not end up in a copied link")
        XCTAssertEqual(RemoteWeb.branch("git@github.com:o/r.git", "feature/x")?.absoluteString, "https://github.com/o/r/tree/feature/x")
        XCTAssertEqual(RemoteWeb.branch("https://gitlab.com/o/r", "main")?.absoluteString, "https://gitlab.com/o/r/-/tree/main")
        XCTAssertEqual(RemoteWeb.commit("git@bitbucket.org:o/r.git", "abc")?.absoluteString, "https://bitbucket.org/o/r/commits/abc")
        XCTAssertNil(RemoteWeb.base("/Users/me/repo.git"))
    }
}
