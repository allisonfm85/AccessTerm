import AppKit

/// Three parts, top to bottom:
///  1. Transcript: a read-only NSTextView. VoiceOver drives it with the caret, so up/down read
///     by line, Option-left/right by word and plain left/right by character, Shift-arrows
///     extend the selection, and Command-A, Command-C and Command-F work as in any text view.
///     The session builds the lines; this mirrors them, adding new ones at the end and
///     rewriting in place the ones whose rows a program has redrawn, without moving the caret
///     off the text it was on.
///  2. Current line: a label with whatever is not part of a line yet (usually the prompt).
///  3. Command line: a view that draws what is being typed and is read out by nothing but
///     this app. Return sends the line to the shell. It is not a text control on purpose --
///     see InputLineView.
final class MainViewController: NSViewController,
                                InputLineViewDelegate, TerminalSessionDelegate,
                                NSMenuItemValidation {

    let session = TerminalSession()
    let announcer = Announcer()

    private let textView = MainViewController.makeTranscriptTextView()
    private let scrollView = NSScrollView()
    private let liveLabel = NSTextField(wrappingLabelWithString: "")
    private let inputLine = InputLineView()

    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// The lines themselves live in the session, which builds them; the text view mirrors it.
    private var transcript: Transcript { session.transcript }
    /// Non-nil while a full-screen program owns the alternate screen; the text view shows this instead.
    private var screenLines: [String]?

    /// What has been spoken for each transcript line, so a redraw of the same words is silent.
    private var news = LineNews()
    /// Where the echo of the most recently submitted command starts. Command-1 lands here.
    private var lastCommandOffset: Int?
    /// The command just sent, until its echo has been seen and left unannounced. See dropEcho.
    private var pendingEcho: String?
    /// Diagnostic only: ACCESSTERM_ECHO_DEBUG puts one line on stderr per committed line,
    /// saying how it was classified and whether it was announced. See logEchoDecisions.
    private let echoDebug = ProcessInfo.processInfo.environment["ACCESSTERM_ECHO_DEBUG"] != nil

    private var liveText = ""
    /// The last live line spoken as a program's question, so it is not said again when it
    /// later gains its newline and arrives as a transcript line.
    private var announcedLiveText = ""

    // MARK: - View construction

    /// Builds the TextKit 1 stack by hand. A plain `NSTextView(frame:)` gets TextKit 2 on
    /// macOS 13, and only TextKit 1 offers non-contiguous layout, which is what keeps a
    /// 100,000-line transcript from laying itself out in full on every append.
    private static func makeTranscriptTextView() -> TranscriptTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let view = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 960, height: 480),
                                      textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        // Its own delegate, for the self-voiced navigation fallback.
        view.delegate = view
        return view
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))

        textView.font = monoFont
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Transcript")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        liveLabel.font = monoFont
        liveLabel.maximumNumberOfLines = 4
        liveLabel.lineBreakMode = .byWordWrapping
        liveLabel.isSelectable = true
        liveLabel.setAccessibilityLabel("Current line")
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveLabel.setContentHuggingPriority(.required, for: .vertical)
        liveLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        inputLine.font = monoFont
        inputLine.placeholder = "Type a command and press Return"
        inputLine.delegate = self
        inputLine.translatesAutoresizingMaskIntoConstraints = false
        inputLine.setContentHuggingPriority(.required, for: .vertical)

        root.addSubview(scrollView)
        root.addSubview(liveLabel)
        root.addSubview(inputLine)

        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            liveLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: pad),
            liveLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            liveLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            inputLine.topAnchor.constraint(equalTo: liveLabel.bottomAnchor, constant: pad),
            inputLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            inputLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            inputLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.delegate = self
        appendExternal(["AccessTerm ready. Shell: /bin/zsh. Command-1 transcript, Command-2 command line."])
        session.start()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.initialFirstResponder = inputLine
        view.window?.makeFirstResponder(inputLine)
    }

    // MARK: - Input line

    /// Return. The line goes to the shell as one write, and nothing says it back: the input
    /// line emptied itself before this was called, and the echo the shell prints is
    /// classified and left unannounced like any other.
    func inputLine(_ view: InputLineView, didSubmit text: String) {
        submit(text)
    }

    /// A key the shell answers for itself: history, completion, a control character. Whatever
    /// had been typed here goes first, without a Return, so that it becomes part of the line
    /// the shell is holding -- otherwise completion would complete nothing and history would
    /// throw the typing away.
    func inputLine(_ view: InputLineView, didSendToShell bytes: [UInt8], pending text: String) {
        if !text.isEmpty {
            lastCommandOffset = transcript.length
            session.send(bytes: Array(text.utf8))
        }
        session.send(bytes: bytes)
    }

    /// The input line's own voice: the character or word the caret crossed, what a deletion
    /// removed. It is not a text control, so the system narrates nothing about it, and this is
    /// the only thing that does. Typing is not among the things it says -- whether keystrokes
    /// are spoken is VoiceOver's key echo setting, and this app does not answer that for
    /// anyone.
    func inputLine(_ view: InputLineView, announce text: String) {
        announcer.announceNow(text, priority: .high)
    }

    private func submit(_ text: String) {
        // The shell echoes the command, so the transcript's current end is where that echo
        // will land: the top of everything this command is about to produce.
        lastCommandOffset = transcript.length
        let typed = text.trimmingCharacters(in: .whitespaces)
        pendingEcho = typed.isEmpty ? nil : typed
        session.send(text: text + "\r")
    }

    // MARK: - Transcript text

    private var textLength: Int { textView.textStorage?.length ?? 0 }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: monoFont, .foregroundColor: NSColor.textColor]
    }

    /// Replaces the whole contents. Only used when switching between the transcript and a
    /// full-screen program's screen, where the caret has nowhere meaningful to stay.
    private func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        textView.withoutSelfVoicing {
            storage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        }
    }

    /// Offset of the start of the last line that has any content. The transcript ends with a
    /// newline, so the very end of the text is an empty line past it, and a caret parked there
    /// leaves VoiceOver nothing to read.
    private var lastLineStart: Int {
        guard let text = textView.textStorage?.mutableString, text.length > 0 else { return 0 }
        var location = text.length
        while location > 0 {
            let line = text.paragraphRange(for: NSRange(location: location - 1, length: 0))
            let content = text.substring(with: line)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line.location
            }
            location = line.location
        }
        return 0
    }

    /// Anywhere on the last line counts as being at the end: that is where Command-Shift-E
    /// lands, and someone who has arrowed back down to the bottom is following output again.
    private var isCaretAtEnd: Bool {
        let selection = textView.selectedRange()
        return selection.location + selection.length >= lastLineStart
    }

    /// Whether new output should scroll the view. The caret only means "where I am reading"
    /// while the transcript has focus; the rest of the time it sits wherever it was last put
    /// (0 at launch), so keying the scroll purely off it would stop the view following the
    /// output after the very first line.
    private var shouldFollowOutput: Bool {
        view.window?.firstResponder !== textView || isCaretAtEnd
    }

    private func moveCaret(to offset: Int) {
        let range = NSRange(location: max(0, min(offset, textLength)), length: 0)
        textView.withoutSelfVoicing {
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    /// Move the caret, take focus, and say what was landed on -- once.
    ///
    /// The announcement is the only voice here, and that takes keeping another one out.
    /// Telling VoiceOver the selection moved asks it to read the landing line itself, and the
    /// announcement a moment later then talks over it: what the user hears is the first
    /// syllable of the line, cut off, and then the announcement -- two voices racing over one
    /// landing. So the notification is not posted when there is something to announce, and
    /// the view is kept quiet until the announcement goes out, which leaves any read AppKit
    /// posts for the selection change with nothing to read from either.
    ///
    /// A landing with nothing to announce is the other way round: there the caret move is
    /// VoiceOver's to describe, so it is told about it and the view is never quieted.
    ///
    /// What this does not touch is the read that comes with focus arriving. See "Known
    /// issues" in the README: VoiceOver reads the first line of the transcript as focus
    /// lands, whatever the caret is doing, and nothing tried so far has stopped it -- the
    /// announcement is what is heard over that.
    private func landCaret(at offset: Int, announcing: String? = nil) {
        let quiet = textView.beQuiet()
        moveCaret(to: offset)
        view.window?.makeFirstResponder(textView)

        let spoken = announcing ?? textView.caretLineText
        guard !spoken.isEmpty else {
            textView.endQuiet(quiet)
            NSAccessibility.post(element: textView, notification: .selectedTextChanged)
            return
        }
        // Long enough for the selection change to have been and gone before the view has
        // anything to say again, and for the announcement to land after focus has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.textView.endQuiet(quiet)
            self.announcer.announceNow(spoken, priority: .high)
        }
    }

    // MARK: - Command blocks

    /// Transcript line the caret is on.
    private var caretLine: Int {
        let offset = textView.selectedRange().location
        let offsets = transcript.offsets
        guard !offsets.isEmpty else { return 0 }
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func offset(ofLine line: Int) -> Int {
        transcript.offset(ofLine: line)
    }

    /// Blocks worth navigating to: ones with a command in them. A block the shell opened for
    /// the prompt currently waiting for input is not somewhere to land.
    private var commandBlocks: [CommandBlock] {
        session.commandBlocks.filter { !$0.command.isEmpty }
    }

    /// Index of the block the caret is in, or the last one starting before it.
    private func blockIndex(containing line: Int, in blocks: [CommandBlock]) -> Int? {
        blocks.lastIndex { $0.allLines.lowerBound <= line }
    }

    /// The block the caret is in and, when that block is a program running a conversation of
    /// its own, the turn within it. Nil for a turn means the caret is in the block but above
    /// its first turn, which is where the program's own startup output is.
    private func location(of line: Int, in blocks: [CommandBlock]) -> (block: Int, turn: Int?)? {
        guard let block = blockIndex(containing: line, in: blocks) else { return nil }
        return (block, blocks[block].turns.lastIndex { $0.allLines.lowerBound <= line })
    }

    private func land(on block: CommandBlock) {
        landCaret(at: offset(ofLine: block.commandLine), announcing: announcement(for: block))
    }

    /// "ls -la" on its own, or "ls -la, exit code 1" when it failed.
    private func announcement(for block: CommandBlock) -> String {
        block.failed ? "\(block.command), exit code \(block.exitCode ?? 0)" : block.command
    }

    @objc func previousCommand(_ sender: Any?) { stepCommand(-1) }
    @objc func nextCommand(_ sender: Any?) { stepCommand(1) }

    private func stepCommand(_ delta: Int) {
        guard screenLines == nil else {
            announcer.announceNow("Not available while a full-screen program is running")
            return
        }
        let blocks = commandBlocks
        guard !blocks.isEmpty else {
            announcer.announceNow("No commands to move between")
            return
        }
        let line = caretLine

        // Inside a command that is running a conversation of its own -- a Claude Code session
        // -- stepping moves between its turns, and only leaves the block at either end.
        if let here = location(of: line, in: blocks), !blocks[here.block].turns.isEmpty {
            let turns = blocks[here.block].turns
            if delta > 0 {
                let next = here.turn.map { $0 + 1 } ?? 0
                if turns.indices.contains(next) {
                    land(on: turns[next])
                    return
                }
            } else if let turn = here.turn {
                // From inside a turn's answer, up goes to the question it answers first.
                if line > turns[turn].commandLine {
                    land(on: turns[turn])
                } else if turn > 0 {
                    land(on: turns[turn - 1])
                } else {
                    // At the first turn, one more step up is the command they are all inside.
                    land(on: blocks[here.block])
                }
                return
            }
        }

        let current = blockIndex(containing: line, in: blocks)

        var target = (current ?? (delta < 0 ? blocks.count : -1)) + delta
        // Going back from inside a block's output means the top of that block, not the one
        // before it: the same as scrolling back to the command you are reading the output of.
        if delta < 0, let current, line > blocks[current].commandLine { target = current }

        guard blocks.indices.contains(target) else {
            announcer.announceNow(delta < 0 ? "No previous command" : "No next command")
            return
        }
        land(on: blocks[target])
    }

    @objc func copyBlockOutput(_ sender: Any?) {
        guard screenLines == nil else {
            announcer.announceNow("Not available while a full-screen program is running")
            return
        }
        let blocks = session.commandBlocks
        guard let index = blockIndex(containing: caretLine, in: blocks) ?? blocks.indices.last else {
            announcer.announceNow("No output to copy")
            return
        }
        let block = blocks[index]
        // Inside a turn, "the output" is the answer to that question, not everything the
        // program has printed since it started.
        let source = block.turns.last { $0.allLines.lowerBound <= caretLine } ?? block
        let output = source.outputLines.clamped(to: transcript.lines.indices)
        guard !output.isEmpty else {
            announcer.announceNow("No output to copy")
            return
        }
        let text = output.map { transcript.lines[$0] }.joined(separator: "\n") + "\n"
        copyToPasteboard(text, announce: "Copied output, \(output.count) "
                         + (output.count == 1 ? "line" : "lines"))
    }

    /// Lines the app writes itself -- the ready message, the exit message. They go through
    /// the session so that they take transcript numbers like any other line: blocks are
    /// numbered in transcript lines, and anything uncounted puts every later block a line out.
    private func appendExternal(_ newLines: [String]) {
        session.appendExternal(newLines)
        mirrorAppended(newLines)
    }

    /// Adds lines the session has already put in the transcript to the text view.
    private func mirrorAppended(_ newLines: [String]) {
        guard !newLines.isEmpty, screenLines == nil, let storage = textView.textStorage else { return }
        let chunk = newLines.map { $0 + "\n" }.joined()
        // If the user has moved the caret back to read something, new output must not drag
        // the view away from them.
        let follow = shouldFollowOutput
        let selection = textView.selectedRanges
        textView.withoutSelfVoicing {
            storage.append(NSAttributedString(string: chunk, attributes: textAttributes))
            // Appending past the caret should leave it alone, but restore it explicitly rather
            // than relying on that: the caret is the reading position.
            textView.setSelectedRanges(selection,
                                       affinity: textView.selectionAffinity,
                                       stillSelecting: false)
        }
        if follow {
            textView.scrollRangeToVisible(NSRange(location: textLength, length: 0))
        }
    }

    /// Rewrites lines whose rows the program has redrawn. The edits are applied in the order
    /// the session made them, because each one's range is the range to replace once the
    /// edits before it are in.
    private func mirrorEdits(_ edits: [Transcript.Edit]) {
        guard !edits.isEmpty, screenLines == nil, let storage = textView.textStorage else { return }
        let follow = shouldFollowOutput
        var selection = textView.selectedRange()
        textView.withoutSelfVoicing {
            for edit in edits {
                guard NSMaxRange(edit.range) <= storage.length else { continue }
                storage.replaceCharacters(in: edit.range,
                                          with: NSAttributedString(string: edit.text,
                                                                   attributes: textAttributes))
                let delta = (edit.text as NSString).length - edit.range.length
                selection = adjusting(selection, forEditIn: edit.range, delta: delta)
                if let offset = lastCommandOffset, offset >= NSMaxRange(edit.range) {
                    lastCommandOffset = offset + delta
                }
            }
            textView.setSelectedRanges([NSValue(range: selection)],
                                       affinity: textView.selectionAffinity,
                                       stillSelecting: false)
        }
        if follow {
            textView.scrollRangeToVisible(NSRange(location: textLength, length: 0))
        }
    }

    /// Keeps the caret on the text it was on when a line elsewhere is rewritten. A caret
    /// inside the line being rewritten has nowhere to stay, so it holds the line.
    private func adjusting(_ selection: NSRange, forEditIn range: NSRange, delta: Int) -> NSRange {
        var result = selection
        let editEnd = NSMaxRange(range)
        if result.location >= editEnd {
            result.location += delta
        } else if result.location > range.location {
            result.location = min(result.location, editEnd + delta)
            result.length = 0
        } else if NSMaxRange(result) > editEnd {
            result.length += delta
        }
        return result
    }

    /// Speaks what is new in a batch, plus anything the app has to add itself.
    private func announce(_ update: TerminalUpdate, extra: [String], alreadySpoken: String) {
        var lines = news.news(in: update)
        let afterNews = lines
        if !alreadySpoken.isEmpty {
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == alreadySpoken }
        }
        let afterAlreadySpoken = lines
        let comparedAgainst = pendingEcho
        dropEcho(from: &lines, in: update)
        if echoDebug {
            logEchoDecisions(update, afterNews: afterNews, afterAlreadySpoken: afterAlreadySpoken,
                             afterDropEcho: lines, comparedAgainst: comparedAgainst, extra: extra)
        }
        // The hint about what Return alone does goes on here, after the checks above have
        // matched a committed line against text it repeats: both are still verbatim.
        announcer.enqueue((lines + extra).map(PromptDefault.spoken))
    }

    /// Diagnostic only: says, for every line this batch committed, how it was classified and
    /// whether it ended up being announced. It reads the decisions the code above already
    /// made -- the three arrays are that code's own output at each step -- and makes none of
    /// its own, so turning it on cannot change what is spoken.
    private func logEchoDecisions(_ update: TerminalUpdate,
                                  afterNews: [String],
                                  afterAlreadySpoken: [String],
                                  afterDropEcho: [String],
                                  comparedAgainst: String?,
                                  extra: [String]) {
        // The lines this batch touched, in the order LineNews considers them.
        var byLine: [Int: String] = [:]
        for edit in update.edits { byLine[edit.line] = edit.text }
        for (index, text) in update.newLines.enumerated() {
            byLine[update.firstNewLine + index] = text
        }
        // Walked in the same order, so each stage's survivors can be consumed off the front.
        var news = afterNews[...]
        var kept = afterAlreadySpoken[...]
        var spoken = afterDropEcho[...]

        var out = ""
        for line in byLine.keys.sorted() {
            guard let text = byLine[line] else { continue }
            let span = session.echoSpan(forLine: line)
            var announce = false
            var reason: String
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                reason = "blank"
            } else if update.userEchoLines.contains(line) {
                reason = "inside the marked B..C echo span"
            } else if news.first != text {
                reason = "same text last announced for this line"
            } else {
                news = news.dropFirst()
                if kept.first != text {
                    reason = "already spoken as the live question"
                } else {
                    kept = kept.dropFirst()
                    if spoken.first != text {
                        reason = "matched the command just sent"
                    } else {
                        spoken = spoken.dropFirst()
                        announce = true
                        reason = "news"
                    }
                }
            }
            let spanText = span.map {
                "\($0.start)..<\($0.end) command=\"\($0.command)\" C\($0.cResolved ? "" : " un")resolved"
            } ?? "none"
            out += "line \(line) text=\"\(text)\"\n"
                + "  markers=\(session.hasCommandMarkers) span=\(spanText) "
                + "inSpan=\(span != nil) userEcho=\(update.userEchoLines.contains(line)) "
                + "submitted=\(comparedAgainst.map { "\"\($0)\"" } ?? "none")\n"
                + "  announce=\(announce) reason=\(reason)\n"
        }
        if !extra.isEmpty {
            out += "  not a committed line, announced alongside them: \(extra)\n"
        }
        if !out.isEmpty {
            FileHandle.standardError.write(Data(out.utf8))
        }
    }

    /// Drops the echo of the command just sent, wherever the markers did not already catch it.
    ///
    /// B and C bracket what is typed at the shell's own prompt, and nothing else: a program
    /// that runs a prompt of its own -- a REPL, `cat`, a session inside the terminal -- gets
    /// no markers, and neither does a shell too old to send them. What is typed there is
    /// echoed back and becomes a committed line like any other, and the only thing that
    /// identifies it is that it is the text that was just sent.
    ///
    /// It comes back exactly once, right after the command goes, so it is matched once and
    /// forgotten: a line that repeats the command later is something a program printed, and
    /// is news.
    private func dropEcho(from lines: inout [String], in update: TerminalUpdate) {
        guard let echo = pendingEcho else { return }
        // The markers found it, so there is nothing left to match. Disarming here matters:
        // a fallback left armed for the rest of the command would go off on some later line
        // of output that happens to say the same thing.
        guard update.userEchoLines.isEmpty else {
            pendingEcho = nil
            return
        }
        guard let index = lines.firstIndex(where: { isEcho($0, of: echo) }) else { return }
        lines.remove(at: index)
        pendingEcho = nil
    }

    /// Whether a committed line is `command` coming back: the command on its own, or a prompt
    /// with the command typed on the end of it. The prompt has to end the way prompts do -- a
    /// "%", "$", ">" and so on, then a space -- so that a line of output merely ending in the
    /// same word is not mistaken for it.
    private func isEcho(_ line: String, of command: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text == command { return true }
        guard text.hasSuffix(command) else { return false }
        let prompt = text.dropLast(command.count)
        guard prompt.hasSuffix(" "), let end = prompt.dropLast().last else { return false }
        return MainViewController.promptEndings.contains(end)
    }

    /// What the last character of a prompt is, before the space the command is typed after.
    private static let promptEndings: Set<Character> = ["%", "$", "#", ">", ":", "\u{276f}"]

    /// A program's question, when this batch brought a new one.
    ///
    /// A prompt that waits for an answer does not end in a newline, so it never becomes a
    /// transcript line and nothing else here would ever say it: gh asking "Path to local
    /// repository (default: .)" straight after a numbered menu sounds, otherwise, exactly like
    /// the menu having hung. Only while a command is running is a live line a program's; at the
    /// shell prompt it is the prompt itself, which the command that just finished already
    /// accounts for.
    private func liveQuestion(in update: TerminalUpdate) -> [String] {
        guard update.programIsRunning else {
            announcedLiveText = ""
            return []
        }
        // A command that has printed nothing yet leaves the line it was typed on as the
        // nearest thing on screen. It is shown, but it is the user's own typing coming back.
        guard !update.liveTextIsUserEcho else { return [] }
        let question = update.liveText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, question != announcedLiveText else { return [] }
        announcedLiveText = question
        return [question]
    }

    // MARK: - TerminalSessionDelegate

    func session(_ session: TerminalSession, didUpdate update: TerminalUpdate) {
        if let screen = update.alternateScreen {
            let previous = screenLines
            screenLines = screen
            setText(screen.map { $0 + "\n" }.joined())
            if previous == nil {
                liveLabel.stringValue = "Full-screen program running. The transcript shows its screen."
                announcer.announceNow("Full-screen program started")
            } else if let previous {
                // Cheap screen-diff: speak rows that changed.
                var changed: [String] = []
                for i in 0..<screen.count where i >= previous.count || previous[i] != screen[i] {
                    changed.append(screen[i])
                    if changed.count >= 10 { break }
                }
                announcer.enqueue(changed)
            }
            return
        }

        if screenLines != nil {
            screenLines = nil
            setText(transcript.text())
            moveCaret(to: textLength)
            announcer.announceNow("Returned to transcript")
        }

        mirrorEdits(update.edits)
        mirrorAppended(update.newLines)
        // A command that failed says so on the end of whatever it printed.
        let failures = update.finishedCommands
            .filter { $0.failed }
            .map { "exit code \($0.exitCode ?? 0)" }
        // What was spoken before this batch: liveQuestion is about to move it on, and a line
        // arriving now is only a repeat of the question as it stood a moment ago.
        let alreadySpoken = announcedLiveText
        announce(update, extra: failures + liveQuestion(in: update), alreadySpoken: alreadySpoken)

        if update.liveText != liveText {
            liveText = update.liveText
            liveLabel.stringValue = liveText
        }
    }

    func sessionDidRingBell(_ session: TerminalSession) {
        NSSound.beep()
        let detail = liveText.isEmpty ? "" : " " + liveText
        announcer.announceNow("Attention." + detail, priority: .high)
    }

    func session(_ session: TerminalSession, didChangeTitle title: String) {
        view.window?.title = title.isEmpty ? "AccessTerm" : "\(title) — AccessTerm"
    }

    func session(_ session: TerminalSession, didTerminateWithExitCode code: Int32?) {
        let message = "[Shell exited" + (code.map { " with code \($0)" } ?? "") + "]"
        appendExternal([message])
        liveLabel.stringValue = message
        inputLine.isEnabled = false
        announcer.announceNow(message)
    }

    // MARK: - Menu actions

    @objc func focusTranscript(_ sender: Any?) {
        // The most recent command's own line, from the block model. Without markers there is
        // no model, so fall back to the offset noted when the command was sent, and to the
        // last line with content before anything has been run -- not textLength, which is the
        // empty line past the final newline and has nothing to read.
        if screenLines == nil, session.hasCommandMarkers, let block = commandBlocks.last {
            // Said the same way stepping between commands says it, so landing on a command
            // sounds the same however you got there. Inside a program running a conversation,
            // the most recent thing asked is the most recent thing done.
            land(on: block.turns.last ?? block)
            return
        }
        landCaret(at: lastCommandOffset ?? lastLineStart)
    }

    @objc func focusCommandLine(_ sender: Any?) {
        view.window?.makeFirstResponder(inputLine)
    }

    @objc func goToEnd(_ sender: Any?) {
        // The start of the last line with content, not the empty line past the final newline:
        // the caret has to be on a line for VoiceOver to have anything to read.
        landCaret(at: lastLineStart)
    }

    @objc func readCurrentLine(_ sender: Any?) {
        announcer.announceNow(liveText.isEmpty ? "Current line is empty" : liveText)
    }

    @objc func toggleSpeakOutput(_ sender: Any?) {
        announcer.enabled.toggle()
        announcer.announceNow(announcer.enabled ? "Speak output on" : "Speak output off")
    }

    @objc func interrupt(_ sender: Any?) {
        session.send(bytes: [0x03])
    }

    @objc func sendEscape(_ sender: Any?) {
        session.send(bytes: [0x1b])
    }

    @objc func sendShiftTab(_ sender: Any?) {
        session.send(bytes: [0x1b, 0x5b, 0x5a])
    }

    @objc func copyAll(_ sender: Any?) {
        copyToPasteboard(transcript.lines.joined(separator: "\n"),
                         announce: "Copied entire transcript")
    }

    private func copyToPasteboard(_ text: String, announce: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        announcer.announceNow(announce)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSpeakOutput(_:)) {
            menuItem.state = announcer.enabled ? .on : .off
        }
        return true
    }
}
