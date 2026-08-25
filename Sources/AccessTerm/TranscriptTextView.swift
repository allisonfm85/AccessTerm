import AppKit

/// The transcript's text view: an ordinary text area, blanked for a moment while the app
/// moves the caret.
///
/// An unmodified text area is what VoiceOver reads best. It follows the caret itself and reads
/// by line, word and character, and it announces selection changes -- extending, shrinking and
/// flipping the anchor -- in the user's own voice settings and phrasing. Reporting the view as
/// static text, or narrowing its value and visible range to the caret's line, all buy quiet at
/// the cost of that native reading, so none of it is done here.
///
/// What is left is the one thing a transcript genuinely needs: VoiceOver reads a newly focused
/// text area's whole contents, which for a scrollback is far too much. beginQuietWindow leaves
/// the view with nothing to read as focus arrives, and landCaret speaks the landing line.
final class TranscriptTextView: NSTextView, NSTextViewDelegate {

    /// Whether the view speaks caret movement and selection changes itself instead of leaving
    /// them to VoiceOver. Off: VoiceOver does both natively, and doing it here would only
    /// double up on what it says and add latency to the caret.
    static let selfVoicedNavigation = false

    /// Where announcements go. Nil means VoiceOver; a test driver can set it to collect them.
    var announcementSink: ((String) -> Void)?

    /// Selection as of the last announcement, which is what the next change is measured
    /// against. Kept in step with the caret even when a change says nothing, so a silent
    /// change never makes the one after it describe the wrong stretch of text.
    private var lastAnnouncedSelection = NSRange(location: 0, length: 0)
    /// Set while the app moves the caret or replaces the text itself.
    private var isSuppressingSelfVoice = false
    /// Set while the view should report nothing to read: see beginQuietWindow.
    private var isQuiet = false
    private var quietGeneration = 0

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

    /// Newlines and tabs collapse too, for text spoken as one phrase rather than as a line.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The quiet window

    /// The role is NSTextView's own: a text area, which is what gives VoiceOver its native
    /// line, word, character and selection reading. Nothing below narrows what the view
    /// reports either -- outside the quiet window every one of these defers to super.
    ///
    /// While the window is open they all report empty. VoiceOver reads a focused text area
    /// from whichever attribute it asks for first, and which one that is varies with the
    /// verbosity settings and the rotor, so leaving any single one of them answering in full
    /// leaves a way for the whole transcript to be read out.

    // NSTextView narrows the accessibility protocol's Any? to String?.
    override func accessibilityValue() -> String? {
        isQuiet ? "" : super.accessibilityValue()
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        guard isQuiet else { return super.accessibilityVisibleCharacterRange() }
        let length = textStorage?.mutableString.length ?? 0
        return NSRange(location: min(selectedRange().location, length), length: 0)
    }

    override func accessibilityNumberOfCharacters() -> Int {
        isQuiet ? 0 : super.accessibilityNumberOfCharacters()
    }

