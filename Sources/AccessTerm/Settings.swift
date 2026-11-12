import Foundation

/// The few settings that are remembered between launches. Everything else in the app is
/// per launch (Speak Output, for one); these are the ones someone sets once for how they use
/// full-screen programs, and would otherwise have to set again every time.
enum Settings {
    /// Who reads the cursor in a full-screen program.
    enum FullScreenReading: String {
        /// AccessTerm announces what the cursor lands on (ScreenNarrator).
        case announce
        /// VoiceOver reads the cursor itself, from the screen exposed as a text area: its
        /// own punctuation level, indentation tones and read-line, read-word commands.
        case voiceOver
    }

    static var defaults = UserDefaults.standard

    private static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    /// Narrate full-screen programs by cursor position. Off, they are spoken as rows change.
    static var trackCursor: Bool {
        get { bool("trackCursor", default: true) }
        set { defaults.set(newValue, forKey: "trackCursor") }
    }

    static var fullScreenReading: FullScreenReading {
        get { defaults.string(forKey: "fullScreenReading").flatMap(FullScreenReading.init) ?? .announce }
        set { defaults.set(newValue.rawValue, forKey: "fullScreenReading") }
    }

    /// Say every symbol by name when announcing the cursor, for programming.
    static var speakSymbols: Bool {
        get { bool("speakSymbols", default: true) }
        set { defaults.set(newValue, forKey: "speakSymbols") }
    }

    /// Say "Attention" for the bell in a full-screen program. Off, the bell is the beep alone:
    /// an editor rings it at every edge of the text.
    static var speakBellInFullScreen: Bool {
        get { bool("speakBellInFullScreen", default: false) }
        set { defaults.set(newValue, forKey: "speakBellInFullScreen") }
    }

    /// How a change of indentation is made known when announcing a line.
    static var indentation: ScreenNarrator.Indentation {
        get { defaults.string(forKey: "indentation").flatMap(ScreenNarrator.Indentation.init) ?? .spoken }
        set { defaults.set(newValue.rawValue, forKey: "indentation") }
    }

    /// A run of this many identical symbols or more is said as a count. 0 is off.
    static var repeatThreshold: Int {
        get { defaults.object(forKey: "repeatThreshold") as? Int ?? 4 }
        set { defaults.set(max(0, newValue), forKey: "repeatThreshold") }
    }

    /// vi-style modal editing on the command line: Escape for normal mode, then motions and
    /// operators. Off, the line behaves exactly as it always has.
    static var viCommandLine: Bool {
        get { bool("viCommandLine", default: false) }
        set { defaults.set(newValue, forKey: "viCommandLine") }
    }
}
