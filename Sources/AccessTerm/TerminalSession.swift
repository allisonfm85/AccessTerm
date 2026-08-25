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
    /// Commands that finished while this batch was being read, for announcing alongside it.
    var finishedCommands: [CommandBlock] = []
}

/// One command, its output and how it ended, as marked by OSC 133. Everything is in
/// transcript lines, so the UI can work in the units it already has.
struct CommandBlock {
    /// The prompt, ending with the line the command was typed on.
    var promptLines: Range<Int>
    /// What was typed, read back off the command line between the B and C markers.
    var command: String
    /// The output on its own: no prompt, no command line.
    var outputLines: Range<Int>
    /// Nil until the command finishes, and after that nil only if the shell reported no code.
    var exitCode: Int32?
    /// Whether the closing marker has arrived. A command still running is not finished.
    var isFinished: Bool

    /// The line the command is on, which is the last line of the prompt.
    var commandLine: Int { max(promptLines.lowerBound, promptLines.upperBound - 1) }
    /// Prompt, command and output together: what "the block the caret is in" means.
    var allLines: Range<Int> {
        min(promptLines.lowerBound, outputLines.lowerBound)..<max(promptLines.upperBound, outputLines.upperBound)
    }
    var failed: Bool { (exitCode ?? 0) != 0 }
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
    /// Transcript lines committed so far, counting lines the app added itself: block line
    /// numbers are transcript line numbers, so anything the transcript holds has to be counted
    /// here or every block after it points a line too high. See noteExternalTranscriptLines.
    private var committedLines = 0

    /// Command blocks as the markers describe them, oldest first.
    private var rawBlocks: [RawBlock] = []
    /// Marker positions waiting for their buffer row to be committed, so the row can be turned
    /// into a transcript line. A marker lands on the row the cursor is on, which is always at
    /// or past the commit point, so anchors only ever resolve forwards.
    private var pendingAnchors: [Int: [(block: Int, anchor: Anchor)]] = [:]
    /// Blocks that finished since the last update went out.
    private var justFinished: [Int] = []
    private var wasAlternate = false
    private var updateScheduled = false
    private(set) var isRunning = false

