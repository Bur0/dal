import XCTest
@testable import Dal

final class ParserTests: XCTestCase {
    func testStatusParsesStagedUnstagedRenamesAndConflicts() {
        let raw = "M  staged.txt\0 M unstaged.txt\0MM both.txt\0?? new.txt\0R  new-name.txt\0old-name.txt\0UU conflict.txt\0"
        let status = Parse.status(raw)
        XCTAssertEqual(status.staged.map(\.path), ["both.txt", "new-name.txt", "staged.txt"])
        XCTAssertEqual(status.unstaged.map(\.path), ["both.txt", "new.txt", "unstaged.txt"])
        XCTAssertEqual(status.conflicted.map(\.path), ["conflict.txt"])
        XCTAssertEqual(status.staged.first { $0.path == "new-name.txt" }?.oldPath, "old-name.txt")
        XCTAssertEqual(status.unstaged.first { $0.path == "new.txt" }?.kind, .untracked)
    }

    func testTrackParsing() {
        XCTAssertEqual(Parse.track("ahead 3, behind 2").ahead, 3)
        XCTAssertEqual(Parse.track("ahead 3, behind 2").behind, 2)
        XCTAssertEqual(Parse.track("behind 7").behind, 7)
        XCTAssertTrue(Parse.track("gone").gone)
    }

