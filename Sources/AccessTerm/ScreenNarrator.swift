import Foundation

/// One read of the alternate screen, with the cursor: everything the narrator needs to say
/// what the cursor landed on.
struct ScreenFrame: Equatable {
    /// One string per screen row. A row that a following row wraps onto keeps its trailing
    /// spaces, because there they are real characters; every other row is right-trimmed.
    var rows: [String]
    /// `wrapped[i]` is true when row `i` is the continuation of row `i - 1`.
    var wrapped: [Bool]
    var cursorRow: Int
    var cursorCol: Int
    var cursorVisible: Bool
    /// Width of the screen in columns.
    var cols: Int

    init(rows: [String], wrapped: [Bool]? = nil, cursorRow: Int, cursorCol: Int,
         cursorVisible: Bool = true, cols: Int = 160) {
        self.rows = rows
        self.wrapped = wrapped ?? Array(repeating: false, count: rows.count)
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorVisible = cursorVisible
        self.cols = cols
    }
}

/// Decides what to say about a full-screen program from where its cursor is, rather than
/// from which rows of text changed. Built around vim and nvim, and it works the same
/// over ssh because it only looks at what the terminal emulator was told.
///
/// What is spoken:
/// - the cursor moved one cell along the same line: that character
/// - it moved further along the same line (w, b, e, 0, $, f): the word it is on
/// - it is on a different line, or the line it is on has changed (j, k, a search, :123, G,
///   a scroll, undo): the whole line
/// - the mode changed (insert, visual, back to normal), or a message appeared on the last row
///
/// What is not spoken is text typed at the cursor, which is VoiceOver's key echo to say
/// (#14), and the status line, the ruler and the rest of the screen.
///
/// `narrate` returns nil when this narrator has nothing to go on -- the cursor is hidden,
/// or the screen changed in a way a cursor does not explain (a pager scrolling a page) --
/// and the caller then speaks the changed rows as it always has.
struct ScreenNarrator {
    enum Mode: Equatable {
        case normal, insert, replace, visual, terminal

        var spoken: String {
            switch self {
            case .normal: return "Normal mode"
            case .insert: return "Insert mode"
            case .replace: return "Replace mode"
            case .visual: return "Visual mode"
            case .terminal: return "Terminal mode"
            }
        }
    }

    /// What is spoken: everything, or only the mode and the last row's messages, for when
    /// VoiceOver is reading the cursor itself and a second voice would talk over it.
    enum Scope { case everything, modesAndMessages }
    var scope: Scope = .everything
    /// Say each symbol by name in a word or line. A single character always is.
    var speaksSymbols = true

    /// How a change of indentation is made known when a whole line is read.
    enum Indentation: String { case off, tones, spoken }
    var indentation: Indentation = .spoken
    /// A run of this many identical symbols, or more, is said as a count ("10 hash"). 0 is off.
    var repeatThreshold = 4
    /// The indentation to sound a tone for after the last `narrate`, in columns, or nil.
    private(set) var lastTone: Int?
    /// The indentation of the last non-blank line read, to say when it changes.
    private var lastIndent = 0
    /// The command line being edited: what kind, its text and the cursor in it.
    private struct CommandLine { var kind: Character; var text: [Character]; var offset: Int }
    private var command: CommandLine?

    private(set) var mode: Mode = .normal
    /// Whether a `-- INSERT --` style marker has ever been seen. A vim with `noshowmode`
    /// never shows one, and then the mode is unknown rather than normal.
    private var modeKnown = false
    private var previous: ScreenFrame?
    private var hiddenFrames = 0

    mutating func reset() {
        self = ScreenNarrator()
    }