    /// Diagnostic only: when ACCESSTERM_LOG names a path, every byte the pty produces is
    /// appended to that file exactly as it arrived, escape sequences and all. It is the
    /// ground truth to compare the assembled transcript against when a program's output
    /// comes out wrong. Nil when the variable is unset, which is the normal case.
    private let rawLog: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["ACCESSTERM_LOG"],
              !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }()

    /// Wide and tall so long lines wrap less and output settles into scrollback quickly.
    init(cols: Int = 160, rows: Int = 50) {
        self.cols = cols
        self.rows = rows
        // Terminal.init lays out tab stops against SwiftTerm's default 80 columns rather than
        // options.cols, so a wider terminal ends up with no stops past column 72 and the first
        // tab beyond it jumps to the last column instead. `ls` separates its columns with tabs,
        // so that splits a filename across the wrap. Terminal.resize is the one public path that
        // rebuilds the stops, and it returns early if the size already matches, so build the
        // terminal at the default size and resize up to the one we actually want.
        terminal = Terminal(delegate: self, options: TerminalOptions(scrollback: 100_000))
        terminal.resize(cols: cols, rows: rows)
        // Command blocks. A registered handler takes precedence over SwiftTerm's own OSC 133
        // handling, which tracks semantic prompt marks per row -- of no use here, because the
        // transcript is addressed by logical line rather than by buffer row.
        terminal.registerOscHandler(code: 133) { [weak self] data in
            self?.handleCommandMarker(data)
        }
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

        // Command blocks: zsh reads its startup files from ZDOTDIR, so point it at one of
        // ours, which sources theirs and adds the markers. Their own ZDOTDIR has to be handed
        // over separately -- it is about to be overwritten, and the files there need it to
        // find the dotfiles they are standing in for.
        if let zdotdir = ShellIntegration.prepareZDotDir() {
            env["ACCESSTERM_USER_ZDOTDIR"] = env["ZDOTDIR"] ?? NSHomeDirectory()
            env["ACCESSTERM_ZDOTDIR"] = zdotdir.path
            env["ZDOTDIR"] = zdotdir.path
        }

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
        rawLog?.write(Data(slice))
        terminal.feed(buffer: slice)
        scheduleUpdate()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        isRunning = false
        try? rawLog?.close()
        publishUpdate()
        delegate?.session(self, didTerminateWithExitCode: exitCode)
    }

    func getWindowSize() -> winsize {
        var size = winsize()
        size.ws_row = UInt16(rows)
        size.ws_col = UInt16(cols)
        return size
    }

    // MARK: - Command blocks

    /// Which part of a block a marker fixes in place.
    private enum Anchor { case prompt, command, outputStart, outputEnd }

    /// A block as the markers describe it. Buffer rows arrive first and become transcript
    /// lines as those rows are committed; the two are kept apart because a marker's row is
    /// usually still on screen and uncommitted when it arrives. D in particular lands on the
    /// row the next prompt will be drawn on, which is not committed until the command after
    /// that one runs.
    private struct RawBlock {
        /// Column the command starts at, which is where the prompt ended.
        var commandColumn = 0
        var exitCode: Int32?
        var isFinished = false
        /// Whether the command ever started running. A prompt sitting waiting for input has
        /// not, and is not a block worth showing anyone.
        var didRun = false

        var promptLine: Int?
        var commandLine: Int?
        var outputStart: Int?
        var outputEnd: Int?
        var command = ""
    }

    /// The commands seen so far, oldest first.
    var commandBlocks: [CommandBlock] {
        guard hasCommandMarkers else {
            // Nothing is marking commands -- an older shell, or a user who has ZDOTDIR locked
            // down. The whole transcript is one block, so everything that works on "the block
            // the caret is in" still has something to work on.
            return [CommandBlock(promptLines: 0..<0, command: "",
                                 outputLines: 0..<committedLines, exitCode: nil, isFinished: false)]
        }
        return rawBlocks.compactMap(published)
    }

    /// Whether the shell is reporting command boundaries at all.
    var hasCommandMarkers: Bool { !rawBlocks.isEmpty }

    /// A block in transcript terms. Anything a marker has not pinned down yet reads as "up to
    /// where the transcript currently ends", which is what an unfinished command's output is.
    private func published(_ block: RawBlock) -> CommandBlock? {
        guard block.didRun || block.isFinished || !block.command.isEmpty else { return nil }
        let prompt = block.promptLine ?? block.commandLine ?? committedLines
        let command = max(prompt, block.commandLine ?? prompt)
        let outputStart = max(command + 1, block.outputStart ?? committedLines)
        let outputEnd = max(outputStart, block.outputEnd ?? committedLines)
        return CommandBlock(promptLines: prompt..<(command + 1),
                            command: block.command,
                            outputLines: outputStart..<outputEnd,
                            exitCode: block.exitCode,
                            isFinished: block.isFinished)
    }

    /// Lines the app put in the transcript itself, rather than the shell: the ready message at
    /// launch, the exit message at the end. Blocks are numbered in transcript lines, so these
    /// have to be counted too.
    func noteExternalTranscriptLines(_ count: Int) {
        committedLines += count
    }

    /// Where a marker arriving now would land, in the same scroll-invariant rows the
    /// transcript is committed in.
    private var cursorRow: Int {
        terminal.buffer.totalLinesTrimmed + terminal.getTopVisibleRow() + terminal.buffer.y
    }

    /// OSC 133: A before the prompt, B where the command is typed, C when it starts running,
    /// D with the exit code when it finishes. Called from inside the parser, so the cursor is
    /// wherever the marker appeared.
    private func handleCommandMarker(_ data: ArraySlice<UInt8>) {
        guard !terminal.isCurrentBufferAlternate,
              let payload = String(bytes: data, encoding: .utf8) else { return }
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let kind = fields.first?.first else { return }
        let row = cursorRow

        switch kind {
        case "A", "N":
            rawBlocks.append(RawBlock())
            anchor(.prompt, row: row)
        case "B":
            openBlock()
            rawBlocks[rawBlocks.count - 1].commandColumn = terminal.buffer.x
            anchor(.command, row: row)
        case "C":
            openBlock()
            rawBlocks[rawBlocks.count - 1].didRun = true
            anchor(.outputStart, row: row)
        case "D":
            openBlock()
            let index = rawBlocks.count - 1
            rawBlocks[index].isFinished = true
            if fields.count > 1 { rawBlocks[index].exitCode = Int32(fields[1]) }
            anchor(.outputEnd, row: row)
            justFinished.append(index)
        default:
            break
        }
    }

    /// Markers can start anywhere: Claude Code emits C and D around its own turns without
    /// having drawn a prompt, and a session attached mid-command has missed A entirely.
    private func openBlock() {
        if rawBlocks.isEmpty || rawBlocks[rawBlocks.count - 1].isFinished {
            rawBlocks.append(RawBlock())
        }
    }

    private func anchor(_ anchor: Anchor, row: Int) {
        pendingAnchors[row, default: []].append((block: rawBlocks.count - 1, anchor: anchor))
    }

    /// Turns the markers waiting on this row into transcript lines.
    private func resolveAnchors(row: Int, line: Int) {
        guard let waiting = pendingAnchors.removeValue(forKey: row) else { return }
        for (block, anchor) in waiting where block < rawBlocks.count {
            switch anchor {
            case .prompt: rawBlocks[block].promptLine = line
            case .command: rawBlocks[block].commandLine = line
            case .outputStart: rawBlocks[block].outputStart = line
            case .outputEnd: rawBlocks[block].outputEnd = line
            }
        }
    }

    /// Reads command text off the lines just committed. It has to happen after the whole
    /// batch, not as each row lands: a wrapped command line is not complete until the last
    /// row of the group has been joined onto it.
    private func readCommands(from newLines: [String], firstLine: Int) {
        guard !newLines.isEmpty else { return }
        let committed = firstLine..<(firstLine + newLines.count)
        for index in rawBlocks.indices where rawBlocks[index].command.isEmpty {
            guard let line = rawBlocks[index].commandLine, committed.contains(line) else { continue }
            let text = Array(newLines[line - firstLine])
            let column = min(rawBlocks[index].commandColumn, text.count)
            rawBlocks[index].command = String(text[column...])
                .trimmingCharacters(in: .whitespaces)
        }
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
                screen.append(lineText(line, trimRight: true))
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

        // Scrollback was cleared (e.g. `clear`, Control-L with ESC[3J): resync. Rows have
        // been renumbered under the markers still waiting on one, so those are dropped; their
        // blocks fall back to reading as "up to the end of the transcript".
        if absCursor < committedRows {
            committedRows = absCursor
            pendingAnchors.removeAll()
        }
        // Rows recycled out of a full scrollback are gone and can no longer be committed.
        if committedRows < buffer.totalLinesTrimmed { committedRows = buffer.totalLinesTrimmed }

        // Never split a wrapped logical line: back up to the start of the group the cursor sits in.
        var commitEnd = absCursor
        while commitEnd > committedRows, isWrapped(commitEnd) {
            commitEnd -= 1
        }

        var newLines: [String] = []
        let firstNewLine = committedLines
        if commitEnd > committedRows {
            for row in committedRows..<commitEnd {
                let text = rowText(row)
                if isWrapped(row), !newLines.isEmpty {
                    newLines[newLines.count - 1] += text
                } else {
                    newLines.append(text)
                }
                // Wrapped rows join the line above, so several rows can resolve to one line.
                resolveAnchors(row: row, line: firstNewLine + newLines.count - 1)
            }
            committedRows = commitEnd
            committedLines += newLines.count
            readCommands(from: newLines, firstLine: firstNewLine)
            // Rows that went past uncommitted -- recycled out of a full scrollback -- are
            // never coming back.
            pendingAnchors = pendingAnchors.filter { $0.key >= committedRows }
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

        let finished = justFinished.compactMap { index -> CommandBlock? in
            index < rawBlocks.count ? published(rawBlocks[index]) : nil
        }
        justFinished.removeAll()

        delegate?.session(self, didUpdate: TerminalUpdate(newLines: newLines,
                                                          liveText: live.joined(separator: "\n"),
                                                          alternateScreen: nil,
                                                          finishedCommands: finished))
    }

    /// Whether the row is a continuation of the row above. Out-of-range rows are not.
    private func isWrapped(_ row: Int) -> Bool {
        terminal.getScrollInvariantLine(row: row)?.isWrapped ?? false
    }

    /// Text of one buffer line.
    ///
    /// Cells a program never wrote hold a null rune, which renders as nothing: `ls` tabs
    /// across its columns rather than padding them, so without this the filenames run
    /// together. Emit those cells as a single space. `skipNullCellsFollowingWide` keeps the
    /// null padding cell that trails a double-width character from becoming a second space.
    private func lineText(_ line: BufferLine, trimRight: Bool) -> String {
        let text = line.translateToString(
            trimRight: trimRight,
            skipNullCellsFollowingWide: true,
            characterProvider: { cell in
                let character = cell.getCharacter()
                return character == "\0" ? " " : character
            })
        // A literal tab would collapse to nothing in the row for the same reason.
        return text.replacingOccurrences(of: "\t", with: " ")
    }

    /// Text of one transcript row. Trailing spaces are kept when the next row is a wrapped
    /// continuation, because in that case they are real characters at the wrap point.
    private func rowText(_ row: Int) -> String {
        guard let line = terminal.getScrollInvariantLine(row: row) else { return "" }
        return lineText(line, trimRight: !isWrapped(row + 1))
    }
}
