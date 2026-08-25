import AppKit

/// Sends output to VoiceOver as announcements, batched so a burst of lines
/// becomes one utterance instead of dozens of interruptions.
final class Announcer {
    /// When off, streamed output is silent. Bells and explicit reads still speak.
    var enabled = true
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