    mutating func narrate(_ frame: ScreenFrame) -> [String]? {
        lastTone = nil
        guard let last = frame.rows.indices.last,
              frame.cursorRow >= 0, frame.cursorRow < frame.rows.count else { return nil }

        // A program that hides its cursor for good (htop) is not about a cursor. One that
        // hides it for the length of a repaint (nvim) is: wait a few frames to tell them
        // apart rather than reading a half-drawn screen as text changes.
        if !frame.cursorVisible {
            hiddenFrames += 1
            return (previous != nil && hiddenFrames < 3) ? [] : nil
        }
        hiddenFrames = 0
        defer { previous = frame }
        guard let before = previous, before.rows.count == frame.rows.count else { return [] }

        var spoken: [String] = []

        // Mode. The last row says it, or is blank in normal mode; anything else on it is a
        // message or a command line, which says nothing new about the mode.
        let lastRow = frame.rows[last]
        if let marked = Self.mode(in: lastRow) {
            modeKnown = true
            if marked != mode { mode = marked; spoken.append(marked.spoken) }
        } else if modeKnown, lastRow.trimmingCharacters(in: .whitespaces).isEmpty, mode != .normal {
            mode = .normal
            spoken.append(Mode.normal.spoken)
        }

        let cursorMoved = before.cursorRow != frame.cursorRow || before.cursorCol != frame.cursorCol

        // Rows other than the cursor's and the last that changed. Several of them while the
        // cursor stays put on a row that did not change is a page turning (a pager, with its
        // cursor on the prompt), not an edit: leave that to the row diff. An edit that
        // shifts the lines (dd) changes the cursor's own row, and is read below.
        if !cursorMoved, before.rows[frame.cursorRow] == frame.rows[frame.cursorRow] {
            var changed = 0
            for row in 0..<last where row != frame.cursorRow && before.rows[row] != frame.rows[row] {
                changed += 1
            }
            if changed >= 2 { return nil }
        }

        // The command line is the cursor's home while a command is being typed, and it is an
        // editable line like any other: entering it is said, moving and deleting in it are
        // read, typing is key echo's to say, and what it does is read once the cursor is back.
        if frame.cursorRow == last, Self.isCommandLine(lastRow) {
            let chars = Array(lastRow)
            var text = Array(chars.dropFirst())
            let offset = max(0, frame.cursorCol - 1)
            // The row is trimmed, so blanks typed at the end are not in it.
            while text.count < offset { text.append(" ") }
            if let was = command, was.kind == chars[0] {
                if scope == .everything {
                    spoken += commandEdit(from: was, to: text, at: offset)
                }
            } else {
                spoken.append(Self.commandKind(chars[0]))
            }
            command = CommandLine(kind: chars[0], text: text, offset: offset)
            return spoken
        }
        command = nil

        // A message: the last row changed, and the cursor is not in it. What is right-aligned
        // there (the ruler, pending keys) changes with every move and is not a message.
        if frame.cursorRow != last {
            let now = Self.message(in: lastRow, cols: frame.cols)
            if now != Self.message(in: before.rows[last], cols: before.cols),
               !now.isEmpty, Self.mode(in: lastRow) == nil {
                spoken.append(phrase(now))
            }
        }

        if scope == .modesAndMessages { return spoken }

        // Where the cursor is.
        let was = Self.logicalLine(in: before)
        let now = Self.logicalLine(in: frame)
        let sameLine = was.start == now.start && was.text == now.text
        let oldChars = Array(was.text), newChars = Array(now.text)

        if sameLine {
            let delta = abs(now.offset - was.offset)
            if delta == 1 {
                spoken.append(Self.character(at: now.offset, in: newChars))
            } else if delta > 1 {
                spoken.append(phrase(Self.word(at: now.offset, in: newChars)))
            }
        } else if was.start == now.start {
            // The same line with different text: typing, or an edit at the cursor.
            if Self.typedSilently(from: oldChars, at: was.offset,
                                  to: newChars, at: now.offset,
                                  mode: modeKnown ? mode : nil) {
                // Key echo's to say.
            } else if Self.editedAtCursor(from: oldChars, to: newChars, at: now.offset),
                      !before.rows.contains(frame.rows[frame.cursorRow]) {
                spoken.append(abs(oldChars.count - newChars.count) == 1 || oldChars.count == newChars.count
                              ? Self.character(at: now.offset, in: newChars)
                              : phrase(Self.word(at: now.offset, in: newChars)))
            } else {
                spoken.append(lineUtterance(now.text))
            }
        } else {
            spoken.append(lineUtterance(now.text))
        }
        return spoken
    }

    // MARK: - Saying things

