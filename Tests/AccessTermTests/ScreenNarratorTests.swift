import XCTest
@testable import AccessTerm

final class ScreenNarratorTests: XCTestCase {
    private let text = ["alpha beta gamma", "", "second line here", "third"]

    /// A 6-row screen: the text, a blank, and a last row.
    private func frame(_ rows: [String]? = nil, row: Int, col: Int, last: String = "",
                       visible: Bool = true) -> ScreenFrame {
        var r = rows ?? text
        r += Array(repeating: "~", count: max(0, 5 - r.count))
        r.append(last)
        return ScreenFrame(rows: r, cursorRow: row, cursorCol: col, cursorVisible: visible)
    }

    private func narrate(_ frames: ScreenFrame...) -> [[String]?] {
        var n = ScreenNarrator()
        return frames.map { n.narrate($0) }
    }

    func testFirstFrameIsSilent() {
        XCTAssertEqual(narrate(frame(row: 0, col: 0))[0] ?? ["x"], [])
    }

    func testCharacterMove() {
        let out = narrate(frame(row: 0, col: 0), frame(row: 0, col: 1))
        XCTAssertEqual(out[1] ?? [], ["l"])
    }

    func testWordMove() {
        let out = narrate(frame(row: 0, col: 0), frame(row: 0, col: 6))
        XCTAssertEqual(out[1] ?? [], ["beta"])
    }

    func testLineMove() {
        let out = narrate(frame(row: 0, col: 0), frame(row: 1, col: 0), frame(row: 2, col: 0))
        XCTAssertEqual(out[1] ?? [], ["blank"])
        XCTAssertEqual(out[2] ?? [], ["second line here"])
    }

    func testJumpToLineFarAway() {
        let out = narrate(frame(row: 0, col: 3), frame(row: 3, col: 0))
        XCTAssertEqual(out[1] ?? [], ["third"])
    }

    func testScrollWithCursorRowUnchangedReadsLine() {
        let scrolled = ["other text", "more", "stuff here", "tail"]
        let out = narrate(frame(row: 0, col: 0), frame(scrolled, row: 0, col: 0))
        XCTAssertEqual(out[1] ?? [], ["other text"])
    }

    func testTypingInInsertModeIsSilentAndModeAnnounced() {
        let typed = ["alphaX beta gamma"] + text.dropFirst()
        let out = narrate(frame(row: 0, col: 5),
                          frame(row: 0, col: 5, last: "-- INSERT --"),
                          frame(Array(typed), row: 0, col: 6, last: "-- INSERT --"),
                          frame(Array(typed), row: 0, col: 5))
        XCTAssertEqual(out[1] ?? [], ["Insert mode"])
        XCTAssertEqual(out[2] ?? ["x"], [])
        XCTAssertEqual((out[3] ?? []).first, "Normal mode")
    }

    func testDeleteCharReadsCharUnderCursor() {
        let after = ["lpha beta gamma"] + text.dropFirst()
        let out = narrate(frame(row: 0, col: 0), frame(Array(after), row: 0, col: 0))
        XCTAssertEqual(out[1] ?? [], ["l"])
    }

    func testDeleteLineReadsNewLine() {
        let after = ["", "second line here", "third"]
        let out = narrate(frame(row: 0, col: 0), frame(after, row: 0, col: 0))
        XCTAssertEqual(out[1] ?? [], ["blank"])
    }

    func testCommandLineEntryIsSpokenThenLineRead() {
        let out = narrate(frame(row: 0, col: 0),
                          frame(row: 5, col: 3, last: ":12"),
                          frame(row: 2, col: 0))
        XCTAssertEqual(out[1] ?? [], ["Command"])
        XCTAssertEqual(out[2] ?? [], ["second line here"])
    }

    func testMessageIsSpoken() {
        let out = narrate(frame(row: 0, col: 0), frame(row: 0, col: 0, last: "E486: Pattern not found: zzz"))
        XCTAssertEqual(out[1] ?? [], ["E486 colon Pattern not found colon zzz"])
    }

    func testRulerChangeIsNotAMessage() {
        let a = frame(row: 0, col: 0, last: String(repeating: " ", count: 140) + "1,1   All")
        let b = frame(row: 0, col: 1, last: String(repeating: " ", count: 140) + "1,2   All")
        XCTAssertEqual(narrate(a, b)[1] ?? [], ["l"])
    }

    func testHiddenCursorFallsBackToRowDiff() {
        let out = narrate(frame(row: 0, col: 0, visible: false), frame(row: 0, col: 0, visible: false),
                          frame(row: 0, col: 0, visible: false))
        XCTAssertNil(out[2])
    }

    func testPageTurnWithCursorStillFallsBackToRowDiff() {
        let a = frame(["a", "b", "c", "d"], row: 5, col: 1, last: ":")
        let b = frame(["e", "f", "g", "h"], row: 5, col: 1, last: ":")
        XCTAssertNil(narrate(a, b)[1])
    }

