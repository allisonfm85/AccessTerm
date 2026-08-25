# AccessTerm (milestone 1)

A macOS terminal built for VoiceOver. Instead of one big text area that VoiceOver has to
interact with, output is presented as an append-only list of logical lines, with a separate
native text field for typing. Requires macOS 13 or later.

## Build and run

Everything is a Swift package, so no Xcode project file is needed.

From the command line (Xcode command line tools or Xcode installed):

    cd AccessTerm
    swift run            # debug build, runs immediately
    ./make-app.sh        # release build wrapped as build/AccessTerm.app

Or open `Package.swift` in Xcode (File > Open), pick the AccessTerm scheme, and press
Command-R. Xcode fetches SwiftTerm automatically on first open.

The first build downloads the SwiftTerm package, so it needs network access once.

## Layout

Top to bottom:

1. **Transcript** (a table, labeled "Transcript"). One row per logical line. Long lines that
   wrapped in the terminal are joined back into a single row.
2. **Current line** (labeled "Current line"). Whatever the program has not finished printing:
   normally the shell prompt, a partially printed line, or a progress line.
3. **Command line** (labeled "Command line"). A normal text field. Return sends the line.

## Keys

Global (Command shortcuts, so they never collide with VoiceOver's Control-Option):

| Key | Action |
| --- | --- |
| Command-1 | Focus the transcript (selects the last line if nothing is selected) |
| Command-2 | Focus the command line |
| Command-Shift-E | Go to the end of the transcript |
| Command-Shift-L | Speak the current line |
| Command-Shift-S | Toggle speaking of new output on and off |
| Command-. | Send Control-C (interrupt) |
| Command-Shift-C | Copy the entire transcript |

In the transcript:

- Up/Down arrow: move one line, VoiceOver reads it. No interaction needed.
- Shift-Up/Down: extend the selection. Command-A selects all.
- Command-C: copy the selected lines.
- Moving the selection off the last line freezes auto-scroll; Command-Shift-E resumes it.

In the command line:

- Return: send the line.
- Up/Down: local command history (kept by the app, so it reads normally).
- Control-C, Control-D, Control-Z, Control-L, Escape: sent straight to the program.
- Shift-Tab: sent to the program (Claude Code uses it to cycle permission modes).
- Tab: moves focus to the transcript. Shell tab-completion is not available in this mode yet.
- Other Control keys keep their macOS text-editing meaning (Control-A, Control-E, Control-K).

Terminal menu also has "Send Escape" and "Send Shift-Tab" for when you'd rather use the menu.

## What is announced

- New output lines are batched every quarter second and spoken as one announcement.
  Bursts over 30 lines are summarised ("N lines of output. Last 30: ...").
- A terminal bell speaks "Attention" plus the current line at high priority. Claude Code's
  screen reader mode rings the bell when it wants input, so this is how you know it's your turn.
- Full-screen programs (vim, htop, an attached Claude session) switch the transcript to a
  screen view and speak changed rows. This is basic in milestone 1.

## Tool settings applied automatically

The shell is launched with these environment variables so the tools you care about behave:

- `CLAUDE_AX_SCREEN_READER=1` — Claude Code's screen reader mode (v2.1.181 or later).
- `GH_ACCESSIBLE_PROMPTER=1`, `GH_ACCESSIBLE_COLORS=1`, `GH_SPINNER_DISABLED=1` — GitHub CLI.
- `TERM_PROGRAM=AccessTerm` so other tools can detect the app.

## Known limitations in this milestone

- The terminal is a fixed 160 columns by 50 rows; it does not follow the window size.
- Shell tab completion and the shell's own history editing don't work from the native
  command field. A "direct input" mode that passes every keystroke through is planned.
- After 100,000 lines of scrollback the transcript stops growing. Restart the app for now.
- No OSC 133 command blocks yet (milestone 2), so "jump to previous command" isn't in yet.

## Milestones

1. This: PTY, headless VT engine, accessible transcript, command field, announcements.
2. Shell integration (OSC 133): command/output blocks, jump between commands, copy output only,
   custom VoiceOver rotors for commands, errors, and Claude turns.
3. Better full-screen program support and a direct-input mode.
