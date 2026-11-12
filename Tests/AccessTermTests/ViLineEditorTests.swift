import XCTest
@testable import AccessTerm

final class ViLineEditorTests: XCTestCase {
    /// Types keys into an editor that starts in normal mode on `line`, caret at `caret`.
    private struct Harness {
        var editor = ViLineEditor()
        var text: [Character]
        var caret: Int
        var effects: [[ViLineEditor.Effect]] = []

        init(_ line: String, caret: Int = 0) {
            text = Array(line)
            self.caret = caret
            var position = caret
            _ = editor.escape(text: text, caret: &position)   // insert -> normal, caret one back
            self.caret = caret
        }

        mutating func keys(_ keys: String) {
            for key in keys {
                effects.append(key == "\u{1b}" ? editor.escape(text: text, caret: &caret)
                                                : editor.normal(key, text: &text, caret: &caret))
            }
        }
        var line: String { String(text) }
        var last: [ViLineEditor.Effect] { effects.last ?? [] }
    }

    func testEscapeEntersNormalModeOneBack() {
        var e = ViLineEditor()
        var caret = 5
        let out = e.escape(text: Array("hello"), caret: &caret)
        XCTAssertEqual(e.mode, .normal)
        XCTAssertEqual(caret, 4)
        XCTAssertEqual(out, [.message("Normal mode")])
    }

    func testCharacterMotionsSayTheCharacterLandedOn() {
        var h = Harness("ls -l", caret: 0)
        h.keys("l")
        XCTAssertEqual(h.caret, 1); XCTAssertEqual(h.last, [.say("s")])
        h.keys("l"); XCTAssertEqual(h.last, [.say(" ")])
        h.keys("l"); XCTAssertEqual(h.last, [.say("-")])
        h.keys("$"); XCTAssertEqual(h.caret, 4)
        h.keys("l"); XCTAssertEqual(h.last, [.message("end of line")])
        h.keys("0"); XCTAssertEqual(h.caret, 0)
        h.keys("h"); XCTAssertEqual(h.last, [.message("start of line")])
    }

    func testWordMotionsSayTheWord() {
        var h = Harness("git commit -m fix", caret: 0)
        h.keys("w"); XCTAssertEqual(h.caret, 4); XCTAssertEqual(h.last, [.say("commit")])
        h.keys("w"); XCTAssertEqual(h.caret, 11); XCTAssertEqual(h.last, [.say("-")])
        h.keys("w"); XCTAssertEqual(h.caret, 12); XCTAssertEqual(h.last, [.say("m")])
        h.keys("b"); XCTAssertEqual(h.caret, 11)
        h.keys("e"); XCTAssertEqual(h.caret, 12)   // from the "-", e is the end of the next word
    }

    func testBigWordsAndEnd() {
        var h = Harness("ls -la /tmp/x", caret: 0)
        h.keys("W"); XCTAssertEqual(h.last, [.say("-la")])
        h.keys("E"); XCTAssertEqual(h.caret, 5)
        h.keys("W"); XCTAssertEqual(h.last, [.say("/tmp/x")])
        h.keys("B"); XCTAssertEqual(h.caret, 3)
        h.keys("$"); h.keys("b"); XCTAssertEqual(h.caret, 11)   // from x, b is the "/" before it
    }

    func testCountsAndDeleteWord() {
        var h = Harness("one two three four", caret: 0)
        h.keys("2w"); XCTAssertEqual(h.caret, 8)
        h.keys("0"); h.keys("dw")
        XCTAssertEqual(h.line, "two three four")
        XCTAssertEqual(h.last, [.deleted("one ")])
        h.keys("2dw")
        XCTAssertEqual(h.line, "four")
    }

    func testXAndDD() {
        var h = Harness("abc def", caret: 1)
        h.keys("x"); XCTAssertEqual(h.line, "ac def"); XCTAssertEqual(h.last, [.deleted("b")])
        h.keys("3x"); XCTAssertEqual(h.line, "aef")
        h.keys("dd"); XCTAssertEqual(h.line, ""); XCTAssertEqual(h.editor.register, "aef")
        h.keys("x"); XCTAssertEqual(h.last, [.message("empty")])
    }

    func testDeleteToEndAndStart() {
        var h = Harness("echo hello world", caret: 5)
        h.keys("D"); XCTAssertEqual(h.line, "echo "); XCTAssertEqual(h.caret, 4)
        h.keys("d0"); XCTAssertEqual(h.line, " ")
        var g = Harness("echo hello world", caret: 5)
        g.keys("d$"); XCTAssertEqual(g.line, "echo ")
    }

