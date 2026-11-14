import Foundation

/// vi-style modal editing for a single line, with no UI in it: the command line gives it keys
/// and its text and caret, and gets back what to say. It starts in insert mode, which is what
/// the line already is, so nothing changes until Escape is pressed.
///
/// What it knows: counts (`3w`, `2x`), the motions `h l 0 ^ $ w b e W B E f F t T ; ,`, the
/// operators `d c y` with those motions or doubled for the whole line, `x X D C s S Y`,
/// `i a I A`, `r`, `~`, `p P`, `u` and Control-R, and `j k` as history down and up. Visual
/// mode, `.`, marks and searches are not here; a line of a command does not call for them.
///
/// The line is a single line, so everything is character-wise, and `cw` works like `ce` the
/// way it does in vi.
struct ViLineEditor {
    enum Mode: Equatable { case insert, normal }

    /// What the caller should do about a key.
    enum Effect: Equatable {
        /// Text the caret landed on, said as the command line says any text.
        case say(String)
        /// Said as it is.
        case message(String)
        case deleted(String)
        case yanked(String)
        case pasted(String)
        /// `j` and `k`: the shell's history, newer and older.
        case history(older: Bool)
        /// A key that does nothing here.
        case invalid
    }

    private(set) var mode: Mode = .insert
    /// What `d`, `c`, `y`, `x` and friends last took, for `p`.
    private(set) var register = ""

    private var count = ""
    private var operatorKey: Character?
    private var operatorCount: Int?
    /// A key that waits for the character after it: `f F t T r`.
    private var awaiting: Character?
    private var lastFind: (key: Character, target: Character)?

    private struct Snapshot { var text: [Character]; var caret: Int }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// Whether the next insert-mode edit starts a new undoable change.
    private var insertNeedsCheckpoint = true

    mutating func reset() {
        self = ViLineEditor()
    }

    // MARK: - Insert mode

    /// Called before any edit made in insert mode, so a stretch of typing is one undo step.
    mutating func noteInsertEdit(text: [Character], caret: Int) {
        guard insertNeedsCheckpoint else { return }
        insertNeedsCheckpoint = false
        checkpoint(text, caret)
    }

    /// Escape: leaves insert mode with the caret on the character before it, as vi does, or
    /// cancels a half-typed command in normal mode.
    mutating func escape(text: [Character], caret: inout Int) -> [Effect] {
        if mode == .insert {
            mode = .normal
            insertNeedsCheckpoint = true
            caret = max(0, min(caret - 1, text.count - 1))
            return [.message("Normal mode")]
        }
        clearPending()
        return []
    }

    /// The caret may sit past the last character only in insert mode.
    func clamped(_ caret: Int, in text: [Character]) -> Int {
        guard mode == .normal else { return caret }
        return max(0, min(caret, text.count - 1))
    }

    // MARK: - Normal mode

