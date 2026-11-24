import Foundation

/// Incremental reverse search through command history, in the manner of bash's and zsh's
/// Control-R. Pure state with no view or shell in it, so it can be tested on its own, like
/// ViLineEditor.
///
/// The shell supplies the entries (see ShellIntegration); this owns the query and which entry
/// it is sitting on. A match is a case-insensitive substring, and an entry that appears more
/// than once is offered once, at its most recent position.
struct HistorySearch {
    /// Oldest first, each distinct command once.
    let entries: [String]
    private(set) var query = ""
    /// Index of the entry the search is on, or entries.count when it is on none yet.
    private(set) var anchor: Int
    /// The query matches nothing at or before the anchor.
    private(set) var failing = false

    init(entries all: [String]) {
        // Keep the newest of any repeat: walk from the newest and drop what has been seen.
        var seen = Set<String>()
        var kept: [String] = []
        for entry in all.reversed() where !entry.isEmpty && seen.insert(entry).inserted {
            kept.append(entry)
        }
        entries = kept.reversed()
        anchor = entries.count
    }

    /// The entry the search is on, if any.
    var match: String? {
        guard !failing, anchor < entries.count else { return nil }
        return entries[anchor]
    }

    /// What the line shows while searching, as the shells draw it.
    var prompt: String {
        "(\(failing ? "failing " : "")reverse-i-search)'\(query)': \(match ?? "")"
    }

    /// Adds to the query. The search stays where it is if the current entry still matches,
    /// and otherwise moves to the next older one that does.
    mutating func type(_ characters: String) {
        query += characters
        guard !failing else { return }          // a longer query cannot match what a shorter one missed
        if let current = match, contains(current) { return }
        let start = anchor < entries.count ? anchor : entries.count - 1
        if let found = find(from: start, step: -1) {
            anchor = found
        } else {
            failing = true
        }
    }

    /// Removes the last character and starts again from the newest entry.
    mutating func backspace() {
        guard !query.isEmpty else { return }
        query.removeLast()
        failing = false
        anchor = entries.count
        if !query.isEmpty, let found = find(from: entries.count - 1, step: -1) { anchor = found }
    }

    /// Moves to the next older match. False, and nothing moves, when there is none.
    @discardableResult
    mutating func older() -> Bool {
        if failing { failing = false; anchor = entries.count }
        if let found = find(from: anchor - 1, step: -1) {
            anchor = found
            return true
        }
        if anchor == entries.count { failing = true }
        return false
    }

    /// Moves to the next newer match. False, and nothing moves, when there is none.
    @discardableResult
    mutating func newer() -> Bool {
        guard !failing, anchor < entries.count,
              let found = find(from: anchor + 1, step: 1) else { return false }
        anchor = found
        return true
    }

    private func contains(_ entry: String) -> Bool {
        query.isEmpty || entry.range(of: query, options: .caseInsensitive) != nil
    }

    private func find(from start: Int, step: Int) -> Int? {
        var index = start
        while index >= 0, index < entries.count {
            if contains(entries[index]) { return index }
            index += step
        }
        return nil
    }
}