    func testChangeWordActsLikeChangeToEnd() {
        var h = Harness("echo hello world", caret: 5)
        h.keys("cw")
        XCTAssertEqual(h.line, "echo  world")
        XCTAssertEqual(h.editor.mode, .insert)
        XCTAssertEqual(h.last, [.deleted("hello"), .message("Insert mode")])
        XCTAssertEqual(h.caret, 5)
    }

    func testFindAndTill() {
        var h = Harness("a=b;c=d", caret: 0)
        h.keys("f;"); XCTAssertEqual(h.caret, 3); XCTAssertEqual(h.last, [.say(";")])
        h.keys("0"); h.keys("t;"); XCTAssertEqual(h.caret, 2)
        h.keys("0"); h.keys("fz"); XCTAssertEqual(h.last, [.message("not found")])
        h.keys("$"); h.keys("F="); XCTAssertEqual(h.caret, 5)
        h.keys("0"); h.keys("df;"); XCTAssertEqual(h.line, "c=d")
    }

    func testRepeatFind() {
        var h = Harness("a,b,c,d", caret: 0)
        h.keys("f,"); XCTAssertEqual(h.caret, 1)
        h.keys(";"); XCTAssertEqual(h.caret, 3)
        h.keys(","); XCTAssertEqual(h.caret, 1)
    }

    func testReplaceAndToggleCase() {
        var h = Harness("abc", caret: 0)
        h.keys("rx"); XCTAssertEqual(h.line, "xbc")
        h.keys("~"); XCTAssertEqual(h.line, "XBC".prefix(1) + "bc"); XCTAssertEqual(h.caret, 1)
        h.keys("2~"); XCTAssertEqual(h.line, "XBC")
    }

    func testYankAndPut() {
        var h = Harness("one two", caret: 0)
        h.keys("yw"); XCTAssertEqual(h.last, [.yanked("one ")]); XCTAssertEqual(h.line, "one two")
        h.keys("$"); h.keys("p"); XCTAssertEqual(h.line, "one twoone "); XCTAssertEqual(h.last, [.pasted("one ")])
        h.keys("0"); h.keys("P"); XCTAssertEqual(h.line, "one one twoone ")
        XCTAssertEqual(h.caret, 3)
    }

    func testInsertCommands() {
        var h = Harness("abc", caret: 1)
        h.keys("a"); XCTAssertEqual(h.caret, 2); XCTAssertEqual(h.editor.mode, .insert)
        var g = Harness("  abc", caret: 4)
        g.keys("I"); XCTAssertEqual(g.caret, 2)
        var i = Harness("abc", caret: 0)
        i.keys("A"); XCTAssertEqual(i.caret, 3)
    }

    func testUndoAndRedo() {
        var h = Harness("one two", caret: 0)
        h.keys("dw"); XCTAssertEqual(h.line, "two")
        h.keys("x"); XCTAssertEqual(h.line, "wo")
        h.keys("u"); XCTAssertEqual(h.line, "two"); XCTAssertEqual(h.last, [.message("undone")])
        h.keys("u"); XCTAssertEqual(h.line, "one two")
        h.keys("u"); XCTAssertEqual(h.last, [.message("already at oldest change")])
        h.keys("\u{12}"); XCTAssertEqual(h.line, "two")
    }

    func testTypingInInsertIsOneUndoStep() {
        var e = ViLineEditor()
        var text = Array("")
        e.noteInsertEdit(text: text, caret: 0)
        text = Array("ls"); e.noteInsertEdit(text: text, caret: 2)   // second edit: no new step
        var caret = 2
        _ = e.escape(text: text, caret: &caret)
        _ = e.normal("u", text: &text, caret: &caret)
        XCTAssertEqual(String(text), "")
    }

    func testHistoryKeys() {
        var h = Harness("x", caret: 0)
        h.keys("k"); XCTAssertEqual(h.last, [.history(older: true)])
        h.keys("j"); XCTAssertEqual(h.last, [.history(older: false)])
    }

    func testUnknownKeyIsInvalid() {
        var h = Harness("x", caret: 0)
        h.keys("q"); XCTAssertEqual(h.last, [.invalid])
    }

    func testEscapeCancelsAPendingOperator() {
        var h = Harness("abc def", caret: 0)
        h.keys("d\u{1b}w")
        XCTAssertEqual(h.line, "abc def")
        XCTAssertEqual(h.caret, 4)
    }

    func testCaretStaysOnACharacterInNormalMode() {
        var h = Harness("abc", caret: 2)
        h.keys("x"); XCTAssertEqual(h.line, "ab"); XCTAssertEqual(h.caret, 1)
        h.keys("$"); h.keys("l"); XCTAssertEqual(h.caret, 1)
    }
}
