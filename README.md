# AccessTerm

AccessTerm is a macOS terminal built for VoiceOver users.

A normal terminal is one big text area that VoiceOver has to "interact with" before it can
read anything, and everything -- what you typed and what the computer printed -- lives in that
one area together. AccessTerm splits it up: output is a plain, read-only list of lines you can
arrow through, and there is a separate ordinary text field for typing. Both are standard macOS
controls, so VoiceOver reads them the way it reads any list or text field.

It needs macOS 13 (Ventura) or later.

**Contents**

- [Installing and running AccessTerm](#installing-and-running-accessterm)
- [What the window looks like](#what-the-window-looks-like)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Programs that redraw the screen](#programs-that-redraw-the-screen)
- [Command blocks](#command-blocks)
- [What gets spoken](#what-gets-spoken)
- [Settings applied automatically](#settings-applied-automatically)
- [Diagnostics](#diagnostics)
- [Known limitations](#known-limitations)
- [Known issues](#known-issues)
- [Milestones](#milestones)
- [License](#license)

## Installing and running AccessTerm

AccessTerm is not distributed as a ready-made download yet, so you build it yourself: you copy
the source code to your Mac and run one command that turns it into a working program.
"Building" (or "compiling") just means that translation step. You only have to do it once, and
you do not need to know anything about the code to do it.

The whole process is: install Apple's developer tools, download the code, run one command.
Expect ten minutes the first time, most of it spent waiting.

### Before you start: install Apple's developer tools

Building needs Swift, Apple's programming language, which comes with a free Apple download
called the Command Line Tools. If you already have Xcode installed, you already have this and
can skip ahead.

1. Open the Terminal app (press Command-Space, type `Terminal`, press Return).
2. Type this and press Return:

   ```
   xcode-select --install
   ```

3. If a dialog appears offering to install the tools, choose Install and wait for it to
   finish. It is a large download.
4. If instead you see a message saying the tools are already installed, you are ready.

### Step 1: get the code onto your Mac

If you know Git, clone the repository as usual:

```
git clone https://github.com/allisonfm85/AccessTerm.git
```

If you do not, go to <https://github.com/allisonfm85/AccessTerm>, use the green **Code**
button, choose **Download ZIP**, and unzip the file that lands in your Downloads folder. Either
way you end up with a folder named `AccessTerm`.

### Step 2: tell Terminal to work inside that folder

Terminal is always "in" one folder at a time, and it only sees the files there. The `cd`
command ("change directory") moves it. If the folder is in your Downloads, that is:

```
cd ~/Downloads/AccessTerm
```

The `~` is shorthand for your home folder. If you put the folder somewhere else, adjust the
path -- or type `cd ` (with a space after it), then drag the folder from Finder onto the
Terminal window, which fills in the path for you, and press Return.

Nothing visible happens when `cd` works. That is normal; silence means success. If you see
"No such file or directory", the path is wrong, not the app.

### Step 3: build and run it

There are two ways to do this. Both build the same program.

**The quick way -- try it now.** Type:

```
swift run
```

This compiles the app and launches it as soon as it is ready. The first run has to download
one component AccessTerm depends on (a terminal engine called SwiftTerm), so it needs an
internet connection that one time, and it can take several minutes. You will see a lot of
progress text scroll by; that is the build talking, not an error. Later runs are much faster.

While the app is running, the Terminal window you started it from stays busy. Quit AccessTerm
to get that window back, or press Control-C in it to stop the app.

**The tidy way -- make a real app you can double-click.** Type:

```
./make-app.sh
```

This does a slower, optimised build and then wraps the result into a proper macOS application
at `build/AccessTerm.app`. When it finishes it prints the path. Open it with:

```
open build/AccessTerm.app
```

From then on you can launch AccessTerm from Finder like any other app -- double-click it, or
drag it to your Applications folder first and launch it from there. You do not need Terminal
again unless you want to rebuild after updating the code.

### If you prefer Xcode

You do not need Xcode, but it works. In Xcode choose File > Open, select the `Package.swift`
file inside the AccessTerm folder, pick the AccessTerm scheme, and press Command-R to build and
run. Xcode downloads SwiftTerm on its own the first time.

### If something goes wrong

| What you see | What it means | What to do |
| --- | --- | --- |
| `swift: command not found` | The developer tools are not installed | Run `xcode-select --install` (see above) |
| An error about `xcrun` or a missing developer directory | Same thing, or Xcode is not selected | Run `xcode-select --install`; if Xcode is installed, run `sudo xcode-select -s /Applications/Xcode.app` |
| `No such file or directory` after `cd` | Terminal is not in the AccessTerm folder | Check the path; drag the folder onto the Terminal window to fill it in |
| The build stops with a network or "failed to clone" error | It could not fetch SwiftTerm | Check your internet connection and run the command again |
| `permission denied: ./make-app.sh` | The script is not marked runnable | Run `chmod +x make-app.sh`, then try again |
| macOS says the app cannot be opened because it is from an unidentified developer | Gatekeeper does not recognise a locally built app | Control-click `AccessTerm.app` in Finder and choose Open, then confirm |

Remember to turn VoiceOver on (Command-F5) before you start using AccessTerm -- it is built
around VoiceOver, and a lot of what it does only shows up when VoiceOver is speaking.

## What the window looks like

Three areas, top to bottom. The Command shortcuts in the next section move between them from
anywhere in the window.

1. **Transcript** (a read-only text view, labeled "Transcript"). Everything that has been
   printed, one line per logical line. Long lines that wrapped on screen are joined back into
   a single line here. Because it is an ordinary text view, VoiceOver navigates it with the
   caret and reads by line, word, or character -- no interacting required. New lines are added
   at the end, and when a program repaints a line it already printed, that line is rewritten
   where it is instead of appearing twice (see [Programs that redraw the
   screen](#programs-that-redraw-the-screen)). Either way, your caret stays on the text it was
   on.
2. **Current line** (labeled "Current line"). The line the program has not finished printing
   yet: usually the shell prompt, a half-printed line, or a progress indicator. When the cursor
   is sitting on a blank row underneath something a program has just drawn, this shows the last
   line of that drawing rather than nothing.
3. **Command line** (labeled "Command line"). An ordinary text field. Press Return to send
   what you have typed.

## Keyboard shortcuts

These all use Command, so they never collide with VoiceOver's Control-Option commands. They
work from anywhere in the window.

| Key | Action |
| --- | --- |
| Command-1 | Focus the transcript, caret at the last command you ran |
| Command-2 | Focus the command line |
| Command-Shift-E | Go to the end of the transcript |
| Command-Shift-L | Speak the current line |
| Command-Shift-S | Toggle speaking of new output on and off |
| Command-. | Send Control-C (interrupt whatever is running) |
| Command-Shift-C | Copy the entire transcript |
| Option-Command-Up | Previous command |
| Option-Command-Down | Next command |
| Command-Shift-O | Copy the output of the command the caret is in |

### While the caret is in the transcript

- **Up/Down arrow**: move one line; VoiceOver reads it. No interaction needed.
- **Left/Right arrow**: move one character. **Option-Left/Right**: move one word.
- **Shift** with any of those extends the selection. **Command-A** selects all.
- **Command-C** copies the selection; **Command-Shift-C** copies the whole transcript.
- **Command-F** opens Find (Edit > Find). Return and Shift-Return step through matches.
- **Command-1** puts the caret at the start of the last command you ran, which is also the top
  of that command's output. Before you have run anything, it goes to the end.
- **Option-Command-Up / Option-Command-Down** step between commands. Each stop lands on the
  command itself and speaks it, plus its exit code if it failed: "ls -la, exit code 1". If the
  caret is in the middle of a command's output, Option-Command-Up goes to the top of that
  command first, then on to the one before it.
- Inside a command that holds a conversation of its own -- a Claude Code session -- those same
  keys step between its turns instead, speaking each question. At the first turn, one more
  Option-Command-Up takes you to the command they all belong to ("claude"), and from there
  stepping continues through the shell's commands as usual. See [Turns inside a
  command](#turns-inside-a-command).
- **Command-Shift-O** copies the output of the command the caret is in, without the prompt or
  the command itself. Inside a turn, it copies just that turn's answer rather than everything
  the program has printed since it started.
- **Command-Shift-E** puts the caret on the last line, so VoiceOver reads it.
- New output only scrolls the view when the caret is already at the end. So moving back to
  re-read something holds your place, and Command-Shift-E puts you back to following along
  live.

### While the caret is in the command line

- **Return**: send the line. The text and the Return are sent as two separate writes. Programs
  work out whether input was typed or pasted by how much arrives at once, and Claude Code
  treats anything over about sixty bytes as a paste -- which used to mean a long line's Return
  was read as pasted text rather than "send this", and nothing happened. When the program has
  asked for bracketed paste, the text is wrapped in the paste markers too.
- **Up/Down**: command history, kept by the app itself so VoiceOver reads it normally.
- **Control-C, Control-D, Control-Z, Control-L, Escape**: sent straight to the program.
- **Shift-Tab**: sent to the program (Claude Code uses it to cycle permission modes).
- **Tab**: moves focus to the transcript. Shell tab-completion is not available in this mode
  yet.
- Other Control keys keep their usual macOS text-editing meaning (Control-A, Control-E,
  Control-K).

The Terminal menu also has "Send Escape" and "Send Shift-Tab", for when a menu is easier than
a key combination.

## Programs that redraw the screen

A terminal is really a grid of character cells, and plenty of programs treat it as one: they
print something, move the cursor back up over it, and print it again with a word changed.
Claude Code's screen reader mode repaints its whole frame -- the message being streamed, the
spinner, the status lines, the input box -- several times a second, and patches single words
in place in between.

That means a line is not finished just because the cursor has moved past it. Every line in the
transcript remembers which screen rows it was built from, and when a program redraws one of
those rows, the line it produced is rewritten in place. A streamed reply reads as one line that
grows, rather than one copy per frame, and what the transcript holds at the end is what a
sighted user would have seen on screen.

Only two things reset that: the scrollback (the history the terminal keeps above the visible
screen) being discarded, and the screen being wiped with `clear` or Control-L. After either,
lines already in the transcript keep their text -- this is a transcript, not a screen -- and
rows start being tracked again from wherever the wipe left the cursor, so nothing already
written gets overwritten by what comes next.

New output is spoken only when it is genuinely new: a line is announced when its text is not
blank and is not what was last announced for that same line, so a frame that repaints the same
words says nothing.

## Command blocks

The transcript is divided into blocks. One block is a prompt, the command you typed, its
output, and how it ended. Blocks are what Option-Command-Up and Option-Command-Down move
between, what Command-Shift-O copies the output of, and what Command-1 lands on.

### Turns inside a command

A command that keeps running and holds a conversation with you should not be a single block
with a wall of output inside it. Claude Code marks the start of each turn, and prints your
question on a line of its own behind a `you:` label. Each of those becomes a block nested
inside the command: the question acts as its command line, the answer as its output, and it
ends where the next question starts.

So a Claude session is one `claude` block with one turn inside it per question.
Option-Command-Up and Option-Command-Down move between those turns while the caret is inside
the session, Command-1 lands on the most recent question, and Command-Shift-O copies that
turn's answer.

A program that does not mark its turns but does label them gets the same treatment from the
label alone: a line beginning with `you: ` starts a turn. Where real markers exist, they win,
so a question quoted inside an answer is not mistaken for a new turn.

### Where the block boundaries come from (the technical bit)

Boundaries come from OSC 133, a set of invisible escape sequences a shell prints to say
"a prompt starts here", "the command starts here", "it is running now", and "it finished with
this exit code".

You do not have to add anything to your dotfiles (the `.zshrc` and friends that configure your
shell). Zsh reads its startup files from whatever `$ZDOTDIR` points at, so AccessTerm writes a
directory of its own at `~/Library/Application Support/AccessTerm/zsh` and launches the shell
pointed at that. The files there source your own `.zshenv`, `.zprofile`, `.zshrc` and `.zlogin`
first, put `ZDOTDIR` back to yours afterwards, and then add the hooks that print the markers.
They are rewritten on every launch, so editing them has no lasting effect -- edit your own
dotfiles, which they run.

Claude Code's screen reader mode prints markers of its own, which is where the turns above come
from. It sends an `A` at the start of a turn and a bare `D` at the end of one; a shell's `D`
always carries an exit code, which is how the two are told apart. An `A` arriving while a
command is still running is also how the app knows it came from a program rather than a shell:
a shell is never prompting while its own command runs.

If no markers ever arrive -- a different shell, or a `$ZDOTDIR` you have locked down -- the
whole transcript is treated as one block. All the commands above still work; there is simply
one thing for them to work on.

## What gets spoken

- New output lines are batched every quarter second and spoken as one announcement. Bursts of
  more than 30 lines are summarised: "N lines of output. Last 30: ...".
- A line is only spoken when it says something new. Blank lines are skipped, and a line
  redrawn with the text it already had is not repeated. See [Programs that redraw the
  screen](#programs-that-redraw-the-screen).
- Moving the caret in the transcript is read by VoiceOver itself, exactly as in any text area:
  the line, word or character you moved over, and VoiceOver's own wording for extending or
  shrinking a selection. The app adds nothing, so this follows your VoiceOver verbosity
  settings.
- When the app moves the caret for you (Command-1, Command-Shift-E), the line you land on is
  announced at high priority once focus has arrived. See [Known issues](#known-issues) for what
  VoiceOver says before it.
- A command that ends with a non-zero exit code -- meaning it failed -- has "exit code 127"
  (or whichever number) added to the end of the announcement of whatever it printed.
- A yes/no prompt is told what pressing Return alone will do. A line ending in `[Y/n]`,
  `[y/N]`, `[Y/n/a]` or `(default: yes)` is announced with "Press Return for yes." (or no) on
  the end. The capital letter is the default, so a prompt that names no default (`[y/n]`) gets
  no hint. Only the spoken announcement carries this; the transcript itself stays verbatim so
  copying it gives you exactly what was printed.
- A terminal bell speaks "Attention" plus the current line, at high priority. Claude Code's
  screen reader mode rings the bell when it wants input, so this is how you know it is your
  turn.
- Full-screen programs (vim, htop, an attached Claude session) switch the transcript to a
  screen view and speak rows as they change. This is still basic.

## Settings applied automatically

AccessTerm launches your shell with these environment variables already set, so the tools you
are likely to use behave well with a screen reader without you configuring anything:

- `CLAUDE_AX_SCREEN_READER=1` — turns on Claude Code's screen reader mode (v2.1.181 or later).
- `GH_ACCESSIBLE_PROMPTER=1`, `GH_ACCESSIBLE_COLORS=1`, `GH_SPINNER_DISABLED=1` — the same for
  the GitHub CLI.
- `TERM_PROGRAM=AccessTerm` so other tools can tell they are running here.
- `ZDOTDIR` points at the app's own zsh startup files, which source yours. See [Command
  blocks](#command-blocks). Your original value is kept in `ACCESSTERM_USER_ZDOTDIR` and
  restored before your `.zshrc` finishes, so anything you launch sees the value you set.

## Diagnostics

This section is for tracking down bugs in AccessTerm itself. You can skip it unless you are
reporting a problem or want to see why a program came out looking wrong.

Setting `ACCESSTERM_LOG` to a file path makes the app append every byte it reads from the
terminal to that file, exactly as it arrived, escape sequences and all. Nothing else changes.
It exists so you can compare what a program actually sent against what the transcript made of
it.

Environment variables like this have to be set for the app's own process, which means putting
them in front of the command that starts it, and starting the program inside the app bundle
directly rather than using `open`:

```
ACCESSTERM_LOG=/tmp/raw.log ./build/AccessTerm.app/Contents/MacOS/AccessTerm
```

The raw log records what a program printed, but not what it was answered with.
`ACCESSTERM_HEXLOG` adds that: every byte written to the terminal as a `TX` line and every byte
read as an `RX` line, in hexadecimal with a millisecond timestamp. This is what a prompt that
looks stuck needs, because it shows whether an answer was sent at all and what the program did
next:

```
ACCESSTERM_LOG=/tmp/raw.log ACCESSTERM_HEXLOG=/tmp/raw.hex \
    ./build/AccessTerm.app/Contents/MacOS/AccessTerm
```

(The backslash at the end of the first line just means "this command continues on the next
line"; you can type it all on one line instead.)

If you set only `ACCESSTERM_LOG`, the hex log is written to that same path with `.hex`
appended. Both logs are off unless their variable is set.

A capture can be replayed through the transcript machinery with no window, shell or terminal
involved, which turns a program that came out wrong into a repeatable test:

```
./build/AccessTerm.app/Contents/MacOS/AccessTerm --replay /tmp/raw.log
```

It prints the transcript the capture produces after a `--- transcript ---` marker, and the
current line on standard error.

## Known limitations

- The terminal is a fixed 160 columns by 50 rows and does not follow the window size.
- Shell tab completion and the shell's own history editing do not work from the native command
  field. A "direct input" mode that passes every keystroke straight through is planned.
- After 100,000 lines, the transcript stops growing. Restart the app for now.

## Known issues

**VoiceOver reads the first line of the transcript when it takes focus.** Command-1 and
Command-Shift-E move the caret to the line you asked for and announce it, but VoiceOver reads
the first line of the transcript first, whatever the caret is doing. You hear the wrong line,
then the right one.

Things that were tried, none of which stopped it:

- Overriding the accessibility attributes the text could be read from -- value, visible
  character range, number of characters, and string and attributed-string for a range --
  either narrowed to the caret's line or blanked entirely.
- Reporting the view as static text instead of a text area, so VoiceOver would read it through
  the visible range rather than as an entry area.
- A quiet window: reporting nothing readable at all for a third of a second around the focus
  change, then restoring and posting selected-text-changed rather than value-changed.
- Swapping the contents themselves, so the text view held only the landing line while focus
  arrived, and putting them back half a second later.

The read appears to come from a path that consults none of those. This is parked: the
high-priority announcement of the landing line is the workaround, and everything else is back
to being an ordinary text area, which is what VoiceOver navigates best.

## Milestones

1. **Done** — PTY, headless VT engine, accessible transcript, command field, announcements.
2. **Done (where the project is now)** — shell integration via OSC 133: command and output
   blocks, jumping between commands, copying output on its own. Custom VoiceOver rotors for
   commands, errors and Claude turns are not in yet.
3. **Planned** — better support for full-screen programs, and a direct-input mode.

## License

MIT. See [LICENSE](LICENSE).
