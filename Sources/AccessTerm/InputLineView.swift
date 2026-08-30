import AppKit

protocol InputLineViewDelegate: AnyObject {
    /// The user pressed Return. The line is handed over and the view is left empty.
    func inputLine(_ view: InputLineView, didSubmit text: String)
    /// A key the shell owns rather than the input line: history, completion, a control
    /// character. `text` is whatever had been typed and not yet sent, for the delegate to
    /// flush first so that the shell's line and this one do not disagree.
    func inputLine(_ view: InputLineView, didSendToShell bytes: [UInt8], pending text: String)
    /// Something for the screen reader to say: the character the caret crossed, the word it
    /// crossed, what a deletion removed. Typing itself says nothing.
    func inputLine(_ view: InputLineView, announce text: String)
}

/// The command line: a view that is drawn and read, and never edited by the system.
///
/// It is deliberately not a text control. An editable field is narrated by the system on its
/// own terms: the field editor reports every change it makes, and emptying it on Return is
/// reported as a deletion, which a screen reader describes by reading out the text that has
/// just gone -- the command said back a moment after it was typed. None of that is ours to
/// switch off from outside, so there is nothing here for it to happen to. This view keeps the
/// string and the caret, draws them, and reports the string to VoiceOver as the value of a
/// piece of static text. Nothing here posts a value change.
///
/// What a field editor was also doing was letting someone read back what they had typed, and
/// that has to be replaced rather than dropped: the caret moves by character and by word, and
/// this view says what it crossed. Typing is silent, because VoiceOver's key echo is the
/// setting that decides whether typing is spoken, and it is not this app's to override.
///
/// The shell has not seen a character of the line until Return, so anything the shell answers
/// for itself -- completion, its own history -- is sent through the delegate, which flushes
/// what is pending first.
final class InputLineView: NSView {

    weak var delegate: InputLineViewDelegate?

    /// Whether keys are taken at all. Off once the shell has exited.
    var isEnabled = true

    /// On while a full-screen program owns the alternate screen. The line-at-a-time model
    /// has nothing to offer such a program -- it reads keys, not lines -- so every keystroke
    /// is encoded as terminal bytes and sent straight through; nothing is buffered, reviewed
    /// or drawn here. Command chords are the one exception: they still belong to the app, so
    /// Command-1 review and Command-2 return work exactly as they do at the prompt. The label
    /// changes so a focus read says where the keys are going.
    var passthrough = false {
        didSet {
            guard passthrough != oldValue else { return }
            setAccessibilityLabel(passthrough ? "Program input" : "Command line")
            needsDisplay = true
        }
    }

    /// Read at each keystroke while passing through: whether the program has asked for
    /// application cursor keys, which decides how arrows are encoded. Supplied by the
    /// controller from the live terminal state; never cached here.
    var applicationCursorKeys: () -> Bool = { false }

    /// What has been typed and not yet sent.
    private(set) var text = "" { didSet { refresh(oldValue != text) } }

    /// Where the next character goes, counted in characters from the start. Everything that
    /// moves it says what it crossed; nothing else here speaks.
    private(set) var caret = 0 { didSet { needsDisplay = true } }

    var placeholder = "" { didSet { needsDisplay = true } }

    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let padding = NSSize(width: 4, height: 3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        // Static text, not a text field: nothing here reports an editable value, and typing
        // posts no value changes. The one exception is clear() -- see the note there.
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Command line")
        refresh(true)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Contents

    /// Empties the line without a word about what was in it. This is what Return does, and the
    /// whole reason the input is not a field.
    func clear() {
        text = ""
        caret = 0
        // The one value-changed notification this view ever posts. VoiceOver caches the
        // value whenever it reads the line, and with no notification nothing ever
        // invalidates that cache -- a later focus read can serve the submitted line back
        // (the phantom-line bug: heard as the old line followed by "Command line").
        // Typing stays unnarrated because inserts still post nothing; this fires only
        // when the line empties, when the value is "" and there is nothing to say.
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// The line handed back by the shell after a completion (see the session's OSC 7770
    /// handling). Silent in itself: the caller announces what changed. From here the line is
    /// reviewable, correctable and submittable again, exactly as if it had been typed.
    func adopt(_ newText: String, caret newCaret: Int) {
        text = newText
        caret = max(0, min(newCaret, newText.count))
    }

    private func refresh(_ changed: Bool) {
        guard changed else { return }
        caret = min(caret, text.count)
        needsDisplay = true
    }

    /// Served at fetch time rather than pushed with setAccessibilityValue: a pushed value
    /// is stored state, and stored state is one more place a stale line can survive. A
    /// getter can only ever answer with the current text. Same pattern as the transcript
    /// view's quiet window.
    override func accessibilityValue() -> Any? { text }

    /// The string index `offset` characters in, clamped.
    private func index(_ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: max(0, min(offset, text.count)))
    }

    // MARK: - Drawing

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: ceil(font.ascender - font.descender + font.leading) + padding.height * 2)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill()
        frame.fill()
        NSColor.separatorColor.setStroke()
        frame.stroke()