    /// `text` as it is spoken: symbols by name, long runs of one symbol as a count.
    func phrase(_ text: String) -> String {
        SymbolSpeller.spoken(text, names: speaksSymbols, repeatThreshold: repeatThreshold)
    }

    /// A whole line, with its indentation made known when it differs from the last line read:
    /// "indent 4", or a tone chosen by `indentation`. A blank line says so and changes nothing.
    mutating func lineUtterance(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "blank" }
        let indent = text.prefix { $0 == " " }.count
        var prefix = ""
        switch indentation {
        case .spoken:
            if indent != lastIndent { prefix = indent == 0 ? "no indent, " : "indent \(indent), " }
        case .tones:
            if indent > 0 { lastTone = indent }
        case .off:
            break
        }
        lastIndent = indent
        return prefix + phrase(String(text.drop { $0 == " " }))
    }

    static func commandKind(_ prefix: Character) -> String {
        switch prefix {
        case "/": return "Search forward"
        case "?": return "Search backward"
        default: return "Command"
        }
    }

    /// What editing the command line from `was` to `text` says. Typing is silent. Moving
    /// says the character or word crossed, deleting says what went, and a text that was
    /// rewritten (history, completion) is read whole.
    private func commandEdit(from was: CommandLine, to text: [Character], at offset: Int) -> [String] {
        let old = was.text
        if old == text {
            let delta = abs(offset - was.offset)
            if delta == 1 { return [Self.character(at: offset, in: text)] }
            if delta > 1 { return [phrase(Self.word(at: offset, in: text))] }
            return []
        }
        // Deleted before the cursor (backspace, Ctrl-W, Ctrl-U) or at it (forward delete).
        let removed = old.count - text.count
        if removed > 0, offset <= was.offset {
            let from = offset < was.offset ? offset : was.offset
            let to = from + removed
            if to <= old.count,
               Array(old[..<from]) == Array(text[..<min(from, text.count)]),
               Array(old[to...]) == Array(text[min(from, text.count)...]) {
                let gone = Array(old[from..<to])
                return [gone.count == 1 ? Self.character(at: 0, in: gone) : phrase(String(gone))]
            }
        }
        if Self.typedSilently(from: old, at: was.offset, to: text, at: offset, mode: .insert) { return [] }
        let whole = String(text)
        return [whole.trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : phrase(whole)]
    }

    /// The line, word and character at the cursor of a frame, said the way the narrator would,
    /// for the commands that read them again on request. Indentation is always said when there
    /// is some, whatever was read last.
    func reading(of frame: ScreenFrame) -> (line: String, word: String, character: String, tone: Int?) {
        var copy = self
        copy.lastIndent = 0
        guard frame.cursorRow >= 0, frame.cursorRow < frame.rows.count else { return ("blank", "blank", "blank", nil) }
        let lastRow = frame.rows[frame.rows.count - 1]
        var text: [Character]
        var offset: Int
        var line: String
        if frame.cursorRow == frame.rows.count - 1, Self.isCommandLine(lastRow) {
            text = Array(lastRow.dropFirst())
            offset = max(0, frame.cursorCol - 1)
            line = Self.commandKind(lastRow.first ?? ":") + ", " + String(text)
            line = text.isEmpty ? Self.commandKind(lastRow.first ?? ":") : copy.phrase(line)
        } else {
            let logical = Self.logicalLine(in: frame)
            text = Array(logical.text)
            offset = logical.offset
            line = copy.lineUtterance(logical.text)
        }
        return (line, copy.phrase(Self.word(at: offset, in: text)),
                Self.character(at: offset, in: text), copy.lastTone)
    }

    // MARK: - Reading the screen

    /// The line the cursor is on, as the program drew it: wrapped rows joined, and a
    /// line-number gutter (`set number`) left off.
    struct LogicalLine {
        var start: Int
        var text: String
        /// The cursor's position in `text`, in characters.
        var offset: Int
    }

    static func logicalLine(in frame: ScreenFrame) -> LogicalLine {
        var start = frame.cursorRow
        while start > 0, frame.wrapped[start] { start -= 1 }
        var end = frame.cursorRow
        while end + 1 < frame.rows.count - 1, frame.wrapped[end + 1] { end += 1 }
        let gutter = gutterWidth(in: frame)
        var text = ""
        for row in start...end {
            let chars = Array(frame.rows[row])
            text += String(chars.dropFirst(min(gutter, chars.count)))
        }
        let rowWidth = max(1, frame.cols - gutter)
        let offset = max(0, (frame.cursorRow - start) * rowWidth + frame.cursorCol - gutter)
        // The row diff only trims the end, so a line is its text minus trailing blanks
        // unless the cursor is past them (insert mode at the end of a line).
        var trimmed = text
        while trimmed.hasSuffix(" "), trimmed.count > offset { trimmed.removeLast() }
        return LogicalLine(start: start, text: trimmed, offset: offset)
    }

    /// Width of the number column, or 0. A number column is right-aligned digits and a space,
    /// at least four wide, on most of the rows with text on them, and always the same width.
    static func gutterWidth(in frame: ScreenFrame) -> Int {
        var widths: [Int] = []
        var texted = 0
        for row in frame.rows.dropLast() {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "~" || trimmed == "@" { continue }
            texted += 1
            let chars = Array(row)
            var index = 0
            while index < chars.count, chars[index] == " " { index += 1 }
            let digits = index
            while index < chars.count, chars[index].isASCII, chars[index].isNumber { index += 1 }
            guard index > digits, index >= 3, index < chars.count, chars[index] == " " else { continue }
            widths.append(index + 1)
        }
        guard let width = widths.first, widths.count >= 2, widths.count * 10 >= texted * 6,
              widths.allSatisfy({ $0 == width }) else { return 0 }
        return width
    }

    // MARK: - Modes and messages

    static func mode(in row: String) -> Mode? {
        if row.contains("-- INSERT --") || row.contains("-- (insert)") { return .insert }
        if row.contains("-- REPLACE --") || row.contains("-- VREPLACE --") { return .replace }
        if row.contains("-- VISUAL") || row.contains("-- SELECT") { return .visual }
        if row.contains("-- TERMINAL --") { return .terminal }
        return nil
    }

    static func isCommandLine(_ row: String) -> Bool {
        guard let first = row.first else { return false }
        return first == ":" || first == "/" || first == "?"
    }

    /// The left-aligned part of the last row. vim draws pending keys and the ruler in the
    /// last 30 columns or so, after blanks; those are not part of a message.
    static func message(in row: String, cols: Int) -> String {
        let chars = Array(row)
        let cut = max(0, cols - 30)
        if chars.count > cut, cut == 0 || chars[cut - 1] == " " {
            return String(chars.prefix(cut)).trimmingCharacters(in: .whitespaces)
        }
        return row.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Edits

    /// Characters typed at the cursor, or deleted before it, are silent. In insert and
    /// replace mode that is anything of the kind; when the mode is not known, only a single
    /// character, so that `p` of a word is still read.
    static func typedSilently(from old: [Character], at oldOffset: Int,
                              to new: [Character], at newOffset: Int, mode: Mode?) -> Bool {
        let typing = mode == .insert || mode == .replace
        if newOffset > oldOffset {
            let n = newOffset - oldOffset
            guard typing || (mode == nil && n == 1), oldOffset <= old.count else { return false }
            // Inserted.
            if new.count == old.count + n,
               Array(new[..<oldOffset]) == Array(old[..<oldOffset]),
               Array(new[(oldOffset + n)...]) == Array(old[oldOffset...]) { return true }
            // Typed over (replace mode, or overstrike).
            if new.count == old.count, newOffset <= new.count,
               Array(new[..<oldOffset]) == Array(old[..<oldOffset]),
               Array(new[newOffset...]) == Array(old[min(newOffset, old.count)...]) { return true }
        } else if newOffset < oldOffset {
            let n = oldOffset - newOffset
            guard typing, new.count == old.count - n, oldOffset <= old.count else { return false }
            if Array(new[..<newOffset]) == Array(old[..<newOffset]),
               Array(new[newOffset...]) == Array(old[oldOffset...]) { return true }
        }
        return false
    }

    /// An edit that starts at the cursor and leaves the rest of the line alone: x, dw, r.
    static func editedAtCursor(from old: [Character], to new: [Character], at offset: Int) -> Bool {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let shortest = min(old.count, new.count)
        return prefix >= offset && prefix + suffix >= shortest - 1 && max(old.count, new.count) > 2
    }

    // MARK: - Words

    static func line(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? "blank" : text
    }

    static func character(at offset: Int, in chars: [Character]) -> String {
        guard offset < chars.count, chars[offset] != " " else { return "space" }
        return SymbolSpeller.name(of: chars[offset]) ?? String(chars[offset])
    }

    private enum Kind { case word, space, punctuation }

    private static func kind(_ c: Character) -> Kind {
        if c == " " || c == "\t" { return .space }
        if c.isLetter || c.isNumber || c == "_" { return .word }
        return .punctuation
    }

    /// The word the cursor is on, the way vim's `w` sees it: a run of word characters, or a
    /// run of other characters. A blank is "space".
    static func word(at offset: Int, in chars: [Character]) -> String {
        guard offset < chars.count, kind(chars[offset]) != .space else { return "space" }
        let k = kind(chars[offset])
        var start = offset, end = offset
        while start > 0, kind(chars[start - 1]) == k { start -= 1 }
        while end + 1 < chars.count, kind(chars[end + 1]) == k { end += 1 }
        return String(chars[start...end])
    }
}

