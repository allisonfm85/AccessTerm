import AppKit

/// Three parts, top to bottom:
///  1. Transcript: a read-only NSTextView. VoiceOver drives it with the caret, so up/down read
///     by line, Option-left/right by word and plain left/right by character, Shift-arrows
///     extend the selection, and Command-A, Command-C and Command-F work as in any text view.
///     Text is only ever appended, so the reading position never moves under you.
///  2. Current line: a label with whatever is not yet committed (usually the prompt).
///  3. Command line: a native text field. Enter sends the line to the shell.
final class MainViewController: NSViewController,
                                NSTextFieldDelegate, TerminalSessionDelegate,
                                NSMenuItemValidation {

    let session = TerminalSession()
    private let announcer = Announcer()

    private let textView = MainViewController.makeTranscriptTextView()
    private let scrollView = NSScrollView()
    private let liveLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField()

    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Committed transcript lines. This stays the source of truth; the text view mirrors it.
    private var lines: [String] = []
    /// Non-nil while a full-screen program owns the alternate screen; the text view shows this instead.
    private var screenLines: [String]?

    /// Character length of the transcript text. Tracked as lines are appended so it stays
    /// correct even while the alternate screen is temporarily showing something else.
    private var transcriptLength = 0
    /// Where the echo of the most recently submitted command starts. Command-1 lands here.
    private var lastCommandOffset: Int?

    private var liveText = ""

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
        appendLines(["AccessTerm ready. Shell: /bin/zsh. Command-1 transcript, Command-2 command line."])
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
        lastCommandOffset = transcriptLength
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

    private func transcriptText() -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// Replaces the whole contents. Only used when switching between the transcript and a
    /// full-screen program's screen, where the caret has nowhere meaningful to stay.
    private func setText(_ text: String) {
        guard let storage = textView.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
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
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    /// Move the caret, then take focus, then tell VoiceOver the selection moved. Taking focus
    /// first makes VoiceOver read whichever line the caret was last left on -- the first line
    /// of the transcript, at launch -- because the caret has not moved yet when focus lands.
    private func landCaret(at offset: Int) {
        moveCaret(to: offset)
        view.window?.makeFirstResponder(textView)
        NSAccessibility.post(element: textView, notification: .selectedTextChanged)

        // Belt and braces. If VoiceOver still starts reading more than the landing line, a
        // high-priority announcement a moment later interrupts it with the line itself.
        let line = textView.caretLineText
        guard !line.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.announcer.announceNow(line, priority: .high)
        }
    }

    private func appendLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        let chunk = newLines.map { $0 + "\n" }.joined()
        transcriptLength += (chunk as NSString).length
        guard screenLines == nil, let storage = textView.textStorage else { return }

        // If the user has moved the caret back to read something, new output must not drag
        // the view away from them.
        let follow = shouldFollowOutput
        let selection = textView.selectedRanges
        storage.append(NSAttributedString(string: chunk, attributes: textAttributes))
        // Appending past the caret should leave it alone, but restore it explicitly rather
        // than relying on that: the caret is the reading position.
        textView.setSelectedRanges(selection,
                                   affinity: textView.selectionAffinity,
                                   stillSelecting: false)
        if follow {
            textView.scrollRangeToVisible(NSRange(location: textLength, length: 0))
        }
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
            setText(transcriptText())
            moveCaret(to: textLength)
            announcer.announceNow("Returned to transcript")
        }

        appendLines(update.newLines)
        announcer.enqueue(update.newLines)

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
        appendLines([message])
        liveLabel.stringValue = message
        commandField.isEnabled = false
        announcer.announceNow(message)
    }

    // MARK: - Menu actions

    @objc func focusTranscript(_ sender: Any?) {
        // The start of the last command's echo, or the end if nothing has been run yet.
        landCaret(at: lastCommandOffset ?? textLength)
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
        copyToPasteboard(lines.joined(separator: "\n"), announce: "Copied entire transcript")
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

/// A text view that reports only the caret's line to VoiceOver on focus.
///
/// VoiceOver announces a text area by reading its *visible* text, not its value, so
/// accessibilityVisibleCharacterRange is what decides how much gets read; left at its default
/// it is the whole scrollback. Both that and the value are narrowed to the caret's line here,
/// and the role is reported as static text so VoiceOver treats the view as something to read
/// rather than a text entry area. Everything else -- string-for-range, line-for-index,
/// range-for-line, the character count -- is left at its default over the full text, so line,
/// word and character navigation and selection still range over the entire transcript.
final class TranscriptTextView: NSTextView, NSTextViewDelegate {

    /// Fallback for VoiceOver not tracking the caret once the view is static text: when true
    /// the view speaks what the caret moves over itself. Off, because VoiceOver's own reading
    /// is better when it works and two voices at once is worse than one.
    static let selfVoicedNavigation = false

    /// Caret offset as of the last selection change, for working out what was just passed over.
    private var lastAnnouncedCaret = 0

    // MARK: - The caret's line

    /// Paragraph range at an offset, including its trailing newline.
    private func paragraphRange(at location: Int) -> NSRange {
        guard let text = textStorage?.mutableString, text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        return text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
    }

    /// Range of the line at an offset, without its trailing newline: VoiceOver reads a
    /// newline inside the range it is given as "new line" after every line.
    private func lineRange(at location: Int) -> NSRange {
        guard let text = textStorage?.mutableString else { return NSRange(location: 0, length: 0) }
        var line = paragraphRange(at: location)
        if line.length > 0, text.character(at: line.location + line.length - 1) == 0x0a {
            line.length -= 1
        }
        return line
    }

    private var caretLineRange: NSRange {
        lineRange(at: selectedRange().location)
    }

    /// Text of the line the insertion point is on, with runs of spaces collapsed to one: the
    /// column padding in output like `ls` is dead air when spoken. Read off the storage's own
    /// backing string, so answering never copies the transcript.
    var caretLineText: String {
        guard let text = textStorage?.mutableString else { return "" }
        return TranscriptTextView.collapsingSpaces(text.substring(with: caretLineRange))
    }

    private static func collapsingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }

    // MARK: - Accessibility

    /// Static text, not a text entry area. VoiceOver reads a text area's full contents when it
    /// takes focus; static text it reads through the visible range, which is the caret's line.
    /// The view is read-only, so there is nothing to lose in giving up the entry semantics.
    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    // NSTextView narrows the accessibility protocol's Any? to String?.
    override func accessibilityValue() -> String? {
        caretLineText
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        caretLineRange
    }

    // MARK: - Self-voiced navigation (fallback)

    func textViewDidChangeSelection(_ notification: Notification) {
        let caret = min(selectedRange().location, textStorage?.mutableString.length ?? 0)
        let previous = lastAnnouncedCaret
        lastAnnouncedCaret = caret
        guard TranscriptTextView.selfVoicedNavigation,
              let text = textStorage?.mutableString,
              caret != previous else { return }

        let spoken: String
        if lineRange(at: caret) != lineRange(at: min(previous, text.length)) {
            // Moved to another line: read the whole line, as VoiceOver would.
            spoken = caretLineText
        } else {
            // Moved within the line: read what was passed over, a character or a word.
            let range = NSRange(location: min(caret, previous), length: abs(caret - previous))
            spoken = TranscriptTextView.collapsingSpaces(text.substring(with: range))
        }
        guard !spoken.isEmpty else { return }

        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [.announcement: spoken,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
