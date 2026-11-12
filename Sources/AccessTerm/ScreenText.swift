import Foundation

/// The alternate screen as one piece of text, for VoiceOver to read: rows joined by
/// newlines, and the program's cursor as the position in it. Pure arithmetic on UTF-16
/// offsets, which is what accessibility ranges count.
struct ScreenText: Equatable {
    let text: String
    /// Where the program's cursor is, as an offset into `text`.
    let cursor: Int
    private let lineStarts: [Int]
    private let lineLengths: [Int]

    init(rows: [String], cursorRow: Int, cursorCol: Int) {
        var starts: [Int] = []
        var lengths: [Int] = []
        var offset = 0
        for row in rows {
            starts.append(offset)
            let length = (row as NSString).length
            lengths.append(length)
            offset += length + 1
        }
        self.text = rows.joined(separator: "\n")
        self.lineStarts = starts
        self.lineLengths = lengths
        if cursorRow >= 0, cursorRow < rows.count {
            // The row is trimmed, so a cursor past its end is at its end.
            let row = rows[cursorRow] as NSString
            let column = max(0, min(cursorCol, row.length))
            self.cursor = starts[cursorRow] + column
        } else {
            self.cursor = 0
        }
    }

    /// The text of the line the cursor is on.
    var cursorLine: String { string(for: range(forLine: line(for: cursor))) }

    var length: Int { (text as NSString).length }

    /// The line an offset is on.
    func line(for location: Int) -> Int {
        var line = 0
        for (index, start) in lineStarts.enumerated() where start <= location { line = index }
        return line
    }

    /// Range of a line without its newline, which VoiceOver would read aloud.
    func range(forLine line: Int) -> NSRange {
        guard line >= 0, line < lineStarts.count else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lineStarts[line], length: lineLengths[line])
    }

    func string(for range: NSRange) -> String {
        let all = text as NSString
        let location = max(0, min(range.location, all.length))
        let end = max(location, min(range.location + range.length, all.length))
        return all.substring(with: NSRange(location: location, length: end - location))
    }
}
