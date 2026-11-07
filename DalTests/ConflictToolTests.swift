import XCTest
@testable import Dal

/// The merge tool's model: line picks, marker rendering, and the base pulled from git's index.
final class ConflictToolTests: XCTestCase {
    private let text = "top\n<<<<<<< HEAD\no1\no2\n=======\nt1\nt2\n>>>>>>> feature\nmid\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\nend"

    func testLinePicksKeepFileOrderAndFirstSide() {
        let chunks = ConflictParser.parse(text)
        let ids = chunks.filter(\.isConflict).map(\.id)
        var picks: [Int: ConflictPick] = [ids[0]: ConflictPick(ours: [1], theirs: [0], theirsFirst: true)]
        XCTAssertNil(ConflictParser.resolve(chunks, picks: picks), "second conflict is still open")
        picks[ids[1]] = ConflictPick(neither: true)
        XCTAssertEqual(ConflictParser.resolve(chunks, picks: picks), "top\nt1\no2\nmid\nend")
    }

    func testRenderKeepsMarkersOfUndecidedConflicts() {
        let chunks = ConflictParser.parse(text)
        let first = chunks.first(where: \.isConflict)!.id
        let out = ConflictParser.render(chunks, picks: [first: ConflictPick(.theirs, oursCount: 2, theirsCount: 2)])
        XCTAssertEqual(out, "top\nt1\nt2\nmid\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> feature\nend")
        XCTAssertTrue(ConflictParser.hasMarkers(out))
        XCTAssertFalse(ConflictParser.hasMarkers("a\n=======\nb"))
    }

    func testChoiceToPick() {
        XCTAssertEqual(ConflictPick(.ours, oursCount: 0, theirsCount: 3), ConflictPick(neither: true),
                       "taking an empty side means removing the lines")
        XCTAssertTrue(ConflictPick(.theirsThenOurs, oursCount: 1, theirsCount: 1).theirsFirst)
        XCTAssertFalse(ConflictPick().isResolved)
    }

    /// A real merge conflict: the tool rebuilds it from the index with the common ancestor.
    func testConflictSourceAddsBaseFromIndex() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dal-conf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = Git(dir: dir)
        let file = dir.appendingPathComponent("f.txt")
        try await git.run(["init", "-q", "-b", "main"])
        try await git.run(["config", "user.name", "T"])
        try await git.run(["config", "user.email", "t@example.com"])
        try "a\nbase\nz\n".write(to: file, atomically: true, encoding: .utf8)
        try await git.run(["commit", "-qam", "x", "--allow-empty"])
        try await git.run(["add", "."]); try await git.run(["commit", "-qm", "base"])
        try await git.run(["switch", "-qc", "feature"])
        try "a\ntheirs\nz\n".write(to: file, atomically: true, encoding: .utf8)
        try await git.run(["commit", "-qam", "theirs"])
        try await git.run(["switch", "-q", "main"])
        try "a\nours\nz\n".write(to: file, atomically: true, encoding: .utf8)
        try await git.run(["commit", "-qam", "ours"])
        _ = try? await git.run(["-c", "merge.conflictStyle=merge", "merge", "feature"])

        let working = try String(contentsOf: file, encoding: .utf8)
        let source = await git.conflictSource(path: "f.txt", working: working)
        guard case .conflict(let ours, let base, let theirs, let oursLabel, let theirsLabel)? =
                ConflictParser.parse(source).first(where: \.isConflict)?.content else { return XCTFail(source) }
        XCTAssertEqual(ours, ["ours"]); XCTAssertEqual(theirs, ["theirs"]); XCTAssertEqual(base, ["base"])
        XCTAssertEqual(oursLabel, "HEAD"); XCTAssertEqual(theirsLabel, "feature")

        // Resolving from the base-enriched source gives the same file as from the original.
        let pick = { (chunks: [ConflictChunk]) in
            Dictionary(uniqueKeysWithValues: chunks.filter(\.isConflict).map { ($0.id, ConflictPick(ours: [0], theirs: [0])) })
        }
        let a = ConflictParser.parse(working), b = ConflictParser.parse(source)
        XCTAssertEqual(ConflictParser.resolve(a, picks: pick(a)), ConflictParser.resolve(b, picks: pick(b)))

        // Once edited by hand, the file on disk stays the source.
        let edited = working.replacingOccurrences(of: "a\n", with: "a (edited)\n")
        let kept = await git.conflictSource(path: "f.txt", working: edited)
        XCTAssertEqual(kept, edited)
    }
}