        let showing = text.isEmpty ? placeholder : text
        let colour = text.isEmpty ? NSColor.placeholderTextColor : NSColor.textColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let origin = NSPoint(x: padding.width, y: padding.height)
        (showing as NSString).draw(at: origin, withAttributes: attributes)

        guard window?.firstResponder === self else { return }
        let before = String(text[text.startIndex..<index(caret)])
        let width = before.isEmpty ? 0 : (before as NSString).size(withAttributes: attributes).width
        let bar = NSRect(x: origin.x + width, y: origin.y,
                         width: 1, height: ceil(font.ascender - font.descender))
        NSColor.textColor.setFill()
        bar.fill()
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // MARK: - Keys

    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
    private static let deleteKey: UInt16 = 51
    private static let forwardDelete: UInt16 = 117
    private static let escape: UInt16 = 53
    private static let tab: UInt16 = 48
    private static let home: UInt16 = 115
    private static let end: UInt16 = 119
    private static let pageUp: UInt16 = 116
    private static let pageDown: UInt16 = 121
    private static let up: UInt16 = 126
    private static let down: UInt16 = 125
    private static let left: UInt16 = 123
    private static let right: UInt16 = 124

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command-Left and Command-Right are the ends of the line. Every other Command
        // combination is the menu's business.
        if flags.contains(.command) {
            switch event.keyCode {
            case InputLineView.left: moveCaret(to: 0)
            case InputLineView.right: moveCaret(to: text.count)
            default: super.keyDown(with: event)
            }
            return
        }

        // A full-screen program reads keys, not lines: everything but Command chords goes to
        // it as terminal bytes. Anything typed at the prompt just before the program took the
        // screen is flushed first (through clear(), so VoiceOver's cached value of this line
        // is invalidated the same way Return invalidates it).
        if passthrough {
            guard let bytes = encodeForProgram(event, flags: flags) else { return }
            let pending = text
            if !pending.isEmpty { clear() }
            delegate?.inputLine(self, didSendToShell: bytes, pending: pending)
            return
        }

        if flags == [.control],
           let character = event.charactersIgnoringModifiers?.lowercased().first,
           character.isLetter, let ascii = character.asciiValue, "cdzl".contains(character) {
            sendToShell([ascii - 96])
            return
        }

