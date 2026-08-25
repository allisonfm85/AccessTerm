import Foundation
import SwiftTerm

/// One batch of changes derived from the terminal buffer.
struct TerminalUpdate {
    /// Lines that have scrolled above the cursor and will never change again.
    /// Wrapped continuation rows are already joined into single logical lines.
    var newLines: [String]
    /// Everything at and below the cursor that is not yet committed
    /// (typically the shell prompt, a partially printed line, or a progress line).
    var liveText: String
    /// Non-nil while a full-screen program (vim, htop, an attached session) owns the alternate screen.
    var alternateScreen: [String]?
}

protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: TerminalSession, didUpdate update: TerminalUpdate)
    func sessionDidRingBell(_ session: TerminalSession)
    func session(_ session: TerminalSession, didChangeTitle title: String)
    func session(_ session: TerminalSession, didTerminateWithExitCode code: Int32?)
}

/// Owns the pseudo-terminal, the shell process, and the VT parser.
/// The parser keeps a character grid (as any terminal does); this class turns that grid
/// into an append-only transcript of logical lines, which is what the UI presents to VoiceOver.
final class TerminalSession: TerminalDelegate, LocalProcessDelegate {
    weak var delegate: TerminalSessionDelegate?

    let cols: Int
    let rows: Int

    private var terminal: Terminal!
    private var process: LocalProcess!

    /// Scroll-invariant buffer row index up to which lines have been committed.
    private var committedRows = 0
    private var wasAlternate = false
    private var updateScheduled = false
    private(set) var isRunning = false

    /// Wide and tall so long lines wrap less and output settles into scrollback quickly.
    init(cols: Int = 160, rows: Int = 50) {
        self.cols = cols
        self.rows = rows
        terminal = Terminal(delegate: self,
                            options: TerminalOptions(cols: cols, rows: rows, scrollback: 100_000))
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    // MARK: - Process control

    func start(shell: String = "/bin/zsh") {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "AccessTerm"
        env["TERM_PROGRAM_VERSION"] = "0.1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env.removeValue(forKey: "LINES")
        env.removeValue(forKey: "COLUMNS")

        // Ask tools that know how to be screen-reader friendly to behave that way.
        env["CLAUDE_AX_SCREEN_READER"] = "1"   // Claude Code: flat, labeled, no redraws
        env["GH_ACCESSIBLE_PROMPTER"] = "1"    // GitHub CLI: numbered prompts instead of arrow menus
        env["GH_ACCESSIBLE_COLORS"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"

        let envArray = env.map { "\($0.key)=\($0.value)" }
        isRunning = true
        process.startProcess(executable: shell, args: ["-l"], environment: envArray)
    }

    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func send(bytes: [UInt8]) {
        guard isRunning, !bytes.isEmpty else { return }
        process.send(data: bytes[...])
    }

    // MARK: - TerminalDelegate (parser -> us)

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Replies the terminal must send back to the application (cursor position reports, etc.)
        guard isRunning else { return }
        process.send(data: data)
    }

    func bell(source: Terminal) {
        delegate?.sessionDidRingBell(self)
    }

    func bufferActivated(source: Terminal) {
        scheduleUpdate()
    }

    func setTerminalTitle(source: Terminal, title: String) {
        delegate?.session(self, didChangeTitle: title)
    }

    // MARK: - LocalProcessDelegate (pty -> us)

    func dataReceived(slice: ArraySlice<UInt8>) {
        terminal.feed(buffer: slice)
        scheduleUpdate()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        isRunning = false
        publishUpdate()
        delegate?.session(self, didTerminateWithExitCode: exitCode)
    }

    func getWindowSize() -> winsize {
        var size = winsize()
        size.ws_row = UInt16(rows)
        size.ws_col = UInt16(cols)
        return size
    }

    // MARK: - Transcript assembly

    /// Output arrives in many small chunks; coalesce so we commit whole lines, not fragments.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.updateScheduled = false
            self?.publishUpdate()
        }
    }

    private func publishUpdate() {
        let buffer = terminal.buffer

        // Full-screen programs: hand the whole screen to the UI, commit nothing.
        if terminal.isCurrentBufferAlternate {
            var screen: [String] = []
            for r in 0..<terminal.rows {
                guard let line = terminal.getLine(row: r) else { break }
                screen.append(line.translateToString(trimRight: true))
            }
            wasAlternate = true
            delegate?.session(self, didUpdate: TerminalUpdate(newLines: [], liveText: "", alternateScreen: screen))
            return
        }
        wasAlternate = false

        // Scroll-invariant rows count from the first line ever written, so they keep
        // identifying the same text after the scrollback cap starts recycling rows.
        // getTopVisibleRow is the application's screen top here: nothing scrolls the view.
        let screenTop = buffer.totalLinesTrimmed + terminal.getTopVisibleRow()
        let absCursor = screenTop + buffer.y

        // Scrollback was cleared (e.g. `clear`, Control-L with ESC[3J): resync.
        if absCursor < committedRows { committedRows = absCursor }
        // Rows recycled out of a full scrollback are gone and can no longer be committed.
        if committedRows < buffer.totalLinesTrimmed { committedRows = buffer.totalLinesTrimmed }

        // Never split a wrapped logical line: back up to the start of the group the cursor sits in.
        var commitEnd = absCursor
        while commitEnd > committedRows, isWrapped(commitEnd) {
            commitEnd -= 1
        }

        var newLines: [String] = []
        if commitEnd > committedRows {
            for row in committedRows..<commitEnd {
                let text = rowText(row)
                if isWrapped(row), !newLines.isEmpty {
                    newLines[newLines.count - 1] += text
                } else {
                    newLines.append(text)
                }
            }
            committedRows = commitEnd
        }

        // Live region: from the start of the cursor's line group to the bottom of the screen.
        var live: [String] = []
        let screenEnd = screenTop + terminal.rows
        if commitEnd < screenEnd {
            for row in commitEnd..<screenEnd {
                guard terminal.getScrollInvariantLine(row: row) != nil else { break }
                let text = rowText(row)
                if isWrapped(row), !live.isEmpty {
                    live[live.count - 1] += text
                } else {
                    live.append(text)
                }
            }
        }
        while let last = live.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            live.removeLast()
        }

        delegate?.session(self, didUpdate: TerminalUpdate(newLines: newLines,
                                                          liveText: live.joined(separator: "\n"),
                                                          alternateScreen: nil))
    }

    /// Whether the row is a continuation of the row above. Out-of-range rows are not.
    private func isWrapped(_ row: Int) -> Bool {
        terminal.getScrollInvariantLine(row: row)?.isWrapped ?? false
    }

    /// Text of one buffer row. Trailing spaces are kept when the next row is a wrapped
    /// continuation, because in that case they are real characters at the wrap point.
    private func rowText(_ row: Int) -> String {
        guard let line = terminal.getScrollInvariantLine(row: row) else { return "" }
        return line.translateToString(trimRight: !isWrapped(row + 1))
    }
}
