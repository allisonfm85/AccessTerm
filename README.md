# AccessTerm (milestone 2)

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
   character. Lines are added at the end, and a line a program repaints is rewritten where it
   already is rather than repeated (see "Programs that redraw"); the caret stays on the text
   it was on either way.
2. **Current line** (labeled "Current line"). Whatever the program has not finished printing:
   normally the shell prompt, a partially printed line, or a progress line. When the cursor is
   parked on a blank row underneath a frame a program has just painted, this is the last line
   of that frame rather than nothing.
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
| Option-Command-Up | Previous command |
| Option-Command-Down | Next command |
| Command-Shift-O | Copy the output of the command the caret is in |

In the transcript:

- Up/Down arrow: move one line, VoiceOver reads it. No interaction needed.
- Left/Right arrow: move one character. Option-Left/Right: move one word.
- Shift with any of those: extend the selection. Command-A selects all.
- Command-C: copy the selection. Command-Shift-C copies the whole transcript.
- Command-F: find (Edit > Find). Return and Shift-Return step through the matches.
- Command-1 puts the caret on the last command you ran, at the start of its line, which is
  the top of that command's output. Before you have run anything it goes to the end.
- Option-Command-Up and Option-Command-Down step between commands, landing on the command
  line each time and speaking the command, plus its exit code if it failed: "ls -la, exit
  code 1". From inside a command's output, Option-Command-Up goes to the top of that command
  first, then to the one before it.
- Inside a command that runs a conversation of its own -- a Claude Code session -- those keys
  step between its turns instead, speaking each question. At the first turn, one more
  Option-Command-Up is the command they are all inside ("claude"), and from there stepping
  goes back to the shell's commands. See "Turns inside a command".
- Command-Shift-O copies the output of the command the caret is in, without the prompt or the
  command line. Inside a turn, it copies the answer to that question rather than everything
  the program has printed since it started.
- Command-Shift-E puts the caret on the last line, so VoiceOver reads it.
- New output only scrolls the view when the caret is already at the end, so moving back to
  read something holds your place; Command-Shift-E returns to following the output.

In the command line:

- Return: send the line. The text and the Return go as two separate writes: programs decide
  whether input was typed or pasted by how much arrives at once, and Claude Code treats
  anything over about sixty bytes as a paste -- which used to mean that a long line's Return
  was pasted text rather than "send this", and nothing happened. When the program has asked
  for bracketed paste, the text is wrapped in the paste markers too.
- Up/Down: local command history (kept by the app, so it reads normally).
- Control-C, Control-D, Control-Z, Control-L, Escape: sent straight to the program.
- Shift-Tab: sent to the program (Claude Code uses it to cycle permission modes).
- Tab: moves focus to the transcript. Shell tab-completion is not available in this mode yet.
- Other Control keys keep their macOS text-editing meaning (Control-A, Control-E, Control-K).

Terminal menu also has "Send Escape" and "Send Shift-Tab" for when you'd rather use the menu.

## Programs that redraw

A terminal is a grid, and plenty of programs treat it as one: they print something, then move
the cursor back up over it and print it again with a word changed. Claude Code's screen reader
mode repaints its whole frame -- the message being streamed, the spinner, the status lines,
the input box -- several times a second, and patches single words in place in between.

Rows are therefore not frozen once the cursor passes them. Every line remembers the rows it
was built from, and when a program redraws one of those rows, the line it produced is rewritten
in its place. A streamed reply reads as one line that grows, not as one copy per frame, and
what the transcript holds at the end is what a sighted user would see on the screen.

Only two things reset that: the scrollback being thrown away, and the screen being wiped
(`clear`, Control-L). Then the lines already in the transcript keep their text -- it is a
transcript, not a screen -- and rows start being read again from where the wipe left the
cursor, so nothing that was on screen is overwritten by what comes next.

New output is spoken when it is new: a line is announced when its text is not blank and is not
what was last announced for that same line, so a frame that repaints the same words says
nothing.

## Command blocks

The transcript is divided into blocks: one prompt, one command, its output, and how it ended.
That is what Option-Command-Up and Option-Command-Down move between, what Command-Shift-O
copies the output of, and what Command-1 lands on.

### Turns inside a command

A command that keeps running and holds a conversation is not one block with a wall of output
in it. Claude Code marks the start of each turn (an OSC 133 `A` while its command is still
running, which no shell would send: a shell is not prompting while its command runs), and
prints the question on a line of its own behind a `you:` label. Each of those becomes a child
block: the question is its command line, the answer is its output, and it ends where the next
question starts.

So a Claude session is one `claude` block with a turn in it per question, and
Option-Command-Up and Option-Command-Down move between those turns while the caret is inside
it. Command-1 lands on the most recent question. Command-Shift-O copies that turn's answer.

A program that does not mark its turns, but does label them, gets the same treatment from the
label alone: a line beginning with `you: ` starts a turn. Where the markers are there, they
are what is believed, so a question quoted inside an answer does not look like a new turn.

