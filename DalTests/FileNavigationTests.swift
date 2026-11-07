import XCTest
@testable import Dal

/// ↑/↓ in a diff move through the files listed in the right panel.
@MainActor
final class FileNavigationTests: XCTestCase {
    func testArrowKeysWalkTheListAndStopAtTheEnds() {
        let store = RepoStore(url: URL(fileURLWithPath: "/tmp/none"))
        let files = ["a.txt", "b.txt", "c.txt"].map { FileChange(path: $0, oldPath: nil, kind: .modified) }
        store.fileOrder = files.map { FileFocus.working($0, staged: false) } + [.working(files[0], staged: true)]

        XCTAssertFalse(store.moveFileFocus(1), "no open file: the graph keeps the arrow keys")
        store.fileFocus = .working(files[0], staged: false)
        XCTAssertTrue(store.moveFileFocus(1))
        XCTAssertEqual(store.fileFocus, .working(files[1], staged: false))
        store.moveFileFocus(2)
        XCTAssertEqual(store.fileFocus, .working(files[0], staged: true), "continues from unstaged into staged")
        store.moveFileFocus(1)
        XCTAssertEqual(store.fileFocus, .working(files[0], staged: true), "stops at the last file")
        store.moveFileFocus(-10)
        XCTAssertEqual(store.fileFocus, .working(files[0], staged: false), "stops at the first file")
    }
}
