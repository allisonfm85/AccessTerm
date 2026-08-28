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
        // Static text, not a text field: nothing here reports an editable value, and nothing
        // posts one changing.
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
    }

    private func refresh(_ changed: Bool) {
        guard changed else { return }
        caret = min(caret, text.count)
        needsDisplay = true
        setAccessibilityValue(text)
    }

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
