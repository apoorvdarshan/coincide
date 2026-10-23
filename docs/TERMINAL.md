# Native terminal behavior

Coincide runs local shells in SwiftTerm PTYs. Each window owns its own tabs;
hiding the terminal or selecting another conversation preserves those processes.
Closing a running command asks for confirmation. Closing the window or quitting
drains the owned processes using the existing shutdown escalation.

## Saved output and restart

Tabs, their order within a conversation, selection, panel visibility, titles,
and bounded plain-text scrollback are saved in the workspace's private
`TerminalHistory` directory. The directory is mode `0700`; files are mode `0600`,
atomically replaced and flushed. Each window claims a separate archive. Files are
bounded and versioned; corrupt, unsafe or unsupported files are preserved with a
visible error. Restoration starts only after the workspace database loads
successfully. A second process that cannot acquire that database cannot restore
or prune its terminal archives.

Only matching conversation IDs and exact workspace paths restore. Removed
conversations and changed workspaces do not inherit old tabs. Closing a tab
removes its saved entry. Output is checkpointed every five seconds and at window
close and normal quit; an abrupt crash can lose the most recent interval.

Restored tabs show saved output and a disconnected label. They start no shell,
send no terminal input, and replay no saved command. **New Terminal** starts a new
shell in the current conversation workspace. Script commands, environments,
process IDs, escape sequences and clipboard controls are not restoration data.
Display capture retains up to 256 KiB per tab and 32 tabs per window. Saved output
can contain whatever was printed in the terminal; it stays local to this
workspace's private app-data directory.

This is cold display restoration, not process reattachment. ANSI styling,
alternate-screen applications, images and cursor state are not reconstructed.
Live terminal survival across app/server restart, remote replay/attachment,
split groups, activity detection and idle-tab policies remain parity gaps.

## Search and text size

The terminal header opens SwiftTerm's native Find interface. It searches the
emulator's retained scrollback, including text outside the visible rows, and
supports next/previous matches, case sensitivity, whole words and regular
expressions. Text-size choices are saved in app preferences and apply to live
and restored tabs.

## Evidence

Focused local checks exercise real PTY output and shutdown, cold restoration
without process launch, tab selection/removal, independent window claims,
workspace changes, Unicode bounds, corrupt/symlink files and search outside the
viewport. The hosted project-script workflow additionally checks restoration
after normal Quit. A compiled hosted test is not a successful hosted run; current
run results are recorded in [VALIDATION.md](VALIDATION.md).