    func testLineNumberGutterIsLeftOff() {
        let rows = ["  1 alpha", "  2 beta", "  3 gamma", "  4 delta", "  5 eps"]
        let out = narrate(frame(rows, row: 0, col: 4), frame(rows, row: 1, col: 4))
        XCTAssertEqual(out[1] ?? [], ["beta"])
    }

    func testWrappedLineIsReadWhole() {
        var wide = ScreenFrame(rows: ["abcdef ", "ghi", "next", "", "~", ""], wrapped: [false, true, false, false, false, false],
                               cursorRow: 2, cursorCol: 0, cols: 7)
        var n = ScreenNarrator()
        _ = n.narrate(wide)
        wide.cursorRow = 0
        XCTAssertEqual(n.narrate(wide) ?? [], ["abcdef ghi"])
    }
}

final class SymbolAndScreenTextTests: XCTestCase {
    func testEveryAsciiSymbolHasAName() {
        for scalar in 33...126 {
            let c = Character(UnicodeScalar(UInt8(scalar)))
            if c.isLetter || c.isNumber { XCTAssertNil(SymbolSpeller.name(of: c)) }
            else { XCTAssertNotNil(SymbolSpeller.name(of: c), "no name for \(c)") }
        }
    }

    func testCharacterSymbolsAreNamed() {
        XCTAssertEqual(ScreenNarrator.character(at: 0, in: Array(":12")), "colon")
        XCTAssertEqual(ScreenNarrator.character(at: 0, in: Array("?")), "question mark")
    }

    func testLineSymbolsAreSpoken() {
        XCTAssertEqual(SymbolSpeller.spoken("def f(x):"), "def f open paren x close paren colon")
        XCTAssertEqual(SymbolSpeller.spoken("    a.b"), "a dot b")
    }

    func testSymbolsCanBeTurnedOff() {
        var n = ScreenNarrator()
        n.speaksSymbols = false
        let rows = ["ab. c", "x", "~", "~", "~", ""]
        _ = n.narrate(ScreenFrame(rows: rows, cursorRow: 0, cursorCol: 0))
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows, cursorRow: 0, cursorCol: 4)) ?? [], ["c"])
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows, cursorRow: 0, cursorCol: 0)) ?? [], ["ab"])
    }

    func testModesAndMessagesScopeIsSilentOnMovesButSpeaksModes() {
        var n = ScreenNarrator()
        n.scope = .modesAndMessages
        let rows = ["alpha beta", "two", "~", "~", "~"]
        _ = n.narrate(ScreenFrame(rows: rows + [""], cursorRow: 0, cursorCol: 0))
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows + [""], cursorRow: 1, cursorCol: 0)) ?? ["x"], [])
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows + ["-- INSERT --"], cursorRow: 1, cursorCol: 0)) ?? [],
                       ["Insert mode"])
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows + ["E486: nope"], cursorRow: 1, cursorCol: 0)) ?? [],
                       ["E486 colon nope"])
    }

    func testScreenTextLinesAndCursor() {
        let s = ScreenText(rows: ["one", "", "three four"], cursorRow: 2, cursorCol: 6)
        XCTAssertEqual(s.text, "one\n\nthree four")
        XCTAssertEqual(s.cursor, 4 + 1 + 6)
        XCTAssertEqual(s.line(for: s.cursor), 2)
        XCTAssertEqual(s.range(forLine: 1), NSRange(location: 4, length: 0))
        XCTAssertEqual(s.range(forLine: 2), NSRange(location: 5, length: 10))
        XCTAssertEqual(s.string(for: s.range(forLine: 0)), "one")
        XCTAssertEqual(s.cursorLine, "three four")
    }

    func testCursorPastRowEndClampsToRowEnd() {
        let s = ScreenText(rows: ["ab", "cd"], cursorRow: 0, cursorCol: 40)
        XCTAssertEqual(s.cursor, 2)
    }
}

final class CommandLineIndentRepeatTests: XCTestCase {
    private let body = ["alpha", "    beta", "        gamma", "delta", "", "~"]

    private func frame(last: String, row: Int, col: Int, rows: [String]? = nil) -> ScreenFrame {
        ScreenFrame(rows: (rows ?? body) + [last], cursorRow: row, cursorCol: col)
    }

    private func start() -> ScreenNarrator {
        var n = ScreenNarrator()
        _ = n.narrate(frame(last: "", row: 0, col: 0))
        return n
    }

    func testEnteringCommandLineKinds() {
        var n = start()
        XCTAssertEqual(n.narrate(frame(last: ":", row: 6, col: 1)) ?? [], ["Command"])
        var s = start()
        XCTAssertEqual(s.narrate(frame(last: "/", row: 6, col: 1)) ?? [], ["Search forward"])
        var b = start()
        XCTAssertEqual(b.narrate(frame(last: "?", row: 6, col: 1)) ?? [], ["Search backward"])
    }

