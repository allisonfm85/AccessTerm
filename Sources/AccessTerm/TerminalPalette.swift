import AppKit

/// The colors programs ask for, tuned to stay legible on the app's background in both light
/// and dark mode. Presentation only -- see StyleRun for why color never carries meaning.
///
/// The 16 named colors get hand-picked light/dark pairs, because the classic values ("yellow")
/// are unreadable on a white background and ("black") invisible on a dark one. The cube and
/// grays use the standard xterm values in both appearances; if any of those prove hard to
/// read for low-vision users, tuning them belongs here and nowhere else.
enum TerminalPalette {
    static func color(_ color: TerminalColor) -> NSColor {
        switch color {
        case .rgb(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255,
                           green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255,
                           alpha: 1)
        case .ansi(let code):
            return ansi(code)
        }
    }

    private static func ansi(_ code: UInt8) -> NSColor {
        if code < 16 { return named[Int(code)] }
        if code < 232 {
            // 6x6x6 cube; level 0 is 0, then 95, 135, ... (the xterm ramp).
            let index = Int(code) - 16
            let level = { (component: Int) -> CGFloat in
                component == 0 ? 0 : CGFloat(55 + 40 * component) / 255
            }
            return NSColor(srgbRed: level(index / 36),
                           green: level((index / 6) % 6),
                           blue: level(index % 6),
                           alpha: 1)
        }
        // Grayscale ramp, 8 to 238.
        let gray = CGFloat(8 + 10 * (Int(code) - 232)) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }

    /// One color that answers for both appearances, resolved at draw time so switching
    /// light/dark restyles existing text without repainting the transcript.
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return rgb(match == .darkAqua ? dark : light)
        }
    }

    private static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1)
    }

    /// The 16 named colors as light/dark pairs. "Black" and "white" are shades that remain
    /// visible against their own background rather than the literal values.
    private static let named: [NSColor] = [
        dynamic(light: 0x000000, dark: 0x666666), // 0 black
        dynamic(light: 0xc41a16, dark: 0xff6b60), // 1 red
        dynamic(light: 0x007400, dark: 0x59c964), // 2 green
        dynamic(light: 0x8f6f00, dark: 0xe5c07b), // 3 yellow
        dynamic(light: 0x0f4dbb, dark: 0x6a9fff), // 4 blue
        dynamic(light: 0xa90d91, dark: 0xd980d9), // 5 magenta
        dynamic(light: 0x0e7c8b, dark: 0x56c8d8), // 6 cyan
        dynamic(light: 0x777777, dark: 0xeeeeee), // 7 white
        dynamic(light: 0x555555, dark: 0x888888), // 8 bright black
        dynamic(light: 0xd13438, dark: 0xff8272), // 9 bright red
        dynamic(light: 0x128622, dark: 0x74d484), // 10 bright green
        dynamic(light: 0x9a7d00, dark: 0xf2d178), // 11 bright yellow
        dynamic(light: 0x2a6ee6, dark: 0x85b1ff), // 12 bright blue
        dynamic(light: 0xb73dae, dark: 0xe58ce5), // 13 bright magenta
        dynamic(light: 0x1290a4, dark: 0x76d9e6), // 14 bright cyan
        dynamic(light: 0x8c8c8c, dark: 0xffffff), // 15 bright white
    ]
}