        switch event.keyCode {
        case InputLineView.returnKey, InputLineView.enterKey:
            let submitted = text
            // Emptied first, and in silence, so that nothing can describe what was there.
            clear()
            delegate?.inputLine(self, didSubmit: submitted)
        case InputLineView.deleteKey:
            deleteBackward()
        case InputLineView.forwardDelete:
            deleteForward()
        case InputLineView.left where flags.contains(.option):
            moveCaret(to: wordStart(before: caret))
        case InputLineView.right where flags.contains(.option):
            moveCaret(to: wordEnd(after: caret))
        case InputLineView.left:
            moveCaret(to: caret - 1)
        case InputLineView.right:
            moveCaret(to: caret + 1)
        case InputLineView.home:
            moveCaret(to: 0)
        case InputLineView.end:
            moveCaret(to: text.count)
        case InputLineView.escape:
            sendToShell([0x1b])
        case InputLineView.tab where flags.contains(.shift):
            sendToShell([0x1b, 0x5b, 0x5a])
        case InputLineView.tab:
            sendToShell([0x09])
        case InputLineView.up:
            sendToShell([0x1b, 0x5b, 0x41])
        case InputLineView.down:
            sendToShell([0x1b, 0x5b, 0x42])
        default:
            insert(event.characters ?? "")
        }
    }

    // MARK: - Editing

    /// Text that is not a control character, put in at the caret. Silent: whether typing is
    /// spoken is VoiceOver's key echo setting, and this app does not answer that question for
    /// anyone.
    private func insert(_ characters: String) {
        let typed = characters.filter { character in
            character.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    // Arrow and function keys arrive as private-use scalars, not as control
                    // characters, and are not something anyone typed.
                    && !(0xF700...0xF8FF).contains(scalar.value)
            }
        }
        guard !typed.isEmpty else { return }
        let at = caret
        text.insert(contentsOf: typed, at: index(at))
        caret = at + typed.count
    }

    private func deleteBackward() {
        guard caret > 0 else { return }
        let position = index(caret - 1)
        let removed = text[position]
        let target = caret - 1
        text.remove(at: position)
        // Set rather than decrement: losing a character has already pulled the caret in by
        // one, and stepping back again from there would skip a character.
        caret = target
        announce(describing(String(removed)) + " deleted")
    }

    private func deleteForward() {
        guard caret < text.count else { return }
        let position = index(caret)
        let removed = text[position]
        text.remove(at: position)
        announce(describing(String(removed)) + " deleted")
    }

    // MARK: - Moving the caret

    /// Moves the caret and says what it crossed, which for one step is the character stepped
    /// over and for a word step is the word. A move that cannot happen says where it already
    /// is, rather than sounding like a key that did nothing.
    private func moveCaret(to position: Int) {
        let target = max(0, min(position, text.count))
        guard target != caret else {
            if text.isEmpty {
                announce("empty")
            } else {
                announce(caret == 0 ? "start of line" : "end of line")
            }
            return
        }
        let crossed = String(text[index(min(caret, target))..<index(max(caret, target))])
        caret = target
        announce(describing(crossed))
    }

    /// How a stretch of text is said. Whitespace has to be named or it sounds like nothing was
    /// crossed at all, and a long jump is counted rather than recited.
    private func describing(_ crossed: String) -> String {
        if crossed.isEmpty { return "" }
        if crossed.count > 60 { return "\(crossed.count) characters" }
        guard crossed.trimmingCharacters(in: .whitespaces).isEmpty else { return crossed }
        return crossed.count == 1 ? "space" : "\(crossed.count) spaces"
    }

    /// Start of the word to the left of `offset`: back over any spaces, then over the word.
    /// A word is a run of anything that is not a space, so a path or a flag is one word.
    private func wordStart(before offset: Int) -> Int {
        let characters = Array(text)
        var position = max(0, min(offset, characters.count))
        while position > 0, characters[position - 1].isWhitespace { position -= 1 }
        while position > 0, !characters[position - 1].isWhitespace { position -= 1 }
        return position
    }

    /// End of the word to the right of `offset`.
    private func wordEnd(after offset: Int) -> Int {
        let characters = Array(text)
        var position = max(0, min(offset, characters.count))
        while position < characters.count, characters[position].isWhitespace { position += 1 }
        while position < characters.count, !characters[position].isWhitespace { position += 1 }
        return position
    }

    private func announce(_ what: String) {
        guard !what.isEmpty else { return }
        delegate?.inputLine(self, announce: what)
    }

    /// Hands the shell a key it answers for itself, along with anything typed here that it has
    /// not seen: completion and history work on the line the shell holds, so what is pending
    /// has to become part of that line first.
    private func sendToShell(_ bytes: [UInt8]) {
        let pending = text
        clear()
        delegate?.inputLine(self, didSendToShell: bytes, pending: pending)
    }

    // MARK: - Full-screen program keys

    /// A keystroke as the bytes a terminal sends for it, or nil for one that sends nothing.
    /// This is what replaces the line-at-a-time handling while a program owns the screen:
    /// nano's Control-X, vim's chords, Option as Meta, arrows in whichever encoding the
    /// program asked for. Command chords never arrive here (keyDown keeps them for the app).
    private func encodeForProgram(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> [UInt8]? {
        let app = applicationCursorKeys()
        // ESC [ for normal cursor keys, ESC O when the program asked for application mode.
        func arrow(_ letter: UInt8) -> [UInt8] { [0x1b, app ? 0x4f : 0x5b, letter] }

        switch event.keyCode {
        case InputLineView.returnKey, InputLineView.enterKey: return [0x0d]
        case InputLineView.deleteKey: return [0x7f]
        case InputLineView.forwardDelete: return [0x1b, 0x5b, 0x33, 0x7e]
        case InputLineView.escape: return [0x1b]
        case InputLineView.tab where flags.contains(.shift): return [0x1b, 0x5b, 0x5a]
        case InputLineView.tab: return [0x09]
        // Control-arrows have their own fixed encoding (CSI 1;5 C/D), used by editors for
        // word movement; the plain arrows follow DECCKM.
        case InputLineView.right where flags.contains(.control):
            return [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x43]
        case InputLineView.left where flags.contains(.control):
            return [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]
        // Option-arrows are word movement, sent the way Terminal.app sends them.
        case InputLineView.left where flags.contains(.option): return [0x1b, 0x62]
        case InputLineView.right where flags.contains(.option): return [0x1b, 0x66]
        case InputLineView.up: return arrow(0x41)
        case InputLineView.down: return arrow(0x42)
        case InputLineView.right: return arrow(0x43)
        case InputLineView.left: return arrow(0x44)
        case InputLineView.home: return arrow(0x48)
        case InputLineView.end: return arrow(0x46)
        case InputLineView.pageUp: return [0x1b, 0x5b, 0x35, 0x7e]
        case InputLineView.pageDown: return [0x1b, 0x5b, 0x36, 0x7e]
        default: break
        }

        // Control chords, the full set this time -- at the prompt only C, D, Z and L pass
        // through, but a full-screen program's whole vocabulary is control characters
        // (Control-X is how nano exits). The mapping is the terminal's: letters to 1-26,
        // and the handful of punctuation control characters around them.
        if flags.contains(.control), !flags.contains(.option),
           let scalar = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            switch scalar {
            case "a"..."z": return [UInt8(scalar.value - 0x60)]
            case " ", "@": return [0x00]
            case "[": return [0x1b]
            case "\\": return [0x1c]
            case "]": return [0x1d]
            case "^", "6": return [0x1e]
            case "_", "-": return [0x1f]
            case "?": return [0x7f]
            default: return nil
            }
        }

        // Option is Meta: ESC then the unmodified character. nano writes its shortcuts as
        // M-U, M-A and so on, and this is what M- means.
        if flags.contains(.option),
           let base = event.charactersIgnoringModifiers,
           let scalar = base.unicodeScalars.first, !(0xF700...0xF8FF).contains(scalar.value) {
            return [0x1b] + Array(base.utf8)
        }

        // Function keys arrive as private-use scalars; F1-F4 have the old ESC O codes,
        // the rest are CSI number ~.
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF704...0xF70F).contains(scalar.value) {
            let codes: [[UInt8]] = [
                [0x1b, 0x4f, 0x50], [0x1b, 0x4f, 0x51], [0x1b, 0x4f, 0x52], [0x1b, 0x4f, 0x53],
                [0x1b, 0x5b, 0x31, 0x35, 0x7e], [0x1b, 0x5b, 0x31, 0x37, 0x7e],
                [0x1b, 0x5b, 0x31, 0x38, 0x7e], [0x1b, 0x5b, 0x31, 0x39, 0x7e],
                [0x1b, 0x5b, 0x32, 0x30, 0x7e], [0x1b, 0x5b, 0x32, 0x31, 0x7e],
                [0x1b, 0x5b, 0x32, 0x33, 0x7e], [0x1b, 0x5b, 0x32, 0x34, 0x7e],
            ]
            return codes[Int(scalar.value - 0xF704)]
        }

        // Everything else is text, sent as typed. The private-use range is the system's
        // encoding of keys that are not text (arrows not caught above, and so on).
        let typed = (event.characters ?? "").unicodeScalars
            .filter { !(0xF700...0xF8FF).contains($0.value) }
        guard !typed.isEmpty else { return nil }
        return Array(String(String.UnicodeScalarView(typed)).utf8)
    }

    // MARK: - Edit menu

    /// Command-V. The Edit menu's Paste travels the responder chain, so without this it would
    /// reach the input line and do nothing. Newlines are dropped rather than submitted: what is
    /// pasted is a command to look at before it runs.
    @objc func paste(_ sender: Any?) {
        guard isEnabled,
              let pasted = NSPasteboard.general.string(forType: .string) else { return }
        insert(pasted
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " "))
    }
}
