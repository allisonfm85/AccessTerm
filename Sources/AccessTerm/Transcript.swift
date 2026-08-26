import Foundation

/// The transcript as a document: logical lines, and where each one starts in the assembled
/// text the UI mirrors.
///
/// Lines are usually appended and never touched again. They cannot be only appended, though:
/// a program that redraws rows it has already printed -- Claude Code's screen reader mode
/// erases and reprints its whole frame several times a second -- keeps rewriting the rows
/// earlier lines were built from. Repeating those rows would fill the transcript with stale
/// copies of every frame, so the line a row produced is rewritten in place instead.
final class Transcript {
    /// One entry per logical line, in order.
    private(set) var lines: [String] = []
    /// Character offset of the start of each line in the assembled text.
    private(set) var offsets: [Int] = []
    /// Character length of the assembled text, counting the newline after every line.
    private(set) var length = 0

    /// One replacement to make in the text a mirror of this transcript holds. Ranges are the
    /// ranges to replace at the moment the edit is produced, so a mirror that applies a batch
    /// in the order it arrived stays in step; applying them out of order does not work.
    struct Edit {
        var line: Int
        var range: NSRange
        var text: String
    }

    var count: Int { lines.count }

    /// Offset of the start of a line, clamped, so callers can turn a line number into
    /// somewhere to put the caret.
    func offset(ofLine line: Int) -> Int {
        guard !offsets.isEmpty else { return 0 }
        return offsets[max(0, min(line, offsets.count - 1))]
    }

    @discardableResult
    func append(_ text: String) -> Int {
        offsets.append(length)
        lines.append(text)
        length += (text as NSString).length + 1
        return lines.count - 1
    }

    /// Rewrites one line. Nil when the text is unchanged, which is the common case: most of
    /// what a redraw rewrites is identical to what was there.
    func revise(_ line: Int, to text: String) -> Edit? {
        guard lines.indices.contains(line), lines[line] != text else { return nil }
        let old = (lines[line] as NSString).length
        let new = (text as NSString).length
        let edit = Edit(line: line, range: NSRange(location: offsets[line], length: old), text: text)
        lines[line] = text
        if new != old {
            let delta = new - old
            for index in (line + 1)..<offsets.count { offsets[index] += delta }
            length += delta
        }
        return edit
    }

    /// The whole transcript as one string, for the text view's initial fill and for copying.
    func text() -> String {
        lines.map { $0 + "\n" }.joined()
    }
}
