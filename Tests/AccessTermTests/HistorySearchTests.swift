import XCTest
@testable import AccessTerm

final class HistorySearchTests: XCTestCase {
    private let history = ["ls", "git status", "make build", "git commit -m x", "ls -la", "git push"]

    func testStartsOnNothing() {
        let search = HistorySearch(entries: history)
        XCTAssertNil(search.match)
        XCTAssertEqual(search.prompt, "(reverse-i-search)'': ")
    }

    func testTypingFindsNewestMatch() {
        var search = HistorySearch(entries: history)
        search.type("git")
        XCTAssertEqual(search.match, "git push")
    }

    func testOlderStepsBackAndStopsAtTheEnd() {
        var search = HistorySearch(entries: history)
        search.type("git")
        XCTAssertTrue(search.older())
        XCTAssertEqual(search.match, "git commit -m x")
        XCTAssertTrue(search.older())
        XCTAssertEqual(search.match, "git status")
        XCTAssertFalse(search.older())
        XCTAssertEqual(search.match, "git status")
    }

    func testNewerStepsForward() {
        var search = HistorySearch(entries: history)
        search.type("git")
        search.older()
        XCTAssertTrue(search.newer())
        XCTAssertEqual(search.match, "git push")
        XCTAssertFalse(search.newer())
    }

    func testLongerQueryKeepsMatchThatStillFits() {
        var search = HistorySearch(entries: history)
        search.type("git")
        search.older()                      // git commit -m x
        search.type(" c")
        XCTAssertEqual(search.match, "git commit -m x")
    }

    func testLongerQueryMovesOlderWhenCurrentNoLongerFits() {
        var search = HistorySearch(entries: history)
        search.type("git ")
        XCTAssertEqual(search.match, "git push")
        search.type("p")                    // "git p" still fits "git push"
        XCTAssertEqual(search.match, "git push")
        search.backspace()
        search.type("c")                    // "git c" does not, so it moves older
        XCTAssertEqual(search.match, "git commit -m x")
    }

    func testNoMatchFails() {
        var search = HistorySearch(entries: history)
        search.type("zzz")
        XCTAssertNil(search.match)
        XCTAssertTrue(search.failing)
        XCTAssertEqual(search.prompt, "(failing reverse-i-search)'zzz': ")
    }

    func testBackspaceRecoversFromFailureAndRestartsFromNewest() {
        var search = HistorySearch(entries: history)
        search.type("lsx")
        XCTAssertTrue(search.failing)
        search.backspace()
        XCTAssertFalse(search.failing)
        XCTAssertEqual(search.match, "ls -la")
    }

    func testBackspaceToEmptyClearsMatch() {
        var search = HistorySearch(entries: history)
        search.type("l")
        search.backspace()
        XCTAssertNil(search.match)
        XCTAssertEqual(search.query, "")
    }

    func testEmptyQueryOlderWalksFromNewest() {
        var search = HistorySearch(entries: history)
        XCTAssertTrue(search.older())
        XCTAssertEqual(search.match, "git push")
        XCTAssertTrue(search.older())
        XCTAssertEqual(search.match, "ls -la")
    }

    func testCaseInsensitive() {
        var search = HistorySearch(entries: history)
        search.type("MAKE")
        XCTAssertEqual(search.match, "make build")
    }

    func testRepeatsAreOfferedOnceAtTheirNewestPosition() {
        let search = HistorySearch(entries: ["a", "b", "a", "c"])
        XCTAssertEqual(search.entries, ["b", "a", "c"])
    }

    func testMultiLineEntriesSurvive() {
        var search = HistorySearch(entries: ["echo one", "for i in 1 2\ndo echo $i\ndone"])
        search.type("done")
        XCTAssertEqual(search.match, "for i in 1 2\ndo echo $i\ndone")
    }

    func testOlderAfterFailureWrapsToNewest() {
        var search = HistorySearch(entries: history)
        search.type("zzz")
        XCTAssertFalse(search.older())      // still nothing
        XCTAssertTrue(search.failing)
    }
}