    override func accessibilityString(for range: NSRange) -> String? {
        isQuiet ? "" : super.accessibilityString(for: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        isQuiet ? NSAttributedString(string: "") : super.accessibilityAttributedString(for: range)
    }

    /// Report nothing to read for a moment.
    ///
    /// VoiceOver reads a newly focused element at the moment focus arrives, and for a text
    /// area that is its whole contents -- the entire scrollback, and read from the line the
    /// caret was on beforehand rather than the one it is about to land on. With nothing to
    /// read it stays quiet, and landCaret's high-priority announcement supplies the landing
    /// line instead.
    func beginQuietWindow(_ duration: TimeInterval = 0.3) {
        isQuiet = true
        quietGeneration += 1
        let generation = quietGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.quietGeneration == generation else { return }
            self.isQuiet = false
            // The view answers in full again. Tell VoiceOver the selection moved rather than
            // that the value changed: it resyncs to the caret without reading the text back.
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
    }

    // MARK: - Self-voiced navigation

    /// Runs a caret or contents change the app made itself without self-voicing it: the user
    /// did not move the caret, so there is nothing for them to hear. The landing announcement
    /// in landCaret would otherwise be said twice, once here and once there.
    func withoutSelfVoicing(_ body: () -> Void) {
        let wasSuppressing = isSuppressingSelfVoice
        isSuppressingSelfVoice = true
        body()
        isSuppressingSelfVoice = wasSuppressing
        // Re-anchor, so the user's next move is measured from where the caret actually is.
        lastAnnouncedSelection = clamped(selectedRange())
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = textStorage?.mutableString.length ?? 0
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    // MARK: - What changed

    /// The parts of `range` that lie outside `other`, in document order. A range can stick out
    /// of `other` at both ends -- the anchor of a selection flips, and it grows at one end
    /// while shrinking at the other -- so this is up to two pieces.
    private static func subtracting(_ other: NSRange, from range: NSRange) -> [NSRange] {
        let shared = NSIntersectionRange(range, other)
        guard shared.length > 0 else { return range.length > 0 ? [range] : [] }

        var pieces: [NSRange] = []
        if shared.location > range.location {
            pieces.append(NSRange(location: range.location,
                                  length: shared.location - range.location))
        }
        let sharedEnd = shared.location + shared.length
        let end = range.location + range.length
        if end > sharedEnd {
            pieces.append(NSRange(location: sharedEnd, length: end - sharedEnd))
        }
        return pieces
    }

    /// Past this many characters a change is counted rather than read out, so Command-A or a
    /// long drag does not recite the transcript.
    private static let maxSpokenSelectionLength = 240

    /// One clause of an announcement: the text of `pieces` followed by `verb`, or nil when
    /// they are empty.
    private func spokenPhrase(for pieces: [NSRange], verb: String, in text: NSMutableString) -> String? {
        let total = pieces.reduce(0) { $0 + $1.length }
        guard total > 0 else { return nil }
        guard total <= TranscriptTextView.maxSpokenSelectionLength else {
            return "\(total) characters \(verb)"
        }
        let body = pieces
            .map { TranscriptTextView.collapsingWhitespace(text.substring(with: $0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return body.isEmpty ? verb : "\(body) \(verb)"
    }

    /// What to say for a selection change, worked out by comparing the two selections as sets
    /// of characters rather than by their lengths: text the change added is "selected", text it
    /// took away is "unselected", and a change that flips the anchor does both at once. That
    /// covers extending either way, shrinking from either end, and word-wise moves, none of
    /// which a length comparison distinguishes.
    private func selectionAnnouncement(from previous: NSRange, to current: NSRange,
                                       in text: NSMutableString) -> String {
        if current.location == 0, current.length == text.length, text.length > 0 {
            return "all selected"
        }
        let removed = TranscriptTextView.subtracting(current, from: previous)
        let added = TranscriptTextView.subtracting(previous, from: current)
        return [spokenPhrase(for: removed, verb: "unselected", in: text),
                spokenPhrase(for: added, verb: "selected", in: text)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// What to say for a caret move: the whole line when it crossed lines, otherwise the text
    /// it passed over, which is the character or word just stepped across.
    private func movementAnnouncement(from previous: Int, to caret: Int, in text: NSMutableString) -> String {
        guard caret != previous else { return "" }
        if lineRange(at: caret) != lineRange(at: min(previous, text.length)) {
            return caretLineText
        }
        let range = NSRange(location: min(caret, previous), length: abs(caret - previous))
        return TranscriptTextView.collapsingSpaces(text.substring(with: range))
    }

    // MARK: - Announcing it

    /// How long changes are gathered before being spoken. VoiceOver drops whatever it was
    /// about to say when a new announcement arrives, so two Shift-arrows in quick succession
    /// would otherwise leave only the second one audible. Changes arriving within this window
    /// of the last announcement are held and then described together, measured from the
    /// selection last announced, so nothing goes unspoken however fast the keys repeat.
    ///
    /// Long enough that a held-down Shift-arrow is spoken in whole phrases rather than
    /// syllables, short enough that a deliberate second press is not noticeably late. Single
    /// presses are unaffected: the first change of a burst always speaks immediately.
    private static let announcementWindow: TimeInterval = 0.4

    private var lastAnnouncementTime = Date.distantPast
    private var isAnnouncementScheduled = false
    /// Whether the user has changed the selection since the last announcement, which is not
    /// the same as the selection differing from it: a burst can end where it began.
    private var hasUnspokenChange = false

    func textViewDidChangeSelection(_ notification: Notification) {
        // First, and before any bookkeeping: with self-voicing off this is every caret move,
        // and VoiceOver is already speaking it. Nothing here may delay that.
        guard TranscriptTextView.selfVoicedNavigation else { return }
        guard !isSuppressingSelfVoice else {
            // Nothing to say, but the caret has still moved: measure the next change from here.
            lastAnnouncedSelection = clamped(selectedRange())
            hasUnspokenChange = false
            return
        }
        hasUnspokenChange = true
        guard clamped(selectedRange()) != lastAnnouncedSelection else { return }

        let sinceLast = Date().timeIntervalSince(lastAnnouncementTime)
        guard sinceLast < TranscriptTextView.announcementWindow else {
            speakSelectionChange()
            return
        }
        guard !isAnnouncementScheduled else { return }  // the pending one will cover this too
        isAnnouncementScheduled = true
        let delay = TranscriptTextView.announcementWindow - sinceLast
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isAnnouncementScheduled = false
            self.speakSelectionChange()
        }
    }

    /// Says what changed between the selection last announced and the selection now, then
    /// re-anchors. Re-anchoring happens whether or not anything was said, so a change that
    /// speaks nothing still counts as seen.
    private func speakSelectionChange() {
        let previous = lastAnnouncedSelection
        let current = clamped(selectedRange())
        let hadChange = hasUnspokenChange
        lastAnnouncedSelection = current
        hasUnspokenChange = false
        guard hadChange, let text = textStorage?.mutableString else { return }

        let spoken: String
        if current == previous {
            // Gathered changes that cancelled out -- Shift-Down then Shift-Up. Saying nothing
            // reads as a dropped announcement, so say where that leaves them.
            spoken = current.length == 0 ? "nothing selected" : ""
        } else if current.length == 0, previous.length == 0 {
            spoken = movementAnnouncement(from: previous.location, to: current.location, in: text)
        } else {
            spoken = selectionAnnouncement(from: previous, to: current, in: text)
        }
        guard !spoken.isEmpty else { return }

        lastAnnouncementTime = Date()
        announce(spoken)
    }

    private func announce(_ text: String) {
        if let sink = announcementSink {
            sink(text)
            return
        }
        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
