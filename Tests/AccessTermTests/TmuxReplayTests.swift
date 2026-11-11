import XCTest
@testable import AccessTerm

/// Replays a real tmux session (captured chunk by chunk with timestamps) through the session
/// and the narrator the way the app does: bytes that arrive within 30 ms of each other become
/// one frame. It is what the tmux behavior is checked against.
final class TmuxReplayTests: XCTestCase {
    private final class Sink: TerminalSessionDelegate {
        var frames: [ScreenFrame] = []
        func session(_ session: TerminalSession, didUpdate update: TerminalUpdate) {
            if let frame = update.alternateFrame { frames.append(frame) }
        }
        func session(_ session: TerminalSession, didCompleteLine buffer: String, cursor: Int) {}
        func sessionDidRingBell(_ session: TerminalSession) {}
        func session(_ session: TerminalSession, didChangeTitle title: String) {}
        func session(_ session: TerminalSession, didTerminateWithExitCode code: Int32?) {}
    }

    struct Step { var frame: ScreenFrame; var spoken: [String]? }

    /// Every frame of the capture with what the narrator says about it (nil: row diff).
    static func replay(_ name: String) throws -> [Step] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        let session = TerminalSession(cols: 80, rows: 24)
        let sink = Sink()
        session.delegate = sink
        var narrator = ScreenNarrator()
        var steps: [Step] = []
        var windowStart = -1000
        var pending = false
        func flush() {
            guard pending else { return }
            pending = false
            sink.frames = []
            session.publishUpdate()
            for frame in sink.frames { steps.append(Step(frame: frame, spoken: narrator.narrate(frame))) }
        }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let pair = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let at = pair[0] as? Int, let hex = pair[1] as? String else { continue }
            if pending, at - windowStart >= 30 { flush() }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            if !pending { windowStart = at; pending = true }
            session.dataReceived(slice: bytes[...])
        }
        flush()
        return steps
    }

    // MARK: - What a shell in tmux says

    /// Typing at a prompt says nothing, before and after vim has run in the same tmux.
    func testTypingAtThePromptIsSilent() throws {
        for name in ["tmux-shell-vim.jsonl", "tmux-shell-vim-nostatus.jsonl"] {
            let steps = try Self.replay(name)
            var typed = 0
            for (before, after) in zip(steps, steps.dropFirst()) {
                let a = before.frame, b = after.frame
                guard b.cursorRow == a.cursorRow, b.cursorCol == a.cursorCol + 1,
                      b.rows[b.cursorRow].hasPrefix("% "), a.rows[a.cursorRow].hasPrefix("% "),
                      b.rows[b.cursorRow].count == a.rows[a.cursorRow].count + 1,
                      b.rows.last == a.rows.last else { continue }
                typed += 1
                XCTAssertEqual(after.spoken ?? ["row diff"], [], "\(name): typing was spoken")
            }
            XCTAssertGreaterThan(typed, 8, name)
        }
    }

    /// Return runs a command: its output is read, then the fresh prompt, every time, whether
    /// the prompt is in the middle of the screen or at the bottom of a scrolled one.
    func testEnterReadsOutputThenPrompt() throws {
        for name in ["tmux-shell-vim.jsonl", "tmux-shell-vim-nostatus.jsonl"] {
            let steps = try Self.replay(name)
            let spoken = steps.compactMap { $0.spoken?.joined(separator: " / ") }
            XCTAssertTrue(spoken.contains("hi / percent"), "\(name): echo hi")
            XCTAssertTrue(spoken.contains { $0.hasSuffix("tmux dot log / percent") || $0.hasSuffix("tmux dot jsonl / percent") },
                          "\(name): ls output then the prompt")
            XCTAssertFalse(spoken.contains("space"), "\(name): a bare 'space' after Return")
        }
    }

    /// A shell that redraws what follows the cursor on every key (a suggestion, colors) does
    /// not make typing audible.
    func testSuggestionRedrawIsSilent() {
        func frame(_ text: String, col: Int) -> ScreenFrame {
            var rows = Array(repeating: "", count: 6)
            rows[2] = text
            return ScreenFrame(rows: rows, cursorRow: 2, cursorCol: col, cols: 80)
        }
        var n = ScreenNarrator()
        _ = n.narrate(frame("% ", col: 2))
        XCTAssertEqual(n.narrate(frame("% l  s -la", col: 3)) ?? ["x"], [])
        XCTAssertEqual(n.narrate(frame("% ls -la", col: 4)) ?? ["x"], [])
    }

    /// Typing after a vim that ran in the same screen is not vim's normal mode.
    func testTypingAfterVimIsSilent() {
        func vim(_ last: String) -> ScreenFrame {
            ScreenFrame(rows: ["one", "two", "three", "~", "~", last], cursorRow: 0, cursorCol: 0, cols: 80)
        }
        func shell(_ line: String, col: Int) -> ScreenFrame {
            var rows = ["% vim a", "", "", "", "", ""]
            rows[1] = line
            return ScreenFrame(rows: rows, cursorRow: 1, cursorCol: col, cols: 80)
        }
        var n = ScreenNarrator()
        _ = n.narrate(vim(""))
        _ = n.narrate(vim("-- INSERT --"))
        _ = n.narrate(vim(""))                 // back to normal: mode known
        _ = n.narrate(shell("% ", col: 2))     // the screen is replaced by the shell
        XCTAssertEqual(n.narrate(shell("% l", col: 3)) ?? ["x"], [])
        XCTAssertEqual(n.narrate(shell("% ls", col: 4)) ?? ["x"], [])
    }

    /// Return at the bottom of a full screen scrolls it: the output and the new prompt are
    /// read, and the new prompt is not mistaken for an edit of the old line.
    func testEnterAtTheBottomOfAScrolledScreen() {
        let rows1 = ["% a", "1", "% b", "2", "% ls x", ""]
        var n = ScreenNarrator()
        _ = n.narrate(ScreenFrame(rows: rows1, cursorRow: 4, cursorCol: 6, cols: 80))
        let rows2 = ["% b", "2", "% ls x", "out1", "out2", "% "]
        let spoken = n.narrate(ScreenFrame(rows: rows2, cursorRow: 5, cursorCol: 2, cols: 80))
        XCTAssertEqual(spoken ?? [], ["out1", "out2", "percent"])
    }

    /// vim scrolling one line at the bottom of a full screen is still just the new line.
    func testVimScrollIsNotOutput() {
        let before = ScreenFrame(rows: ["a", "b", "c", "d", "e", "f", ""], cursorRow: 5, cursorCol: 0, cols: 80)
        let after = ScreenFrame(rows: ["b", "c", "d", "e", "f", "g", ""], cursorRow: 5, cursorCol: 0, cols: 80)
        var n = ScreenNarrator()
        _ = n.narrate(before)
        XCTAssertEqual(n.narrate(after) ?? [], ["g"])
    }
}