/// Spoken names for symbols. An announcement is read at VoiceOver's own punctuation level,
/// which leaves most of these out; reading code needs every one.
enum SymbolSpeller {
    private static let names: [Character: String] = [
        "!": "bang", "\"": "quote", "#": "hash", "$": "dollar", "%": "percent", "&": "ampersand",
        "'": "apostrophe", "(": "open paren", ")": "close paren", "*": "star", "+": "plus",
        ",": "comma", "-": "dash", ".": "dot", "/": "slash", ":": "colon", ";": "semicolon",
        "<": "less than", "=": "equals", ">": "greater than", "?": "question mark", "@": "at",
        "[": "open bracket", "\\": "backslash", "]": "close bracket", "^": "caret",
        "_": "underscore", "`": "backtick", "{": "open brace", "|": "pipe", "}": "close brace",
        "~": "tilde", "\t": "tab",
        "\u{2018}": "left quote", "\u{2019}": "right quote", "\u{201C}": "left double quote",
        "\u{201D}": "right double quote", "\u{2013}": "en dash", "\u{2014}": "em dash",
        "\u{2026}": "ellipsis", "\u{2192}": "right arrow", "\u{2190}": "left arrow",
        "\u{00A3}": "pound", "\u{20AC}": "euro", "\u{00B0}": "degrees", "\u{2022}": "bullet",
    ]