    func testLogParsing() {
        let raw = "abc\u{1f}p1 p2\u{1f}Ada\u{1f}ada@example.com\u{1f}1700000000\u{1f}Ada\u{1f}ada@example.com\u{1f}1700000000\u{1f}Merge things\u{1f}Body line\n\u{1e}\n"
        let commits = Parse.log(raw)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, ["p1", "p2"])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[0].body, "Body line")
    }

    func testDiffParsingNumbersLines() {
        let raw = """
        diff --git a/f.txt b/f.txt
        index 1..2 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let diff = Parse.diff(raw)
        XCTAssertEqual(diff.header.count, 4)
        XCTAssertEqual(diff.hunks.count, 1)
        let lines = diff.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .context])
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertEqual(lines[2].newNumber, 2)
        XCTAssertEqual(lines[3].newNumber, 3)
    }

    func testBadgesMergeLocalAndRemote() {
        let refs = [
            Ref(fullName: "refs/heads/main", name: "main", kind: .localBranch, target: "a", isHead: true),
            Ref(fullName: "refs/remotes/origin/main", name: "origin/main", kind: .remoteBranch, target: "a"),
            Ref(fullName: "refs/tags/v1", name: "v1", kind: .tag, target: "a"),
        ]
        let badges = Parse.badges(refs)["a"]!
        XCTAssertEqual(badges.count, 2)
        XCTAssertEqual(badges[0].name, "main")
        XCTAssertEqual(badges[0].remotes.count, 1)
        XCTAssertEqual(badges[1].name, "v1")
    }
}

final class GraphLayoutTests: XCTestCase {
    func testLinearHistoryUsesOneLane() {
        let nodes = [
            GraphLayout.Node(id: "c", parents: ["b"]),
            GraphLayout.Node(id: "b", parents: ["a"]),
            GraphLayout.Node(id: "a", parents: []),
        ]
        let result = GraphLayout.compute(nodes)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.rows.map(\.lane), [0, 0, 0])
    }

    func testBranchAndMergeUseTwoLanes() {
        // m merges f into main; f and b both come from a.
        let nodes = [
            GraphLayout.Node(id: "m", parents: ["b", "f"]),
            GraphLayout.Node(id: "f", parents: ["a"]),
            GraphLayout.Node(id: "b", parents: ["a"]),
            GraphLayout.Node(id: "a", parents: []),
        ]
        let result = GraphLayout.compute(nodes)
        XCTAssertEqual(result.width, 2)
        XCTAssertEqual(result.rows[0].lane, 0)
        XCTAssertEqual(result.rows[1].lane, 1)
        XCTAssertEqual(result.rows[2].lane, 0)
        XCTAssertEqual(result.rows[3].lane, 0)
        // The root row receives both lanes.
        XCTAssertEqual(result.rows[3].lines.filter { $0.kind == .toNode }.count, 2)
    }
}

final class PatchBuilderTests: XCTestCase {
    private let raw = """
    diff --git a/f.txt b/f.txt
    --- a/f.txt
    +++ b/f.txt
    @@ -1,3 +1,4 @@
     one
    -two
    +TWO
    +extra
     three
    """

    func testStagingOneAddedLineKeepsDeletionAsContext() throws {
        let diff = Parse.diff(raw)
        let hunk = diff.hunks[0]
        let extra = hunk.lines.first { $0.text == "extra" }!.id
        let patch = try XCTUnwrap(PatchBuilder.patch(header: diff.header, hunk: hunk, selected: [extra], reverse: false))
        XCTAssertTrue(patch.contains("@@ -1,3 +1,4 @@"))
        XCTAssertTrue(patch.contains(" two\n"))
        XCTAssertFalse(patch.contains("+TWO"))
        XCTAssertTrue(patch.contains("+extra"))
    }

    func testReversePatchTurnsUnselectedAdditionsIntoContext() throws {
        let diff = Parse.diff(raw)
        let hunk = diff.hunks[0]
        let extra = hunk.lines.first { $0.text == "extra" }!.id
        let patch = try XCTUnwrap(PatchBuilder.patch(header: diff.header, hunk: hunk, selected: [extra], reverse: true))
        XCTAssertTrue(patch.contains(" TWO\n"))
        XCTAssertFalse(patch.contains("-two"))
        XCTAssertTrue(patch.contains("@@ -1,3 +1,4 @@"))
    }

    func testNothingSelectedReturnsNil() {
        let diff = Parse.diff(raw)
        XCTAssertNil(try PatchBuilder.patch(header: diff.header, hunk: diff.hunks[0], selected: [], reverse: false))
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testWorktreeRenameReadsOldPath() {
        // Intent-to-add renames show up as " R new\0old\0".
        let status = Parse.status(" R new.swift\0old.swift\0 M other.txt\0")
        XCTAssertEqual(status.unstaged.map(\.path), ["new.swift", "other.txt"])
        XCTAssertEqual(status.unstaged.first?.oldPath, "old.swift")
        XCTAssertTrue(status.staged.isEmpty)
    }

    func testUnterminatedConflictKeepsAllLines() {
        let text = "intro\n<<<<<<< not really\nquoted line\nend"
        let chunks = ConflictParser.parse(text)
        XCTAssertFalse(chunks.contains(where: \.isConflict))
        XCTAssertEqual(ConflictParser.resolve(chunks, choices: [:]), text)
    }

    func testLongerMarkersAreNotConflicts() {
        let text = "a\n<<<<<<<< eight\nb"
        XCTAssertFalse(ConflictParser.parse(text).contains(where: \.isConflict))
    }

    func testPartialPatchRefusedForRenames() {
        XCTAssertFalse(PatchBuilder.supportsPartial(["diff --git a/x b/y", "rename from x", "rename to y"]))
        XCTAssertFalse(PatchBuilder.supportsPartial(["diff --git a/x b/x", "new file mode 100644"]))
        XCTAssertTrue(PatchBuilder.supportsPartial(["diff --git a/x b/x", "index 1..2 100644"]))
    }
}

final class ConflictParserTests: XCTestCase {
    func testParseAndResolve() {
        let text = "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nz"
        let chunks = ConflictParser.parse(text)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertNil(ConflictParser.resolve(chunks, choices: [:]))
        XCTAssertEqual(ConflictParser.resolve(chunks, choices: [1: .theirs]), "a\ntheirs\nz")
        XCTAssertEqual(ConflictParser.resolve(chunks, choices: [1: .oursThenTheirs]), "a\nours\ntheirs\nz")
    }
}
