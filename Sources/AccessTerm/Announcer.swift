import AppKit

/// Picks what in a batch of transcript changes is worth speaking: a line that is not blank,
/// that is not the echo of what the user has just typed, and that does not already say, for
/// that line, what was last announced for it. A program repainting its frame rewrites the same
/// lines with the same words several times a second, and none of that is news; a line that
/// fills in, or changes, is spoken once.
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
                  !update.userEchoLines.contains(line),
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

/// The hint spoken after a yes/no prompt, so that what pressing Return alone does is heard
/// rather than inferred from which letter a program happened to capitalise. Programs write
/// the default as the capital of a bracketed pair -- "Continue? [y/N]", "Overwrite? [Y/n/a]"
/// -- or spell it out as "(default: yes)". Only the announcement gets the hint: the
/// transcript stays verbatim, so what is read and copied is what the program printed.
enum PromptDefault {
    /// `line` with its hint appended, or `line` unchanged when it is not a yes/no prompt.
    static func spoken(_ line: String) -> String {
        guard let hint = hint(for: line) else { return line }
        return line + hint
    }

    /// What Return alone does, when the end of `line` says. Nil when the line does not end in
    /// a yes/no prompt, and when it ends in one that names no default ("[y/n]") or more than
    /// one ("[Y/N]"): a guess about which key a program will take is worse than silence.
    static func hint(for line: String) -> String? {
        // A prompt's brackets are often followed by a colon, and by the space the cursor sits
        // in; neither is part of what is being asked.
        let tail = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
        if tail.hasSuffix("]"), let open = tail.lastIndex(of: "[") {
            let choices = tail[tail.index(after: open)..<tail.index(before: tail.endIndex)]
            return hint(forChoices: choices)
        }
        if tail.hasSuffix(")"), let open = tail.lastIndex(of: "(") {
            let note = tail[tail.index(after: open)..<tail.index(before: tail.endIndex)]
            return hint(forDefaultNote: note)
        }
        return nil
    }

    /// The letters of a bracketed prompt: single letters separated by slashes, at least one
    /// yes and one no among them, exactly one of them capitalised.
    private static func hint(forChoices choices: Substring) -> String? {
        let parts = choices.split(separator: "/", omittingEmptySubsequences: false)
        let letters = parts.compactMap { $0.count == 1 ? $0.first : nil }.filter { $0.isLetter }
        guard letters.count == parts.count, parts.count >= 2,
              letters.contains(where: { $0.lowercased() == "y" }),
              letters.contains(where: { $0.lowercased() == "n" }) else { return nil }
        let capitals = letters.filter { $0.isUppercase }
        guard capitals.count == 1 else { return nil }
        switch capitals[0] {
        case "Y": return yes
        case "N": return no
        default: return nil
        }
    }

    /// A default spelled out rather than bracketed: "(default: yes)", "(default no)".
    private static func hint(forDefaultNote note: Substring) -> String? {
        let words = note.lowercased().filter { !" \t:=".contains($0) }
        switch words {
        case "defaultyes": return yes
        case "defaultno": return no
        default: return nil
        }
    }

    private static let yes = " Press Return for yes."
    private static let no = " Press Return for no."
}
