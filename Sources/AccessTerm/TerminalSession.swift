import Foundation
import SwiftTerm

/// One batch of changes derived from the terminal buffer.
struct TerminalUpdate {
    /// Lines added to the end of the transcript in this batch.
    var newLines: [String] = []
    /// Transcript index of the first of those lines.
    var firstNewLine: Int = 0
    /// Lines already in the transcript whose rows were redrawn, as replacements to apply to
    /// a mirror of the transcript, in the order they are given.
    var edits: [Transcript.Edit] = []
    /// Everything at and below the cursor that is not yet part of a line
    /// (typically the shell prompt, a partially printed line, or a progress line). When the
    /// cursor is parked on an empty row under a frame that was just redrawn, this is the
    /// nearest line of that frame instead, which is what someone asking "what is on screen
    /// right now" means.
    var liveText: String = ""
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
/// The parser keeps a character grid (as any terminal does); this class turns that grid into
/// the transcript of logical lines the UI presents to VoiceOver. Rows become lines as the
/// cursor passes them, and a row that is redrawn afterwards rewrites the line it produced,
/// so a program that repaints its own output in place reads as one changing line rather than
/// as one copy per frame.
final class TerminalSession: TerminalDelegate, LocalProcessDelegate {
    weak var delegate: TerminalSessionDelegate?

    let cols: Int
    let rows: Int

    /// The lines themselves. The UI mirrors this; nothing else writes to it.
    let transcript = Transcript()

    private var terminal: Terminal!
    private var process: LocalProcess!

    /// One past the last scroll-invariant row that has been turned into a transcript line.
    private var extentRow = 0
    /// The lowest row that still has a line: rows below this were recycled out of the
    /// scrollback or renumbered by a clear, and are not ours to re-read.
    private var mappedFrom = 0
    /// For each transcript line, the rows it was built from. Lines the app added itself have
    /// no rows, and lines whose rows have been renumbered lose theirs.
    private var lineRows: [Range<Int>] = []
    /// Row to the line it is part of, so a redrawn row can find the line to rewrite.
    private var rowToLine: [Int: Int] = [:]
    /// Buffer coordinates as of the last update, to notice the buffer being renumbered under
    /// us (see the resync in publishUpdate).
    private var lastTop = 0
    private var lastTrimmed = 0
    /// First row of the last frame that was painted, which is as far back as "what is on
    /// screen right now" reaches when the cursor is parked on a blank row under it.
    private var frameStart = 0
    /// Where the cursor was when the screen was last wiped, if that has happened since the
    /// last update. Whatever is drawn next starts there, which is not necessarily where the
    /// cursor has got to by the time the update runs.
    private var screenErasedAt: Int?

    /// Command blocks as the markers describe them, oldest first.
    private var rawBlocks: [RawBlock] = []
    /// Marker positions waiting for their buffer row to become a transcript line. Markers
    /// that land on a row that is already a line are resolved as they arrive instead.
    private var pendingAnchors: [Int: [(block: Int, anchor: Anchor)]] = [:]
    /// Blocks that finished since the last update went out.
    private var justFinished: [Int] = []
    private var updateScheduled = false
    private(set) var isRunning = false

    /// Rows for a line that did not come from the buffer.
    private static let noRows = 0..<0

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

    /// Sends a line the user typed.
    ///
    /// The Return at the end goes as a write of its own, a moment after the text. Programs
    /// that read their own input decide whether a chunk was typed or pasted by how much of it
    /// arrives at once, and Claude Code treats anything over about sixty bytes as a paste --
    /// which means a Return in the same write is pasted text, not "send this". Splitting the
    /// write leaves the Return unmistakable however long the line is. When the program has
    /// asked for bracketed paste, the text is wrapped in the paste markers as well, so it is
    /// told what it was rather than left to guess.
    func send(text: String) {
        guard let terminator = text.last, terminator == "\r" || terminator == "\n" else {
            send(bytes: Array(text.utf8))
            return
        }
        let body = String(text.dropLast())
        if !body.isEmpty {
            if terminal.bracketedPasteMode {
                send(bytes: Array("\u{1b}[200~\(body)\u{1b}[201~".utf8))
            } else {
                send(bytes: Array(body.utf8))
            }
        }
        let tail = Array(String(terminator).utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.send(bytes: tail)
        }
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
        // What is on the screen becomes lines before anything wipes it: otherwise the line a
        // screen-clearing command was typed on is gone before it was ever read, and its
        // output arrives in the transcript with no command above it.
        if wipesScreen(slice) { publishUpdate() }
        terminal.feed(buffer: slice)
        noteScreenErase()
        scheduleUpdate()
    }

