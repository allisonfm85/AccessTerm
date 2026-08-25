import AppKit

/// Three parts, top to bottom:
///  1. Transcript: an NSTableView, one logical line per row. Arrow keys move and VoiceOver
///     reads each row; Shift-arrows extend the selection; Command-C copies selected rows.
///     Rows are append-only, so the reading position never moves under you.
///  2. Current line: a label with whatever is not yet committed (usually the prompt).
///  3. Command line: a native text field. Enter sends the line to the shell.
final class MainViewController: NSViewController,
                                NSTableViewDataSource, NSTableViewDelegate,
                                NSTextFieldDelegate, TerminalSessionDelegate,
                                NSMenuItemValidation {

    let session = TerminalSession()
    private let announcer = Announcer()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let liveLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField()

    private let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let cellIdentifier = NSUserInterfaceItemIdentifier("lineCell")

    /// Committed transcript lines.
    private var lines: [String] = []
    /// Non-nil while a full-screen program owns the alternate screen; the table shows this instead.
    private var screenLines: [String]?
    private var displayedLines: [String] { screenLines ?? lines }

    private var liveText = ""
    /// True while the selection is at (or past) the end, so the view follows new output.
    private var followOutput = true

    private var history: [String] = []
    private var historyIndex = 0
    private var keyMonitor: Any?

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.title = "Line"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 22
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Transcript")

        scrollView.documentView = tableView
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

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedLines.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellIdentifier
            cell.font = monoFont
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
        }
        let text = displayedLines[row]
        cell.stringValue = text
        // stringValue stays exactly as the terminal drew it so copying is faithful, but the
        // column padding in output like `ls` is dead air when spoken; collapse the runs so
        // VoiceOver reads the columns as words.
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            cell.setAccessibilityLabel("blank line")
        } else {
            cell.setAccessibilityLabel(text.replacingOccurrences(of: " {2,}",
                                                                 with: " ",
                                                                 options: .regularExpression))
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let last = displayedLines.count - 1
        followOutput = tableView.selectedRowIndexes.isEmpty || tableView.selectedRow == last
    }

    private func appendLines(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        let start = lines.count
        lines.append(contentsOf: newLines)
        guard screenLines == nil else { return }
        tableView.insertRows(at: IndexSet(integersIn: start..<lines.count), withAnimation: [])
        if followOutput {
            tableView.scrollRowToVisible(lines.count - 1)
        }
    }

    private func selectLastRow() {
        let last = displayedLines.count - 1
        guard last >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
        followOutput = true
    }

    // MARK: - TerminalSessionDelegate

    func session(_ session: TerminalSession, didUpdate update: TerminalUpdate) {
        if let screen = update.alternateScreen {
            let previous = screenLines
            screenLines = screen
            tableView.reloadData()
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
            tableView.reloadData()
            selectLastRow()
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
        if tableView.selectedRow < 0 { selectLastRow() }
        view.window?.makeFirstResponder(tableView)
    }

    @objc func focusCommandLine(_ sender: Any?) {
        view.window?.makeFirstResponder(commandField)
    }

    @objc func goToEnd(_ sender: Any?) {
        selectLastRow()
        view.window?.makeFirstResponder(tableView)
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
        copyToPasteboard(displayedLines.joined(separator: "\n"), announce: "Copied entire transcript")
    }

    /// Reached through the responder chain when the transcript table has focus.
    @objc func copy(_ sender: Any?) {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let text = rows.map { displayedLines[$0] }.joined(separator: "\n")
        copyToPasteboard(text, announce: rows.count == 1 ? "Copied line" : "Copied \(rows.count) lines")
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
        if menuItem.action == #selector(copy(_:)) {
            return !tableView.selectedRowIndexes.isEmpty
        }
        return true
    }
}