    func testCommandLineTypingIsSilentAndMovesAreRead() {
        var n = start()
        _ = n.narrate(frame(last: ":", row: 6, col: 1))
        XCTAssertEqual(n.narrate(frame(last: ":set", row: 6, col: 4)) ?? ["x"], [])
        XCTAssertEqual(n.narrate(frame(last: ":set", row: 6, col: 3)) ?? [], ["t"])
        XCTAssertEqual(n.narrate(frame(last: ":set", row: 6, col: 1)) ?? [], ["set"])
    }

    func testCommandLineDeleteSpeaksWhatWentAndHistoryReadsWhole() {
        var n = start()
        _ = n.narrate(frame(last: ":", row: 6, col: 1))
        _ = n.narrate(frame(last: ":set", row: 6, col: 4))
        XCTAssertEqual(n.narrate(frame(last: ":se", row: 6, col: 3)) ?? [], ["t"])
        XCTAssertEqual(n.narrate(frame(last: ":write", row: 6, col: 6)) ?? [], ["write"])
    }

    func testLeavingCommandLineReadsTheLine() {
        var n = start()
        _ = n.narrate(frame(last: ":", row: 6, col: 1))
        XCTAssertEqual(n.narrate(frame(last: ":", row: 1, col: 4)) ?? [], ["indent 4, beta"])
    }

    func testIndentSpokenOnChangeOnly() {
        var n = start()
        XCTAssertEqual(n.narrate(frame(last: "", row: 1, col: 4)) ?? [], ["indent 4, beta"])
        XCTAssertEqual(n.narrate(frame(last: "", row: 2, col: 8)) ?? [], ["indent 8, gamma"])
        XCTAssertEqual(n.narrate(frame(last: "", row: 3, col: 0)) ?? [], ["no indent, delta"])
        XCTAssertEqual(n.narrate(frame(last: "", row: 4, col: 0)) ?? [], ["blank"])
        XCTAssertEqual(n.narrate(frame(last: "", row: 0, col: 0)) ?? [], ["alpha"])
    }

    func testIndentOffAndTones() {
        var off = start()
        off.indentation = .off
        XCTAssertEqual(off.narrate(frame(last: "", row: 1, col: 4)) ?? [], ["beta"])
        var tones = start()
        tones.indentation = .tones
        XCTAssertEqual(tones.narrate(frame(last: "", row: 1, col: 4)) ?? [], ["beta"])
        XCTAssertEqual(tones.lastTone, 4)
        _ = tones.narrate(frame(last: "", row: 3, col: 0))
        XCTAssertNil(tones.lastTone)
    }

    func testRepeatedSymbolsAreCounted() {
        let hashes = String(repeating: "#", count: 50)
        XCTAssertEqual(SymbolSpeller.spoken(hashes, names: true, repeatThreshold: 4), "50 hash")
        XCTAssertEqual(SymbolSpeller.spoken("a ### b", names: true, repeatThreshold: 4), "a hash hash hash b")
        XCTAssertEqual(SymbolSpeller.spoken("a #### b", names: true, repeatThreshold: 4), "a 4 hash b")
        XCTAssertEqual(SymbolSpeller.spoken(hashes, names: false, repeatThreshold: 4), "50 #")
        XCTAssertTrue(SymbolSpeller.spoken(hashes, names: true, repeatThreshold: 0).hasPrefix("hash hash"))
        XCTAssertEqual(SymbolSpeller.spoken("aaaaaa", names: true, repeatThreshold: 4), "aaaaaa")
    }

    func testRepeatsInLineReading() {
        var n = start()
        n.repeatThreshold = 4
        let rows = [String(repeating: "=", count: 30), "x", "", "", "", "~"]
        _ = n.narrate(ScreenFrame(rows: rows + [""], cursorRow: 0, cursorCol: 0))
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows + [""], cursorRow: 1, cursorCol: 0)) ?? [], ["x"])
        XCTAssertEqual(n.narrate(ScreenFrame(rows: rows + [""], cursorRow: 0, cursorCol: 0)) ?? [], ["30 equals"])
    }

    func testReadingOfFrame() {
        let n = ScreenNarrator()
        let r = n.reading(of: frame(last: "", row: 1, col: 4))
        XCTAssertEqual(r.line, "indent 4, beta")
        XCTAssertEqual(r.word, "beta")
        XCTAssertEqual(r.character, "b")
    }

    func testToneWavIsValidAndPitchDiffers() {
        let a = ToneSpeaker.wav(forIndent: 4), b = ToneSpeaker.wav(forIndent: 8)
        XCTAssertEqual(String(decoding: a.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: a[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(a.count, 44 + Int(Double(ToneSpeaker.sampleRate) * ToneSpeaker.duration) * 2)
        XCTAssertNotEqual(a, b)
        XCTAssertLessThan(ToneSpeaker.frequency(forIndent: 4), ToneSpeaker.frequency(forIndent: 8))
    }
}