    mutating func normal(_ key: Character, text: inout [Character], caret: inout Int) -> [Effect] {
        if let waiting = awaiting {
            awaiting = nil
            return finish(waiting: waiting, with: key, text: &text, caret: &caret)
        }

        if key.isASCII, key.isNumber, key != "0" || !count.isEmpty {
            count.append(key)
            return []
        }
        let typed = Int(count)
        count = ""

        // An operator waiting for its motion.
        if let op = operatorKey {
            if key == op { // dd, cc, yy: the whole line
                clearPending()
                return apply(op, from: 0, to: text.count, text: &text, caret: &caret)
            }
            if "fFtT".contains(key) {
                operatorCount = (operatorCount ?? 1) * (typed ?? 1)
                awaiting = key
                return []
            }
            let total = (operatorCount ?? 1) * (typed ?? 1)
            clearPending()
            guard let motion = motion(key, count: total, text: text, caret: caret, forOperator: op) else {
                return [.invalid]
            }
            return apply(op, range: motion, text: &text, caret: &caret)
        }

        let n = typed ?? 1
        switch key {
        // Motions.
        case "h", "l", "0", "^", "$", "w", "b", "e", "W", "B", "E", ";", ",":
            guard let target = motion(key, count: n, text: text, caret: caret, forOperator: nil) else {
                return [.invalid]
            }
            return move(to: target.end, key: key, text: text, caret: &caret)
        case "f", "F", "t", "T", "r":
            operatorCount = typed
            awaiting = key
            return []

        // Operators.
        case "d", "c", "y":
            operatorKey = key
            operatorCount = typed
            return []
        case "x": return apply("d", from: caret, to: min(text.count, caret + n), text: &text, caret: &caret)
        case "X": return apply("d", from: max(0, caret - n), to: caret, text: &text, caret: &caret)
        case "D": return apply("d", from: caret, to: text.count, text: &text, caret: &caret)
        case "C": return apply("c", from: caret, to: text.count, text: &text, caret: &caret)
        case "s": return apply("c", from: caret, to: min(text.count, caret + n), text: &text, caret: &caret)
        case "S": return apply("c", from: 0, to: text.count, text: &text, caret: &caret)
        case "Y": return apply("y", from: 0, to: text.count, text: &text, caret: &caret)

        // Into insert mode.
        case "i": return insert(at: caret, text: text, caret: &caret)
        case "a": return insert(at: text.isEmpty ? 0 : caret + 1, text: text, caret: &caret)
        case "I":
            return insert(at: firstNonBlank(text), text: text, caret: &caret)
        case "A": return insert(at: text.count, text: text, caret: &caret)

        // Changes.
        case "~": return toggleCase(count: n, text: &text, caret: &caret)
        case "p", "P": return put(before: key == "P", count: n, text: &text, caret: &caret)
        case "u": return undo(text: &text, caret: &caret)
        case "\u{12}": return redo(text: &text, caret: &caret)

        // History, which is the shell's own.
        case "j": return [.history(older: false)]
        case "k": return [.history(older: true)]

        default:
            return [.invalid]
        }
    }

    // MARK: - Commands

    private mutating func clearPending() {
        count = ""
        operatorKey = nil
        operatorCount = nil
        awaiting = nil
    }

    private mutating func checkpoint(_ text: [Character], _ caret: Int) {
        undoStack.append(Snapshot(text: text, caret: caret))
        redoStack.removeAll()
    }

    /// A motion's reach: where the caret goes, and whether the character there is part of a
    /// range taken by an operator.
    private struct Motion { var end: Int; var inclusive: Bool }

    private mutating func finish(waiting: Character, with key: Character,
                                 text: inout [Character], caret: inout Int) -> [Effect] {
        let op = operatorKey
        let total = (operatorCount ?? 1)
        operatorCount = nil
        operatorKey = nil
        if waiting == "r" {
            guard !text.isEmpty, caret + total <= text.count else { return [.invalid] }
            checkpoint(text, caret)
            for offset in 0..<total { text[caret + offset] = key }
            caret += total - 1
            return [.say(String(key))]
        }
        lastFind = (waiting, key)
        guard let motion = find(waiting, key, count: total, text: text, caret: caret) else {
            return [.message("not found")]
        }
        if let op { return apply(op, range: motion, text: &text, caret: &caret) }
        return move(to: motion.end, key: waiting, text: text, caret: &caret)
    }

    private mutating func move(to target: Int, key: Character, text: [Character],
                               caret: inout Int) -> [Effect] {
        let landed = max(0, min(target, text.count - 1))
        guard landed != caret else {
            return [.message("hbB0^FT,".contains(key) ? "start of line" : "end of line")]
        }
        caret = landed
        guard !text.isEmpty else { return [] }
        if "wbeWBE".contains(key) {
            return [.say(wordText(at: landed, in: text, big: key.isUppercase))]
        }
        return [.say(String(text[landed]))]
    }

