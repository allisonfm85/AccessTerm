import AppKit

protocol InputLineViewDelegate: AnyObject {
    /// The user pressed Return. The line is handed over and the view is left empty.
    func inputLine(_ view: InputLineView, didSubmit text: String)
    /// A key the shell owns rather than the input line: history, completion, a control
    /// character. `text` is whatever had been typed and not yet sent, for the delegate to
    /// flush first so that the shell's line and this one do not disagree.
    func inputLine(_ view: InputLineView, didSendToShell bytes: [UInt8], pending text: String)
    /// A character was typed or deleted, for the delegate to say if it says such things.
    func inputLineDidEdit(_ view: InputLineView, speaking text: String)
}

/// The command line: a view that is drawn and read, and never edited.
///
/// It is deliberately not a text control. An editable field is narrated by the system on its
/// own terms: the field editor reports every change it makes, and emptying it on Return is
/// reported as a deletion, which a screen reader describes by reading out the text that has
/// just gone -- the command said back a moment after it was typed. None of that is ours to
/// switch off from outside, so there is nothing here for it to happen to. This view keeps the
/// string, draws it, and tells VoiceOver what it says through a label it is told to update.
/// Nothing here posts a value change, and nothing here is editable as far as the system is
/// concerned.
///
/// What that costs is what a field editor was doing: there is no caret to move, so editing is
/// typing and Backspace. Text is committed as a whole line, so the shell has not seen a
/// character of it until then -- anything the shell has to answer for itself, completion and
/// history among them, is sent through the delegate, which flushes what is pending first.
final class InputLineView: NSView {

    weak var delegate: InputLineViewDelegate?

    /// Whether the view says what is typed into it. VoiceOver's own key echo is off for many
    /// people, and a view that is not a text control gets none of the narration a field would:
    /// without this, typing is silent. On, each character and each deletion is spoken as it
    /// happens.
    /// ACCESSTERM_QUIET_TYPING turns it off without a rebuild, for comparing the two against a
    /// screen reader.
    static var speaksTyping = ProcessInfo.processInfo.environment["ACCESSTERM_QUIET_TYPING"] == nil

    /// Whether keys are taken at all. Off once the shell has exited.
    var isEnabled = true

    /// What has been typed and not yet sent. Setting it redraws and re-labels, and announces
    /// nothing: what to say about a change is the delegate's business, and submitting says
    /// nothing at all.
    private(set) var text = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
            updateAccessibilityLabel()
        }
    }

    var placeholder = "" {
        didSet { needsDisplay = true; updateAccessibilityLabel() }
    }

    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let padding = NSSize(width: 4, height: 3)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        // Static text, not a text field: nothing about this reports an editable value, and
        // nothing posts one changing.
        setAccessibilityRole(.staticText)
        updateAccessibilityLabel()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Contents

    /// Empties the line without a word about what was in it. This is what Return does, and the
    /// whole reason the input is not a field.
    func clear() {
        text = ""
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(text.isEmpty ? "Command line, empty" : "Command line, \(text)")
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

        // A caret, so that someone watching can see where typing goes. It sits after the text
        // because that is the only place typing can go: there is no caret to move.
        guard window?.firstResponder === self else { return }
        let width = text.isEmpty ? 0 : (text as NSString).size(withAttributes: attributes).width
        let caret = NSRect(x: origin.x + width, y: origin.y,
                           width: 1, height: ceil(font.ascender - font.descender))
        NSColor.textColor.setFill()
        caret.fill()
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // MARK: - Keys

    /// The keys the shell owns. Everything else is text, or Backspace, or Return.
    private static let escape: UInt16 = 53
    private static let delete: UInt16 = 51
    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
    private static let tab: UInt16 = 48
    private static let up: UInt16 = 126
    private static let down: UInt16 = 125
    private static let left: UInt16 = 123
    private static let right: UInt16 = 124

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Command combinations are menu business, and Control combinations other than the ones
        // below keep whatever meaning the responder chain gives them.
        if flags.contains(.command) {
            super.keyDown(with: event)
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
        case InputLineView.delete:
            deleteBackward()
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
        case InputLineView.left:
            sendToShell([0x1b, 0x5b, 0x44])
        case InputLineView.right:
            sendToShell([0x1b, 0x5b, 0x43])
        default:
            insert(event.characters ?? "")
        }
    }

    /// Text that is not a control character. Anything else -- a function key, a dead key on its
    /// own -- is not something to type.
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
        text += typed
        speak(typed)
    }

    private func deleteBackward() {
        guard let last = text.last else { return }
        text.removeLast()
        speak(String(last) + " deleted")
    }

    private func speak(_ what: String) {
        guard InputLineView.speaksTyping else { return }
        delegate?.inputLineDidEdit(self, speaking: what)
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
        let flattened = pasted
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        insert(flattened)
    }
}
