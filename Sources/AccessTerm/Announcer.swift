import AppKit

/// Picks what in a batch of transcript changes is worth speaking: a line that is not blank,
/// and that does not already say, for that line, what was last announced for it. A program
/// repainting its frame rewrites the same lines with the same words several times a second,
/// and none of that is news; a line that fills in, or changes, is spoken once.
struct LineNews {
    private var announced: [Int: String] = [:]

    mutating func news(in update: TerminalUpdate) -> [String] {
        var byLine: [Int: String] = [:]
        for edit in update.edits { byLine[edit.line] = edit.text }
        for (index, text) in update.newLines.enumerated() {
            byLine[update.firstNewLine + index] = text
        }
        var spoken: [String] = []
        for line in byLine.keys.sorted() {
            guard let text = byLine[line],
                  !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  announced[line] != text else { continue }
            announced[line] = text
            spoken.append(text)
        }
        return spoken
    }
}

/// Sends output to VoiceOver as announcements, batched so a burst of lines
/// becomes one utterance instead of dozens of interruptions.
final class Announcer {
    /// When off, streamed output is silent. Bells and explicit reads still speak.
    var enabled = true
    /// Where announcements go. Nil means VoiceOver; a test driver can set it to collect them.
    var sink: ((String) -> Void)?
    var maxLinesPerAnnouncement = 30

    private var pending: [String] = []
    private var flushScheduled = false

    func enqueue(_ lines: [String]) {
        guard enabled else { return }
        let useful = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !useful.isEmpty else { return }
        pending.append(contentsOf: useful)

        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.flush()
        }
    }

    func announceNow(_ text: String, priority: NSAccessibilityPriorityLevel = .high) {
        post(text, priority: priority)
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let text: String
        if pending.count > maxLinesPerAnnouncement {
            let tail = pending.suffix(maxLinesPerAnnouncement)
            text = "\(pending.count) lines of output. Last \(maxLinesPerAnnouncement): "
                + tail.joined(separator: "\n")
        } else {
            text = pending.joined(separator: "\n")
        }
        pending.removeAll()
        post(text, priority: .medium)
    }

    private func post(_ text: String, priority: NSAccessibilityPriorityLevel) {
        if let sink {
            sink(text)
            return
        }
        let element: Any
        if let window = NSApp.mainWindow {
            element = window
        } else {
            element = NSApplication.shared
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue
            ]
        )
    }
}
