# Native terminal behavior

Coincide runs local shells in SwiftTerm PTYs. Each window owns its own tabs;
hiding the terminal or selecting another conversation preserves those processes.
Closing a running command asks for confirmation. Closing the window or quitting
drains the owned processes using the existing shutdown escalation.

## Shells and environment

A new terminal starts your shell as a login shell in the conversation's
checkout. If that shell is unavailable, Coincide tries `$SHELL`, your account's
login shell, then `/bin/zsh`, `/bin/bash` and `/bin/sh`, as T3 Code does. Only
existing executable files are tried; a shell that starts and then fails is not
replaced by another one.

Every terminal, like every project script, receives `T3CODE_PROJECT_ROOT` (the
project's root checkout). A conversation in a linked worktree also receives
`T3CODE_WORKTREE_PATH`. Values inherited from the app's own environment are
replaced, never passed through.

## Drawer, tabs and split panes

Each conversation remembers whether its terminal drawer is open and how tall it
is. **⌘J** (Terminal › Toggle Terminal) shows or hides the selected
conversation's drawer and opens a shell when it has none; the toolbar button
keeps **⌥⌘T**. Drag the divider above the drawer to resize it.

Tabs are groups of up to four terminals. **Split Right** places a new terminal
beside the selected one and **Split Down** stacks it below; the group takes the
latest direction. Closing a pane selects its neighbour, and closing the last
pane removes the tab. Plain terminals are labelled **Terminal 1**, **Terminal
2** and so on; while a command runs, its tab shows the command's name.

A shell that exits with status 0 closes its tab (and hides the drawer when it
was the last one). A non-zero exit keeps the tab with its status. Script tabs
always keep their result.

### Keyboard and context menu

While a terminal has keyboard focus:

| Keys | Action |
| --- | --- |
| ⌘D / ⇧⌘D | Split right / split down |
| ⌘N | New terminal |
| ⌘W | Close the focused terminal (asks first if a command is running) |
| ⌘K | Clear (sends Ctrl-L, so the shell redraws its prompt) |
| ⌘F | Find in scrollback |
| ⇧⌘End / ⇧⌘Home | Jump to the latest output / the start |
| ⇧PageUp / ⇧PageDown | Scroll the scrollback |

Full-screen programs (alternate screen) keep their own navigation keys. These
shortcuts apply only to a focused terminal, so they are not claimed for the
whole window. Showing a terminal again does not move keyboard focus to it; new,
split and explicitly opened terminals are focused.

Right-click a terminal for Copy, Paste, Select All, Jump to Latest, Clear,
Find, New Terminal, Split Right, Split Down and Close Terminal. Paste and Clear
are unavailable for saved output. The Terminal menu offers New Terminal, Split
Right, Split Down, Clear, Jump to Latest Output, Find and Close for the selected
terminal.

## Running indicators

Coincide samples each running shell's process table about once a second,
off the main thread, using read-only `libproc` calls (no `ps` subprocess). A
shell with a foreground job, or any child except an asynchronous prompt
helper, counts as running, following T3's rules. Quiet shells are re-sampled
only every 30 seconds until input or output arrives. Script tabs count as
running until they exit.

Running terminals show a pulsing dot in their tab. A conversation with running
terminals shows **Terminal running** in the sidebar; choosing it selects the
conversation and opens its terminal.

## Links

⌘-click a URL or a path in terminal output. `http` and `https` links open in
your default browser. Paths may be absolute, relative to the terminal's current
directory (the running command's or the shell's), or start with `~/`, and may
end in `:line` or `:line:column`; trailing punctuation and unbalanced closing
brackets are ignored. Files inside the conversation's checkout open in the
Files inspector at that line. Other existing files and folders are revealed in
Finder. A missing file shows a short notice in the terminal. Other schemes
(`mailto:`, `ssh:`, custom handlers) are refused. Opening a link never runs
anything.

## Appearance

Settings › General › Terminal chooses the font family (installed fixed-pitch
fonts or System Monospaced), the size (8–20 pt) and colors. **Match
Appearance** keeps the system text and background colors and switches T3's
light and dark ANSI palettes, cursor and selection colors with the app;
**Light** and **Dark** fix the whole terminal theme. Increased contrast
strengthens the selection and the dimmest light-palette colors. Changes apply
to open local and remote terminals without restarting them. The terminal
header's text-size menu remains a shortcut.

## Settle

**Close idle shells when settling** in Settings is off by default. When enabled,
settling a conversation closes its terminals that wait at a proven idle prompt,
in every window, and keeps their output in the tab. Coincide inspects each shell
again at that moment instead of trusting the last sample, so a command started
just before settling keeps its terminal. A quiet tab label alone cannot authorize
closure: Coincide also requires a current native semantic prompt marker, a known
foreground shell with its captured physical executable identity, and no remaining
owned descendants. The protected native `/bin/sh` image, selected system shell
and Apple's missing-selector Bash default are handled without trusting process
display names. Startup shell builtins,
shells without prompt integration, background jobs, same-named shell helpers,
script tabs, and an unavailable process-table sample stay open. Starting a fresh
shell in a closed tab requires its original conversation and checkout to match.

Managed setup scripts run through the app-owned helper and show their output
in the setup banner, not in a terminal tab, so there is no setup terminal to
close after a successful setup run.

## Saved output and restart

Tabs, groups, their order within a conversation, selection, per-conversation
drawer visibility and height, titles, styled scrollback and plain-text
scrollback are saved in the workspace's private `TerminalHistory` directory. The
directory is mode `0700`; files are mode `0600`, atomically replaced and
flushed. Each window claims a separate archive. Files are bounded and
versioned; corrupt, unsafe or unsupported files are preserved with a visible
error. Restoration starts only after the workspace database loads successfully.
A second process that cannot acquire that database cannot restore or prune its
terminal archives. Older files without the newer fields still restore; their
window-wide drawer state applies to conversations with tabs.

Only existing conversation IDs restore; removed conversations do not inherit old
tabs. Output from an earlier checkout remains readable in its original pane when
the conversation moves, with resume disabled. New panes retain their own checkout
identity independently, so saving a new checkout never relabels old output.
Closing a tab removes its saved entry. Output is checkpointed every five seconds and at window
close and normal quit; an abrupt crash can lose the most recent interval.
Scrollback is encoded off the main thread, and only after new output.

Styled history is rebuilt from the emulator's cells, not recorded from PTY
bytes. It can contain only text, newlines, tabs and SGR color and style
sequences: no queries, replies, titles, clipboard or hyperlink controls, cursor
movement or mode changes, so replaying it cannot make the terminal answer or a
program act. Saved files are checked for exactly that form. Up to 5,000 lines
and 1 MiB of styled history and 256 KiB of plain text are kept per tab, 32 tabs
per window; when a window's file would exceed its budget, the largest tabs keep
only plain text.

Newly saved panes capture their conversation incarnation, project, exact checkout
path, preparation attempt, and physical checkout and launch-directory identities.
Automatic and manual resume both recheck that original capture against the current
conversation. Moving a conversation to another checkout or replacing its folder
never turns its saved pane into a shell in that new folder. Its output stays inert;
open a new terminal to capture the new checkout. Older archives without that
identity retain their output and require a new terminal too.

When a restored terminal is shown and its captured checkout becomes ready,
Coincide starts one fresh login shell in the same tab, below the saved output and
a dim separator, as T3 Code does. Readiness changes retry this check even when the
saved pane IDs remain the same. Keyboard focus stays where it was. Script tabs and terminals
closed on Settle stay as saved output with **Start Shell Here**. Turn off
**Start a new shell in restored terminals** in Settings to keep restored tabs as
saved output until you choose **Start Shell Here**. No saved command,
environment, process ID, escape sequence or clipboard control is ever replayed.
Saved output can contain whatever was printed in the terminal; it stays local to
this workspace's private app-data directory.

This is display restoration with a new shell, not process reattachment.
Commands that were running when Coincide quit are not restarted, and
alternate-screen applications, images and cursor state are not reconstructed.

## Remote workspaces

The remote window has a separate terminal panel. **New Terminal** explicitly
opens a host PTY; the local SwiftTerm view only renders output and forwards ordered
input and resize requests. Hidden tabs keep their sessions. Disconnect freezes
the transcript and closes the owned host; reconnect never opens a shell or repeats
input. Explicit attachment inspects the exact existing incarnation, and missing
output is restored as inert text with a visible gap notice. Remote transcripts
stay in memory for the current app lifetime. Remote terminals share the font
and color settings and offer Copy, Paste (while attached), Select All, Jump to
Latest and Find in their context menu. Splits, links, running indicators and
restart restoration are local-only. See
[remote terminal behavior and limits](REMOTE_ENVIRONMENTS.md#remote-terminals).

## Search and text size

The terminal header opens SwiftTerm's native Find interface. It searches the
emulator's retained scrollback, including text outside the visible rows, and
supports next/previous matches, case sensitivity, whole words and regular
expressions. Text-size choices are saved in app preferences and apply to live
and restored tabs.

## Evidence

Focused local checks exercise real PTY output and shutdown, cold restoration
without process launch, styled-history sanitization and replay, resuming a
fresh shell in a restored tab, shell fallback, `T3CODE_*` variables, split
group limits and persistence, per-conversation drawer state and height, clean
and failed shell exits, live child-process detection with a real `sleep`, idle
closure on Settle that keeps running commands, link resolution and routing,
context-menu actions, key mapping, tab selection/removal, independent window
claims, workspace changes, Unicode bounds, corrupt/symlink files and search
outside the viewport. The hosted project-script workflow additionally checks
restoration after normal Quit. A compiled hosted test is not a successful hosted
run; current run results are recorded in [VALIDATION.md](VALIDATION.md).