    /// Whether this chunk is about to erase the screen (ED 2), the scrollback (ED 3) or the
    /// terminal (RIS).
    private func wipesScreen(_ bytes: ArraySlice<UInt8>) -> Bool {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == 0x1b else {
                index += 1
                continue
            }
            let rest = bytes[index...].prefix(4)
            if rest.count > 1, rest[rest.startIndex + 1] == UInt8(ascii: "c") { return true }
            if rest.count > 3, rest[rest.startIndex + 1] == UInt8(ascii: "["),
               rest[rest.startIndex + 3] == UInt8(ascii: "J"),
               rest[rest.startIndex + 2] == UInt8(ascii: "2") || rest[rest.startIndex + 2] == UInt8(ascii: "3") {
                return true
            }
            index += 1
        }
        return false
    }

    /// Notices `clear` and its relatives: the cursor sent home and every row on the screen
    /// blank. It has to be checked as the bytes arrive rather than when an update is
    /// published, because the shell paints its prompt into the cleared screen a moment later
    /// and by then it no longer looks wiped. The test past the cursor check is only reached
    /// on the rare chunk that leaves the cursor at the top left corner.
    private func noteScreenErase() {
        guard !terminal.isCurrentBufferAlternate,
              terminal.buffer.x == 0, terminal.buffer.y == 0 else { return }
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { break }
            if !lineText(line, trimRight: true).isEmpty { return }
        }
        screenErasedAt = cursorRow
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
    /// lines as those rows are read; the two are kept apart because a marker's row is often
    /// still uncommitted when it arrives. D in particular lands on the row the next prompt
    /// will be drawn on, which is not a line until the command after that one runs.
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
                                 outputLines: 0..<transcript.count, exitCode: nil, isFinished: false)]
        }
        return rawBlocks.compactMap(published)
    }

    /// Whether the shell is reporting command boundaries at all.
    var hasCommandMarkers: Bool { !rawBlocks.isEmpty }

    /// A block in transcript terms. Anything a marker has not pinned down yet reads as "up to
    /// where the transcript currently ends", which is what an unfinished command's output is.
    private func published(_ block: RawBlock) -> CommandBlock? {
        guard block.didRun || block.isFinished || !block.command.isEmpty else { return nil }
        let prompt = block.promptLine ?? block.commandLine ?? transcript.count
        let command = max(prompt, block.commandLine ?? prompt)
        let outputStart = max(command + 1, block.outputStart ?? transcript.count)
        let outputEnd = max(outputStart, block.outputEnd ?? transcript.count)
        return CommandBlock(promptLines: prompt..<(command + 1),
                            command: block.command,
                            outputLines: outputStart..<outputEnd,
                            exitCode: block.exitCode,
                            isFinished: block.isFinished)
    }

    /// Lines the app puts in the transcript itself, rather than the shell: the ready message
    /// at launch, the exit message at the end. They are lines like any other, so they take
    /// transcript numbers like any other, but no row ever maps to them.
    func appendExternal(_ lines: [String]) {
        for line in lines {
            transcript.append(line)
            lineRows.append(TerminalSession.noRows)
        }
    }

    /// Where a marker arriving now would land, in the same scroll-invariant rows lines are
    /// built from.
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
            // A prompt that has not run anything yet and gets marked again is the same prompt
            // being redrawn, not a new one: Claude Code marks every frame it paints. Re-anchor
            // it where it is now instead of opening a block per frame.
            if let last = rawBlocks.last, !last.didRun, !last.isFinished {
                rawBlocks[rawBlocks.count - 1].promptLine = nil
                rawBlocks[rawBlocks.count - 1].commandLine = nil
            } else {
                rawBlocks.append(RawBlock())
            }
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
        let block = rawBlocks.count - 1
        // A marker on a row that is already a line -- a redrawn prompt, most often -- has
        // nothing to wait for.
        if let line = rowToLine[row] {
            resolve(anchor, block: block, line: line)
        } else {
            pendingAnchors[row, default: []].append((block: block, anchor: anchor))
        }
    }

    private func resolve(_ anchor: Anchor, block: Int, line: Int) {
        guard rawBlocks.indices.contains(block) else { return }
        switch anchor {
        case .prompt: rawBlocks[block].promptLine = line
        case .command: rawBlocks[block].commandLine = line
        case .outputStart: rawBlocks[block].outputStart = line
        case .outputEnd: rawBlocks[block].outputEnd = line
        }
    }

    /// Turns the markers waiting on this row into transcript lines.
    private func resolveAnchors(row: Int, line: Int) {
        guard let waiting = pendingAnchors.removeValue(forKey: row) else { return }
        for (block, anchor) in waiting {
            resolve(anchor, block: block, line: line)
        }
    }

    /// Reads command text off the lines this batch touched. It has to happen after the whole
    /// batch, not as each row lands: a wrapped command line is not complete until the last
    /// row of the group has been joined onto it.
    private func readCommands(touching lines: Set<Int>) {
        guard !lines.isEmpty else { return }
        for index in rawBlocks.indices where rawBlocks[index].command.isEmpty {
            guard let line = rawBlocks[index].commandLine, lines.contains(line),
                  transcript.lines.indices.contains(line) else { continue }
            let text = Array(transcript.lines[line])
            let column = min(rawBlocks[index].commandColumn, text.count)
            rawBlocks[index].command = String(text[column...])
                .trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Transcript assembly

    /// Output arrives in many small chunks; coalesce so we read whole frames, not fragments.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.updateScheduled = false
            self?.publishUpdate()
        }
    }

    func publishUpdate() {
        let buffer = terminal.buffer

        // Full-screen programs: hand the whole screen to the UI, build no lines.
        if terminal.isCurrentBufferAlternate {
            var screen: [String] = []
            for r in 0..<terminal.rows {
                guard let line = terminal.getLine(row: r) else { break }
                screen.append(lineText(line, trimRight: true))
            }
            terminal.clearUpdateRange()
            delegate?.session(self, didUpdate: TerminalUpdate(alternateScreen: screen))
            return
        }

        // Scroll-invariant rows count from the first line ever written, so they keep
        // identifying the same text as the screen scrolls.
        // getTopVisibleRow is the application's screen top here: nothing scrolls the view.
        let trimmed = buffer.totalLinesTrimmed
        let top = terminal.getTopVisibleRow()
        let screenTop = trimmed + top
        let absCursor = screenTop + buffer.y

        // The rows we have lines for are no longer the rows we had lines for: the scrollback
        // was thrown away (`clear`, Control-L with ESC[3J: the buffer is renumbered and both
        // of these run backwards) or the screen was wiped without renumbering anything, which
        // leaves the rows in place but hands them to whatever is drawn next. Either way the
        // lines built from them keep their text and let go of their rows, and rows start being
        // read again from the cursor. A program moving the cursor up to repaint its own output
        // is NOT this: that is the ordinary case, handled by re-reading the rows below.
        if trimmed < lastTrimmed || top < lastTop || screenErasedAt != nil {
            // Rows are read again from where the wipe left the cursor, not from where the
            // cursor has since got to: a `clear; ls` prints its output into the cleared screen
            // before this ever runs, and that output is the first thing the transcript wants.
            let restart = min(screenErasedAt ?? absCursor, absCursor)
            rowToLine.removeAll()
            for index in lineRows.indices { lineRows[index] = TerminalSession.noRows }
            pendingAnchors.removeAll()
            extentRow = restart
            mappedFrom = restart
            frameStart = restart
        }
        screenErasedAt = nil
        lastTrimmed = trimmed
        lastTop = top

        // Rows recycled out of a full scrollback are gone and can no longer be read.
        if mappedFrom < trimmed {
            rowToLine = rowToLine.filter { $0.key >= trimmed }
            mappedFrom = trimmed
        }
        if extentRow < trimmed { extentRow = trimmed }

        // Everything from the lowest row the parser touched since the last update through the
        // cursor is fair game: rows past the extent become new lines, rows below it rewrite
        // the lines they already produced.
        var readFrom = extentRow
        if let changed = terminal.getScrollInvariantUpdateRange() {
            readFrom = min(readFrom, changed.startY + trimmed)
        }
        terminal.clearUpdateRange()
        readFrom = max(readFrom, mappedFrom)
        // Rows above the screen cannot be redrawn -- the program cannot address them -- so
        // they are never worth re-reading, which also keeps a batch's work to a screenful.
        // Rows that scrolled past unread in a burst still have to be read, hence the extent.
        readFrom = max(readFrom, min(extentRow, screenTop))
        // Never start in the middle of a line: a wrapped group is read as a whole or not at all.
        if let line = rowToLine[readFrom], lineRows.indices.contains(line) {
            readFrom = min(readFrom, lineRows[line].lowerBound)
        }

        // Never split a wrapped logical line: back up to the start of the group the cursor sits in.
        var readEnd = absCursor
        while readEnd > readFrom, isWrapped(readEnd) {
            readEnd -= 1
        }

        var newLines: [String] = []
        var edits: [Transcript.Edit] = []
        var touched: Set<Int> = []
        let firstNewLine = transcript.count

        var row = readFrom
        while row < readEnd {
            var text = rowText(row)
            var end = row + 1
            while end < readEnd, isWrapped(end) {
                text += rowText(end)
                end += 1
            }
            let group = row..<end

            let line: Int
            if let existing = rowToLine[row], lineRows.indices.contains(existing) {
                line = existing
                if let edit = transcript.revise(existing, to: text) { edits.append(edit) }
            } else {
                line = transcript.append(text)
                lineRows.append(group)
                newLines.append(text)
            }
            if lineRows[line] != group {
                lineRows[line] = group
            }
            for r in group { rowToLine[r] = line }
            resolveAnchors(row: row, line: line)
            touched.insert(line)
            row = end
        }
        if readEnd > readFrom { frameStart = readFrom }
        if readEnd > extentRow { extentRow = readEnd }
        readCommands(touching: touched)
        // Anchors on rows that went past unread -- recycled out of a full scrollback -- are
        // never coming back.
        pendingAnchors = pendingAnchors.filter { $0.key >= trimmed }

        // Live region: from the start of the cursor's line group to the bottom of the screen.
        var live: [String] = []
        let screenEnd = screenTop + terminal.rows
        if readEnd < screenEnd {
            for row in readEnd..<screenEnd {
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
        var liveText = live.joined(separator: "\n")
        if liveText.isEmpty {
            // The cursor is parked on an empty row under the frame that was just painted --
            // where Claude Code leaves it between frames. "Nothing" is the wrong answer to
            // "what is on screen now": the last line of that frame is.
            var above = readEnd - 1
            let floor = max(frameStart, mappedFrom, readEnd - terminal.rows)
            while above >= floor {
                let text = rowText(above)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    liveText = text
                    break
                }
                above -= 1
            }
        }

        let finished = justFinished.compactMap { index -> CommandBlock? in
            index < rawBlocks.count ? published(rawBlocks[index]) : nil
        }
        justFinished.removeAll()

        delegate?.session(self, didUpdate: TerminalUpdate(newLines: newLines,
                                                          firstNewLine: firstNewLine,
                                                          edits: edits,
                                                          liveText: liveText,
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