    /// Applies an operator to the half-open range, in characters.
    private mutating func apply(_ op: Character, range motion: Motion,
                                text: inout [Character], caret: inout Int) -> [Effect] {
        var low = min(caret, motion.end)
        var high = max(caret, motion.end)
        if motion.inclusive, motion.end >= caret { high += 1 }
        low = max(0, low)
        high = min(text.count, high)
        return apply(op, from: low, to: high, text: &text, caret: &caret)
    }

    private mutating func apply(_ op: Character, from low: Int, to high: Int,
                                text: inout [Character], caret: inout Int) -> [Effect] {
        guard high > low, low >= 0, high <= text.count else {
            if op == "c" { return insert(at: caret, text: text, caret: &caret) }
            return [.message(text.isEmpty ? "empty" : "nothing")]
        }
        let taken = String(text[low..<high])
        register = taken
        switch op {
        case "y":
            caret = low
            return [.yanked(taken)]
        case "d":
            checkpoint(text, caret)
            text.removeSubrange(low..<high)
            caret = clamped(low, in: text)
            return [.deleted(taken)]
        default: // "c"
            checkpoint(text, caret)
            text.removeSubrange(low..<high)
            mode = .insert
            insertNeedsCheckpoint = false
            caret = low
            return [.deleted(taken), .message("Insert mode")]
        }
    }

    private mutating func insert(at position: Int, text: [Character], caret: inout Int) -> [Effect] {
        mode = .insert
        insertNeedsCheckpoint = true
        caret = max(0, min(position, text.count))
        return [.message("Insert mode")]
    }

    private mutating func toggleCase(count: Int, text: inout [Character], caret: inout Int) -> [Effect] {
        guard !text.isEmpty else { return [.invalid] }
        checkpoint(text, caret)
        let end = min(text.count, caret + count)
        for index in caret..<end {
            let c = text[index]
            let flipped = c.isUppercase ? c.lowercased() : c.uppercased()
            if flipped.count == 1, let first = flipped.first { text[index] = first }
        }
        caret = clamped(end, in: text)
        return [.say(String(text[max(0, min(end - 1, text.count - 1))]))]
    }

    private mutating func put(before: Bool, count: Int, text: inout [Character],
                              caret: inout Int) -> [Effect] {
        guard !register.isEmpty else { return [.message("nothing to paste")] }
        checkpoint(text, caret)
        let pasted = Array(String(repeating: register, count: count))
        let at = before || text.isEmpty ? caret : caret + 1
        text.insert(contentsOf: pasted, at: min(at, text.count))
        caret = at + pasted.count - 1
        return [.pasted(register)]
    }

    private mutating func undo(text: inout [Character], caret: inout Int) -> [Effect] {
        guard let last = undoStack.popLast() else { return [.message("already at oldest change")] }
        redoStack.append(Snapshot(text: text, caret: caret))
        text = last.text
        caret = clamped(last.caret, in: text)
        return [.message("undone")]
    }

    private mutating func redo(text: inout [Character], caret: inout Int) -> [Effect] {
        guard let next = redoStack.popLast() else { return [.message("already at newest change")] }
        undoStack.append(Snapshot(text: text, caret: caret))
        text = next.text
        caret = clamped(next.caret, in: text)
        return [.message("redone")]
    }

    // MARK: - Motions

