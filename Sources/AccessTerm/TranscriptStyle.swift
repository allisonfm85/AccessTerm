import Foundation

/// A color a program asked for, before the UI decides what it actually looks like.
enum TerminalColor: Equatable {
    /// The 256-color palette: 0-15 are the named colors, 16-231 the color cube,
    /// 232-255 the grays. The UI maps these to something legible on its background.
    case ansi(UInt8)
    /// 24-bit color, passed through as given.
    case rgb(UInt8, UInt8, UInt8)
}

/// A run of characters in one transcript line sharing one visual style.
///
/// Styles are decoration and nothing more (issue #4): the transcript's text is the record --
/// it is what is spoken, read, searched, copied and classified -- and none of that ever
/// depends on a run being present. A line with no runs is simply drawn in the default style,
/// which is also what happens when extraction cannot vouch for its ranges: misplaced color
/// could decorate the wrong characters, absent color cannot. Nothing here changes what
/// VoiceOver says.
struct StyleRun: Equatable {
    /// Where in the line's text, in UTF-16 units -- the units NSAttributedString addresses.
    var range: NSRange
    /// Foreground; nil means the default, i.e. no override.
    var color: TerminalColor?
    /// Background; nil means none.
    var background: TerminalColor?
    var bold = false
    var underline = false

    /// Whether the run would change anything visually. A run of defaults is not worth keeping.
    var isPlain: Bool {
        color == nil && background == nil && !bold && !underline
    }
}
