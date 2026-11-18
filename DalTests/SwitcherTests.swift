import XCTest
@testable import Dal

/// The branch switcher's search, and how a detached HEAD is labelled in the graph.
final class SwitcherTests: XCTestCase {
    func testWordsMatchInAnyOrder() {
        XCTAssertTrue(BranchSwitcher.matches("feat/BLT-11119-hub-kurumsal-blok", "11119 hub"))
        XCTAssertTrue(BranchSwitcher.matches("feat/BLT-11119-hub-kurumsal-blok", "HUB blt"))
        XCTAssertFalse(BranchSwitcher.matches("feat/BLT-11119-hub-kurumsal-blok", "11119 crm"))
        XCTAssertTrue(BranchSwitcher.matches("anything", ""))
    }

    func testRanking() {
        XCTAssertLessThan(BranchSwitcher.rank("main", "main"), BranchSwitcher.rank("maintenance", "main"))
        XCTAssertLessThan(BranchSwitcher.rank("maintenance", "main"), BranchSwitcher.rank("feat/main-menu", "main"))
        XCTAssertLessThan(BranchSwitcher.rank("feat/main-menu", "main"), BranchSwitcher.rank("feat/domain", "main"))
    }

    private func ref(_ name: String, _ kind: RefKind, _ target: String, head: Bool = false) -> Ref {
        let prefix = kind == .localBranch ? "refs/heads/" : kind == .remoteBranch ? "refs/remotes/" : "refs/tags/"
        return Parse.refs("\(prefix)\(name)\u{1f}\(target)\u{1f}\u{1f}\u{1f}\u{1f}\(head ? "*" : " ")\u{1f}\u{1f}").first!
    }

    func testDetachedHeadOnATagMarksTheTag() {
        let refs = [ref("main", .localBranch, "aaa"), ref("v1.0", .tag, "bbb"), ref("v1.0-rc", .tag, "bbb")]
        let badges = Parse.badges(refs, detachedHead: "bbb")
        let atHead = badges["bbb"] ?? []
        XCTAssertEqual(atHead.first?.isHead, true)
        XCTAssertNotNil(atHead.first?.tag)
        XCTAssertEqual(atHead.filter(\.isHead).count, 1)
        XCTAssertEqual(badges["aaa"]?.first?.isHead, false)
    }

    func testDetachedHeadWithoutRefsGetsAHeadLabel() {
        let refs = [ref("main", .localBranch, "aaa")]
        let badges = Parse.badges(refs, detachedHead: "ccc")
        XCTAssertEqual(badges["ccc"]?.first?.name, "HEAD")
        XCTAssertEqual(badges["ccc"]?.first?.target, "ccc")
        XCTAssertNil(Parse.badges(refs)["ccc"])
    }
}
