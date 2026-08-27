import AppKit

/// Three parts, top to bottom:
///  1. Transcript: a read-only NSTextView. VoiceOver drives it with the caret, so up/down read
///     by line, Option-left/right by word and plain left/right by character, Shift-arrows
///     extend the selection, and Command-A, Command-C and Command-F work as in any text view.
///     The session builds the lines; this mirrors them, adding new ones at the end and
///     rewriting in place the ones whose rows a program has redrawn, without moving the caret
///     off the text it was on.
///  2. Current line: a label with whatever is not part of a line yet (usually the prompt).
///  3. Command line: a native text field. Enter sends the line to the shell.
final class MainViewController: NSViewController,
                                NSTextFieldDelegate, TerminalSessionDelegate,
                                NSMenuItemValidation {

    let session = TerminalSession()
    let announcer = Announcer()

    private let textView = MainViewController.makeTranscriptTextView()
    private let scrollView = NSScrollView()
    private let liveLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField()

    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// The lines themselves live in the session, which builds them; the text view mirrors it.
    private var transcript: Transcript { session.transcript }
    /// Non-nil while a full-screen program owns the alternate screen; the text view shows this instead.
    private var screenLines: [String]?

    /// What has been spoken for each transcript line, so a redraw of the same words is silent.
    private var news = LineNews()
    /// Where the echo of the most recently submitted command starts. Command-1 lands here.
    private var lastCommandOffset: Int?
    /// The command just sent, until its echo has been seen and left unannounced. Only used
    /// when the shell is not marking its commands: see dropEcho.
    private var pendingEcho: String?

    private var liveText = ""
    /// The last live line spoken as a program's question, so it is not said again when it
    /// later gains its newline and arrives as a transcript line.
    private var announcedLiveText = ""

    private var history: [String] = []
    private var historyIndex = 0
    private var keyMonitor: Any?

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

        commandField.font = monoFont
        commandField.placeholderString = "Type a command and press Return"
        commandField.setAccessibilityLabel("Command line")
        commandField.delegate = self
        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandField.setContentHuggingPriority(.required, for: .vertical)

        root.addSubview(scrollView)
        root.addSubview(liveLabel)
        root.addSubview(commandField)

        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            liveLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: pad),
            liveLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            liveLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),

            commandField.topAnchor.constraint(equalTo: liveLabel.bottomAnchor, constant: pad),
            commandField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            commandField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            commandField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
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
        view.window?.initialFirstResponder = commandField
        view.window?.makeFirstResponder(commandField)
        installKeyMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Control keys while typing in the command field

    private var isEditingCommandField: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView,
              let editorDelegate = editor.delegate else { return false }
        return (editorDelegate as AnyObject) === commandField
    }

    /// Control-C/D/Z/L and Escape go straight to the program instead of the text field.
    /// Other Control combinations keep their normal text-editing meaning (Control-A, Control-E, ...).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window, self.isEditingCommandField else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags.isEmpty, event.keyCode == 53 { // Escape
                self.session.send(bytes: [0x1b])
                return nil
            }
            if flags == [.control],
               let ch = event.charactersIgnoringModifiers?.lowercased().first,
               let ascii = ch.asciiValue, ch.isLetter,
               "cdzl".contains(ch) {
                self.session.send(bytes: [ascii - 96])
                return nil
            }
            return event
        }
    }

    // MARK: - Command field

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Smart quotes and dashes would corrupt commands.
        if let editor = commandField.currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submitCommand()
            return true
        case #selector(NSResponder.moveUp(_:)):
            stepHistory(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            stepHistory(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            // Shift-Tab: Claude Code cycles permission modes with it.
            session.send(bytes: [0x1b, 0x5b, 0x5a])
            return true
        default:
            return false
        }
    }

    private func submitCommand() {
        let text = commandField.stringValue
        // The shell echoes the command, so the transcript's current end is where that echo
        // will land: the top of everything this command is about to produce.
        lastCommandOffset = transcript.length
        let typed = text.trimmingCharacters(in: .whitespaces)
        pendingEcho = typed.isEmpty ? nil : typed
        session.send(text: text + "\r")
        if !text.isEmpty {
            if history.last != text { history.append(text) }
        }
        historyIndex = history.count
        commandField.stringValue = ""
    }

    private func stepHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        historyIndex = max(0, min(history.count, historyIndex + delta))
        commandField.stringValue = historyIndex == history.count ? "" : history[historyIndex]
        let length = (commandField.stringValue as NSString).length
        commandField.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
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

    /// Move the caret, then take focus, then tell VoiceOver the selection moved, then say
    /// the landing line.
    ///
    /// The announcement is what the user actually hears the landing line from. See "Known
    /// issues" in the README: VoiceOver reads the first line of the transcript as focus
    /// arrives, whatever the caret is doing, and nothing tried so far has stopped it.
    private func landCaret(at offset: Int, announcing: String? = nil) {
        moveCaret(to: offset)
        view.window?.makeFirstResponder(textView)
        NSAccessibility.post(element: textView, notification: .selectedTextChanged)

        let spoken = announcing ?? textView.caretLineText
        guard !spoken.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.announcer.announceNow(spoken, priority: .high)
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
        if !alreadySpoken.isEmpty {
            lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == alreadySpoken }
        }
        dropEcho(from: &lines)
        // The hint about what Return alone does goes on here, after the checks above have
        // matched a committed line against text it repeats: both are still verbatim.
        announcer.enqueue((lines + extra).map(PromptDefault.spoken))
    }

    /// Drops the echo of the command just sent, for a shell that does not mark its commands.
    /// Where the markers are there, the session says which lines the echo landed on and
    /// LineNews has already left them out; with no B and C to bracket it, all that identifies
    /// the echo is that it is the text that was just sent. It comes back exactly once, right
    /// after the command goes, so it is matched once and forgotten: a line that repeats the
    /// command later is something a program printed, and is news.
    private func dropEcho(from lines: inout [String]) {
        guard !session.hasCommandMarkers, let echo = pendingEcho,
              let index = lines.firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == echo
              }) else { return }
        lines.remove(at: index)
        pendingEcho = nil
    }

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
        commandField.isEnabled = false
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
        view.window?.makeFirstResponder(commandField)
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
