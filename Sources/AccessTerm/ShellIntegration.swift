import Foundation

/// Gets zsh to report where commands start and end, without anyone editing their dotfiles.
///
/// zsh reads .zshenv, .zprofile, .zshrc and .zlogin from $ZDOTDIR, so the app writes a
/// directory of its own and launches the shell with ZDOTDIR pointing at it. Each file there
/// sources the user's own first, so nothing they have set up is lost, and ZDOTDIR is put back
/// to their value at the end of .zshrc so anything they run afterwards sees the real one.
///
/// What the app adds is four OSC 133 markers: A before the prompt, B where the command will
/// be typed, C when it starts running, and D with its exit code when it finishes. The
/// terminal treats them as invisible; TerminalSession turns them into command blocks. Claude
/// Code's screen reader mode emits the same markers itself, so a session attached to it is
/// structured whether or not the shell cooperates.
enum ShellIntegration {

    /// Writes the directory and returns it, or nil if it could not be written -- in which case
    /// the shell is launched without it and the transcript is one unstructured block.
    static func prepareZDotDir() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true) else { return nil }
        let directory = support.appendingPathComponent("AccessTerm/zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in files {
                try contents.write(to: directory.appendingPathComponent(name),
                                   atomically: true, encoding: .utf8)
            }
        } catch {
            return nil
        }
        return directory
    }

    /// Rewritten on every launch, so a change here reaches an existing install.
    private static var files: [String: String] {
        [".zshenv": zshenv, ".zprofile": sourcingUserFile(".zprofile"),
         ".zlogin": sourcingUserFile(".zlogin"), ".zshrc": zshrc]
    }

    private static let header = """
    # Written by AccessTerm on every launch. Edits here are overwritten -- edit your own
    # dotfiles instead, which this sources.

    """

    /// Runs first, and is the file that works out where the user's own dotfiles are. Their
    /// .zshenv may set ZDOTDIR itself, in which case that is their real one from then on.
    private static let zshenv = header + """
    ACCESSTERM_USER_ZDOTDIR="${ACCESSTERM_USER_ZDOTDIR:-${ZDOTDIR:-$HOME}}"
    export ACCESSTERM_USER_ZDOTDIR
    if [[ -f "$ACCESSTERM_USER_ZDOTDIR/.zshenv" ]]; then
        ZDOTDIR="$ACCESSTERM_USER_ZDOTDIR"
        source "$ACCESSTERM_USER_ZDOTDIR/.zshenv"
        ACCESSTERM_USER_ZDOTDIR="${ZDOTDIR:-$ACCESSTERM_USER_ZDOTDIR}"
    fi
    # Back to ours, so the rest of zsh's startup files are the ones with the markers in.
    ZDOTDIR="$ACCESSTERM_ZDOTDIR"
    """

    private static func sourcingUserFile(_ name: String) -> String {
        header + """
        [[ -f "$ACCESSTERM_USER_ZDOTDIR/\(name)" ]] && source "$ACCESSTERM_USER_ZDOTDIR/\(name)"
        ZDOTDIR="$ACCESSTERM_ZDOTDIR"
        """
    }

    /// The user's own .zshrc, then the hooks. Deliberately last: their file is free to set
    /// PS1, install its own hooks, or load a theme, and this goes on top of the result.
    private static let zshrc = header + #"""
    [[ -f "$ACCESSTERM_USER_ZDOTDIR/.zshrc" ]] && source "$ACCESSTERM_USER_ZDOTDIR/.zshrc"

    # Their shell is set up now, so ZDOTDIR goes back to being theirs.
    ZDOTDIR="$ACCESSTERM_USER_ZDOTDIR"

    if [[ -o interactive ]]; then
        autoload -Uz add-zsh-hook

        __accessterm_precmd() {
            local exit_code=$?
            # D closes the command that has just finished, and only if one was running: the
            # first prompt of the session has nothing to report.
            if [[ -n ${__accessterm_running-} ]]; then
                printf '\e]133;D;%d\a' "$exit_code"
                unset __accessterm_running
            fi
            # B marks where the typed command starts, which is wherever the prompt ends, so it
            # rides on the end of PS1. Re-applied every time: themes rebuild PS1 as they go.
            # %{...%} keeps zsh from counting the escape sequence as prompt width.
            if [[ $PS1 != *$'\e]133;B\a'* ]]; then
                PS1="${PS1}"$'%{\e]133;B\a%}'
            fi
            printf '\e]133;A\a'
        }

        __accessterm_preexec() {
            typeset -g __accessterm_running=1
            printf '\e]133;C\a'
        }

        add-zsh-hook precmd __accessterm_precmd
        add-zsh-hook preexec __accessterm_preexec
    fi
    """#
}