    private func motion(_ key: Character, count n: Int, text: [Character], caret: Int,
                        forOperator op: Character?) -> Motion? {
        let last = max(0, text.count - 1)
        switch key {
        case "h": return Motion(end: max(0, caret - n), inclusive: false)
        case "l": return Motion(end: min(op == nil ? last : text.count, caret + n), inclusive: false)
        case "0": return Motion(end: 0, inclusive: false)
        case "^": return Motion(end: firstNonBlank(text), inclusive: false)
        case "$": return Motion(end: last, inclusive: true)
        case "w", "W":
            let big = key == "W"
            // cw is ce, unless the caret is on a blank.
            if op == "c", caret < text.count, !isBlank(text[caret]) {
                var end = caret
                for step in 0..<n { end = wordEnd(from: step == 0 ? caret - 1 : end, in: text, big: big) }
                return Motion(end: end, inclusive: true)
            }
            var end = caret
            for _ in 0..<n { end = nextWordStart(from: end, in: text, big: big) }
            return Motion(end: op == nil ? min(end, last) : end, inclusive: false)
        case "b", "B":
            var end = caret
            for _ in 0..<n { end = previousWordStart(from: end, in: text, big: key == "B") }
            return Motion(end: end, inclusive: false)
        case "e", "E":
            var end = caret
            for _ in 0..<n { end = wordEnd(from: end, in: text, big: key == "E") }
            return Motion(end: end, inclusive: true)
        case ";", ",":
            guard let again = lastFind else { return nil }
            var kind = again.key
            if key == "," { kind = kind.isUppercase ? Character(kind.lowercased()) : Character(kind.uppercased()) }
            return find(kind, again.target, count: n, text: text, caret: caret)
        default:
            return nil
        }
    }

    /// `f x` and its kin. `t` and `T` stop one short.
    private func find(_ kind: Character, _ target: Character, count n: Int,
                      text: [Character], caret: Int) -> Motion? {
        let forward = kind == "f" || kind == "t"
        var position = caret
        for _ in 0..<n {
            var next = position + (forward ? 1 : -1)
            while next >= 0, next < text.count, text[next] != target { next += forward ? 1 : -1 }
            guard next >= 0, next < text.count else { return nil }
            position = next
        }
        if kind == "t" { position -= 1 } else if kind == "T" { position += 1 }
        return Motion(end: position, inclusive: forward)
    }

    // MARK: - Words

    private enum Class { case blank, word, punctuation }

    private func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }

    private func kind(_ c: Character, big: Bool) -> Class {
        if isBlank(c) { return .blank }
        if big { return .word }
        return c.isLetter || c.isNumber || c == "_" ? .word : .punctuation
    }

    private func firstNonBlank(_ text: [Character]) -> Int {
        text.firstIndex { !isBlank($0) } ?? max(0, text.count - 1)
    }

    private func nextWordStart(from index: Int, in text: [Character], big: Bool) -> Int {
        var j = index
        if j < text.count {
            let k = kind(text[j], big: big)
            if k != .blank { while j < text.count, kind(text[j], big: big) == k { j += 1 } }
        }
        while j < text.count, kind(text[j], big: big) == .blank { j += 1 }
        return j
    }

    private func previousWordStart(from index: Int, in text: [Character], big: Bool) -> Int {
        guard !text.isEmpty else { return 0 }
        var j = min(index, text.count) - 1
        while j > 0, kind(text[j], big: big) == .blank { j -= 1 }
        guard j > 0 else { return 0 }
        let k = kind(text[j], big: big)
        while j > 0, kind(text[j - 1], big: big) == k { j -= 1 }
        return j
    }

    private func wordEnd(from index: Int, in text: [Character], big: Bool) -> Int {
        var j = index + 1
        while j < text.count, kind(text[j], big: big) == .blank { j += 1 }
        guard j < text.count else { return max(0, text.count - 1) }
        let k = kind(text[j], big: big)
        while j + 1 < text.count, kind(text[j + 1], big: big) == k { j += 1 }
        return j
    }

    /// The run of characters of one kind the caret is on, which is what `w` just landed on.
    private func wordText(at index: Int, in text: [Character], big: Bool) -> String {
        guard index < text.count else { return "" }
        let k = kind(text[index], big: big)
        guard k != .blank else { return "space" }
        var start = index, end = index
        while start > 0, kind(text[start - 1], big: big) == k { start -= 1 }
        while end + 1 < text.count, kind(text[end + 1], big: big) == k { end += 1 }
        return String(text[start...end])
    }
}