    /// The spoken name of a symbol, or nil for a letter, a digit or a blank.
    static func name(of character: Character) -> String? { names[character] }

    /// `text` with every symbol replaced by its name, set off by spaces. Leading blanks, the
    /// indentation, are dropped: a number of spaces is not worth saying.
    static func spoken(_ text: String) -> String {
        spoken(text, names: true, repeatThreshold: 0)
    }

    /// `names` says each symbol by name; `repeatThreshold`, when above 0, says a run of that
    /// many identical symbols or more as a count and one name: "10 hash", or "10 #" when
    /// names are off. Letters, digits and blanks are never counted.
    static func spoken(_ text: String, names useNames: Bool, repeatThreshold: Int) -> String {
        guard useNames || repeatThreshold > 0 else { return text }
        let characters = Array(text)
        var out = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            var end = index
            while end + 1 < characters.count, characters[end + 1] == character { end += 1 }
            let run = end - index + 1
            let isSymbol = !(character.isLetter || character.isNumber || character.isWhitespace)
            if isSymbol, repeatThreshold > 0, run >= repeatThreshold {
                out += " \(run) \(useNames ? (names[character] ?? String(character)) : String(character)) "
            } else {
                for _ in 0..<run {
                    if useNames, let name = names[character], character != "\t" {
                        out += " \(name) "
                    } else {
                        out.append(character)
                    }
                }
            }
            index = end + 1
        }
        return out.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