The boundaries come from OSC 133, the escape sequences a shell prints to say "prompt starts
here", "the command starts here", "it is running now" and "it finished with this exit code".
Nothing needs to be added to your dotfiles: zsh reads its startup files from `$ZDOTDIR`, so
the app writes a directory of its own to `~/Library/Application Support/AccessTerm/zsh` and
launches the shell pointed at it. The files there source your own `.zshenv`, `.zprofile`,
`.zshrc` and `.zlogin` first, put `ZDOTDIR` back to yours afterwards, and then add `precmd`
and `preexec` hooks that print the markers. They are rewritten on every launch, so editing
them is pointless -- edit your own dotfiles, which they run.

Claude Code's screen reader mode prints markers of its own, which is where the turns above
come from. It sends `A` at the start of a turn and a bare `D` at the end of one; the shell's
`D` always carries an exit code, which is how the two are told apart.

If no markers ever arrive -- another shell, a `$ZDOTDIR` you have locked down -- the whole
transcript is treated as one block. The commands above still work; there is just one thing
for them to work on.

## What is announced

- New output lines are batched every quarter second and spoken as one announcement.
  Bursts over 30 lines are summarised ("N lines of output. Last 30: ...").
- A line is only spoken when it says something new: blank lines are skipped, and a line that
  is redrawn with the text it already had is not repeated. See "Programs that redraw".
- Moving the caret in the transcript is read by VoiceOver itself, as in any text area: the
  line, word or character moved over, and its own wording for extending or shrinking the
  selection. The app adds nothing to it, so it follows your VoiceOver verbosity settings.
- When the app moves the caret for you (Command-1, Command-Shift-E), the landing line is
  announced at high priority once focus has landed. See "Known issues" for what VoiceOver
  says before it.
- A command that ends with a non-zero exit code adds "exit code 127" to the end of the
  announcement of whatever it printed.
- A yes/no prompt says what Return alone will do: a line ending in `[Y/n]`, `[y/N]`,
  `[Y/n/a]` or `(default: yes)` is announced with "Press Return for yes." (or no) on the
  end. The capital is the default, so a prompt that names none (`[y/n]`) gets no hint. Only
  the announcement carries it; the transcript stays verbatim for copying.
- A terminal bell speaks "Attention" plus the current line at high priority. Claude Code's
  screen reader mode rings the bell when it wants input, so this is how you know it's your turn.
- Full-screen programs (vim, htop, an attached Claude session) switch the transcript to a
  screen view and speak changed rows. This is basic in milestone 1.

## Tool settings applied automatically

The shell is launched with these environment variables so the tools you care about behave:

- `CLAUDE_AX_SCREEN_READER=1` — Claude Code's screen reader mode (v2.1.181 or later).
- `GH_ACCESSIBLE_PROMPTER=1`, `GH_ACCESSIBLE_COLORS=1`, `GH_SPINNER_DISABLED=1` — GitHub CLI.
- `TERM_PROGRAM=AccessTerm` so other tools can detect the app.
- `ZDOTDIR` points at the app's own zsh startup files, which source yours. See "Command
  blocks". Your original value is kept in `ACCESSTERM_USER_ZDOTDIR` and restored before your
  `.zshrc` finishes, so anything you launch sees the value you set.

## Diagnostics

Setting `ACCESSTERM_LOG` to a path makes the app append every byte it reads from the pty to
that file, exactly as it arrived, escape sequences and all. Nothing else changes. It is there
to compare what a program actually sent against what the transcript made of it:

    ACCESSTERM_LOG=/tmp/raw.log ./build/AccessTerm.app/Contents/MacOS/AccessTerm

The variable has to be in the app's own environment, so launch the binary directly rather than
with `open`.

The raw log says what a program printed, but not what it was answered with. `ACCESSTERM_HEXLOG`
adds that: every byte written to the pty as a `TX` line and every byte read as an `RX` line, in
hex with a millisecond timestamp. It is what a prompt that looks stuck needs, since it shows
whether an answer was sent at all and what the program did next:

    ACCESSTERM_LOG=/tmp/raw.log ACCESSTERM_HEXLOG=/tmp/raw.hex \
        ./build/AccessTerm.app/Contents/MacOS/AccessTerm

With only `ACCESSTERM_LOG` set, the hex log goes to that path with `.hex` appended. Both logs
are off unless their variable is set.

A capture can be replayed through the transcript assembly without a window, a shell or a pty,
which is how a program that comes out wrong becomes a repeatable check:

    ./build/AccessTerm.app/Contents/MacOS/AccessTerm --replay /tmp/raw.log

It prints the transcript the capture produces after a `--- transcript ---` marker, and the
current line on standard error.

## Known limitations in this milestone

- The terminal is a fixed 160 columns by 50 rows; it does not follow the window size.
- Shell tab completion and the shell's own history editing don't work from the native
  command field. A "direct input" mode that passes every keystroke through is planned.
- After 100,000 lines of scrollback the transcript stops growing. Restart the app for now.

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
2. This: shell integration (OSC 133): command/output blocks, jump between commands, copy
   output only. Custom VoiceOver rotors for commands, errors and Claude turns are not in yet.
3. Better full-screen program support and a direct-input mode.

## License

MIT. See [LICENSE](LICENSE).
