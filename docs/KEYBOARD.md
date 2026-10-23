# Keyboard shortcuts and the command palette

Coincide follows T3 Code's keybinding model (`docs/user/keybindings.md` at the
pinned revision) in a native macOS window. Menus, the command palette and the
keyboard dispatcher all read the same rules, so a change in Settings → Keyboard
or in `keybindings.json` updates menu shortcuts, palette labels and key handling
together.

## Configuration file

Rules live in `~/Library/Application Support/Coincide/keybindings.json`, beside
the workspace database (UI-test runs use their isolated test root). It is a JSON
array of `{ "key", "command", "when" }` rules:

```json
[
  { "key": "mod+g", "command": "terminal.toggle" },
  { "key": "mod+j", "command": "rightPanel.toggle", "when": "terminalOpen && !terminalFocus" }
]
```

- The first launch writes the defaults below. Later launches append defaults for
  commands the file does not mention, before your rules, and skip a default whose
  shortcut and condition you already use. Nothing is backfilled while the file
  has issues. One-time late defaults are recorded in `keybindings-migrations`.
- `//` and `/* */` comments and trailing commas are accepted.
- An invalid entry is ignored and reported; a file that is not a JSON array is
  reported and the defaults apply. A non-blocking warning in the main window
  offers **Open keybindings.json** and **Show in Finder**.
- Saving the file in any editor (in place or by atomic rename) reloads it within
  about 100 ms and briefly shows "Keybindings updated".
- A command that appears in the file replaces all of that command's defaults.
  Removing every rule for a command restores its defaults on the next start.
- At most 256 rules apply; the newest are kept.

### Key syntax, conditions and precedence

Exactly as T3: modifiers and one key joined by `+` (`mod+shift+[`, `mod++`,
`ctrl+space`, `esc`). `mod` is Command. `cmd`/`meta`, `ctrl`/`control`,
`alt`/`option` and `shift` are accepted. Shifted punctuation and digits match by
key position, so `mod+shift+[` matches ⇧⌘[ on a US layout, and letters match by
position on non-Latin layouts.

`when` combines context keys with `!`, `&&`, `||` and parentheses (nesting up to
64, 256 characters). Unknown keys are false. Coincide sets:

| Key | True when |
| --- | --- |
| `terminalFocus` | a terminal has keyboard focus |
| `terminalOpen` | the terminal panel is shown |
| `editableFocus` | the composer, a text field or the file editor has focus |
| `composerFocus` | the composer has focus |
| `fileEditorFocus` | the inspector's file editor has focus (Coincide) |
| `composerDraft` | the selected thread has unsent text |
| `turnRunning` | the selected thread is working |
| `draftThreadRoute` | the selected thread has no messages yet |
| `rightPanelOpen`, `inspectorOpen` | the inspector is shown |
| `commandPaletteOpen`, `threadFindOpen` | the palette or thread find is open (Coincide) |
| `isDesktop` | always true; `isWeb` is always false |
| `previewFocus`, `previewOpen`, `usagePageOpen`, `modelPickerOpen` | always false (no such surface yet) |

The last rule whose shortcut and condition both match wins, even across commands.

## Default shortcuts

| Command | Shortcut | Notes |
| --- | --- | --- |
| `commandPalette.toggle` | ⌘K | not in a terminal |
| `sidebar.toggle` | ⌘B | View menu |
| `terminal.toggle` | ⌘J | the toolbar also keeps ⌥⌘T |
| `rightPanel.toggle` | ⌥⌘I, ⌥⌘B | Toggle Inspector |
| `diff.toggle` | ⌘D | Show Changes in the inspector; not in a terminal |
| `filePicker.toggle` | ⌘P | Go to File: inspector Files, path search focused |
| `projectSearch.toggle` | ⇧⌘F | Search Project Contents: inspector Files, content search |
| `chat.find` | ⌘F | Find in the current thread; terminals and the file editor keep their own Find |
| `navigation.back` / `navigation.forward` | ⌘[ / ⌘] | thread history; not in a terminal |
| `thread.previous` / `thread.next` | ⇧⌘[ / ⇧⌘] | sidebar order, no wraparound |
| `thread.jump.1`…`9` | ⌘1…⌘9 | first nine visible threads; holding ⌘ shows hints |
| `thread.stop` | ⌘. | Coincide default (T3 leaves it unbound) |
| `thread.copyReference` | ⇧⌘C | copies the thread ID |
| `thread.settle` | ⇧⌘S | Settle, or Resume a settled thread |
| `thread.pin` | ⇧⌘P | Pin or unpin |
| `view.reopenClosed` | ⇧⌘T | reopens the last hidden inspector view |
| `theme.select` | ⌥⌘A | opens Change Appearance in the palette |
| `appearance.cycle` | ⌥⇧⌘A | System → Light → Dark |
| `chat.new` | ⌘N | New Thread in the current project |
| `project.new` | ⇧⌘N | Coincide; T3 uses this for `chat.newLocal` |
| `project.add` | ⌘O | Coincide; T3 uses this for `editor.openFavorite` |
| `project.clone` | ⇧⌘O | Coincide |
| `window.new` | ⌥⌘N | Coincide; T3 uses this for `chat.newWithoutProject` |
| `remote.open` | ⌥⌘R | Coincide |
| `terminal.new`, `terminal.close`, `terminal.split`, `terminal.splitVertical` | ⌘N, ⌘W, ⌘D, ⇧⌘D in a terminal | reserved for the terminal; not dispatched yet |

`chat.newLocal`, `editor.openFavorite` (open the workspace in the preferred
editor) and `project.import` are available without a default. Other T3 command
IDs (preview, usage, model picker, composer pickers, `thread.undo` and others)
are accepted in the file for compatibility but do nothing yet; Settings marks
them. `script.{id}.run` rules are accepted and listed but do not run scripts yet.

The composer keeps its built-in keys: Return sends, ⇧Return or ⌥Return inserts a
new line, ⌘Return uses the opposite Queue/Steer action, ⌘S stashes the prompt
and ⇧⌘V pastes plain text.

## Settings → Keyboard

Lists every rule by group with its shortcut, condition and source (Default,
Custom or Project), conflicts with other commands, and a search over labels,
IDs, keys and conditions. Edit records a shortcut from the keyboard (Escape
cancels) or accepts typed key syntax, validates the condition and warns about
unknown context keys. Custom rules can be reset to their default or removed;
Add Shortcut creates a rule for any available command.

## Command palette

⌘K opens a palette over the window. With no query it lists actions and the 12
most recent threads; typing searches actions, projects, settings and all threads
(message text from two characters). Start with `>` for actions only. Arrow keys
move, Return chooses, ⌘1–⌘9 choose an entry directly, Delete on an empty query or
Escape leaves a submenu, and Escape or ⌘K closes. **New Thread In…** chooses a
checkout; **Change Appearance** chooses System, Light or Dark. Closing returns
focus to the composer.

## Focus

- The palette and thread find keep focus while open and return it to the
  composer when they close.
- Typing a printable character (or ⌘V) while nothing editable or interactive has
  focus moves focus to the composer and keeps the typed text.
- A terminal takes focus when you open it, create a tab or switch tabs. Restoring
  saved terminals and switching threads leave the composer focused, and a
  terminal that attaches after you returned to typing does not take focus.

## Native menus

Menu items show the shortcut configured for their command. A key whose rule does
not apply in the current focus (for example ⌘K in a terminal) is not run by the
menu either; ⌘F in a terminal or the file editor opens that view's own Find. The
remote window publishes no main-window target, so these commands disable there.
