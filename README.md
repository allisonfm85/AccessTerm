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

1. **Transcript** (a read-only text view, labeled "Transcript"). One line per logical line.
   Long lines that wrapped in the terminal are joined back into a single line. Because it is
   an ordinary text view, VoiceOver navigates it with the caret and reads by line, word, or
   character; text is only ever appended, so the reading position never moves under you.
2. **Current line** (labeled "Current line"). Whatever the program has not finished printing:
   normally the shell prompt, a partially printed line, or a progress line.
3. **Command line** (labeled "Command line"). A normal text field. Return sends the line.

## Keys

Global (Command shortcuts, so they never collide with VoiceOver's Control-Option):

| Key | Action |
| --- | --- |
| Command-1 | Focus the transcript, caret at the last command you ran |
| Command-2 | Focus the command line |
| Command-Shift-E | Go to the end of the transcript |
| Command-Shift-L | Speak the current line |
| Command-Shift-S | Toggle speaking of new output on and off |
| Command-. | Send Control-C (interrupt) |
| Command-Shift-C | Copy the entire transcript |

In the transcript:

- Up/Down arrow: move one line, VoiceOver reads it. No interaction needed.
- Left/Right arrow: move one character. Option-Left/Right: move one word.
- Shift with any of those: extend the selection. Command-A selects all.
- Command-C: copy the selection. Command-Shift-C copies the whole transcript.
- Command-F: find (Edit > Find). Return and Shift-Return step through the matches.
- Command-1 puts the caret at the start of the echo of the last command you sent, which is
  the top of that command's output. Before you have run anything it goes to the end.
- Command-Shift-E puts the caret on the last line, so VoiceOver reads it.
- New output only scrolls the view when the caret is already at the end, so moving back to
  read something holds your place; Command-Shift-E returns to following the output.

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
- Moving the caret in the transcript is read by VoiceOver itself, as in any text area: the
  line, word or character moved over, and its own wording for extending or shrinking the
  selection. The app adds nothing to it, so it follows your VoiceOver verbosity settings.
- When the app moves the caret for you (Command-1, Command-Shift-E), the landing line is
  announced at high priority once focus has landed. See "Known issues" for what VoiceOver
  says before it.
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

## Known issues

**VoiceOver reads the first line of the transcript when it takes focus.** Command-1 and
Command-Shift-E move the caret to the line you asked for and announce it, but VoiceOver reads
the first line of the transcript first, whatever the caret is doing. You hear the wrong line,
then the right one.

Tried, none of which stopped it:

- Overriding the accessibility attributes the text could be read from -- value, visible
  character range, number of characters, and string and attributed-string for a range --
  either narrowed to the caret's line or blanked entirely.
- Reporting the view as static text instead of a text area, so VoiceOver would read it
  through the visible range rather than as an entry area.
- A quiet window: reporting nothing readable at all for a third of a second around the focus
  change, then restoring and posting selected-text-changed rather than value-changed.
- Swapping the contents themselves, so the text view held only the landing line while focus
  arrived and was put back half a second later.

The read appears to come from a path that does not consult any of those. Parked: the
high-priority announcement of the landing line is the workaround, and everything else is back
to an ordinary text area, which is what VoiceOver navigates best.

## Milestones

1. This: PTY, headless VT engine, accessible transcript, command field, announcements.
2. Shell integration (OSC 133): command/output blocks, jump between commands, copy output only,
   custom VoiceOver rotors for commands, errors, and Claude turns.
3. Better full-screen program support and a direct-input mode.
