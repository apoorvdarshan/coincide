# Local CLI control

Open Coincide, then use `script/coincide` in a source checkout. In a packaged app,
**Settings → General → Command-line tool** installs the `coincide` command. Its
folder-opening behavior remains available as `coincide /absolute/project/path`.

Commands return JSON. None sends a prompt to a model.

```sh
./script/coincide status
./script/coincide projects
./script/coincide threads --project coincide
./script/coincide thread
./script/coincide providers
./script/coincide models --all --refresh
./script/coincide ui --settings models
./script/coincide ui --chat --sidebar hide
./script/coincide ui --model-picker
./script/coincide ui --display built-in
./script/coincide sort
./script/coincide sort --projects newest --chats priority
./script/coincide screenshot /tmp/coincide-window.png
./script/coincide screenshot /tmp/coincide-picker.png --popover
```

- `select THREAD_UUID` selects a saved chat. `new PATH` creates an empty chat.
- `model codex MODEL_ID` or `model claude MODEL_ID` selects an advertised model
  and its provider. `--thread THREAD_UUID` targets a different saved chat.
  Use `models --all` to obtain IDs; use an empty string for the CLI default.
  Changing providers preserves the Coincide chat and prepares its saved history
  for the next message. Busy chats must finish their reply and queued messages
  before switching providers. Model selection itself sends no prompt.
- `models --refresh` refreshes the selected chat's catalog. `--all --refresh`
  reads both available CLI catalogs. Catalog reads do not prove model execution.
- `ui --settings PAGE` accepts `general`, `appearance`, `notifications`, `providers`,
  `models`, `conversations`, `keyboard`, and `about`. It opens embedded Settings
  in the existing main window, using the same navigation state as the app menu
  and ⌘,. `ui --chat` returns to the selected conversation without creating one.
- `ui --display built-in` fits and centers the existing main window on the Mac's
  built-in display without activating it. It fails when that display or the
  main window is unavailable. Status includes `display`, `onBuiltInDisplay`
  (the whole window fits in the display's usable frame), `fillsUsableScreen`,
  and `windowCount`. New main windows fill the usable screen area, leaving the
  menu bar and Dock available. You can resize the window afterward.
- `sort` reads the saved choices and current sidebar IDs. `--projects` and
  `--chats` independently accept `newest`, `active`, `priority`, `name`, or
  `custom`. Priority puts pinned items first. The sidebar has matching sort
  menus beside Projects and Recents. With Custom selected, right-click an item
  and choose Move up or Move down. Custom positions survive other sort choices
  and app restarts; newly created chats appear at the top of the custom list.
  The CLI can also move items: `sort --move-chat UUID --direction up` or
  `sort --move-project UUID --direction down`, with the corresponding sort
  set to Custom. Chat moves use the currently visible (filtered) chat list.
- `screenshot` writes a new PNG and refuses to overwrite a file. `--popover`
  captures the single visible native popover, refusing ambiguity. Native content
  rendering may omit system-composited chrome; it is not a full screen capture.

The Python client uses Coincide's authenticated loopback service. The local-owner
credential is held in a private `Control` directory under Application Support;
it is separate from provider-scoped MCP sessions and is never passed to agents.
The client rejects non-loopback endpoints and redirects. Do not copy its
connection file into projects, logs, or automation output.

This is control of the running native app. It is not yet a standalone headless
agent runtime or a public network API.

For a new development launch, pass `--display=built-in --background` to the app
executable. The first option places each main window on the built-in display;
the second suppresses Coincide's explicit app activation for launch, Settings,
and conversation links. Use a background-capable launcher too: the flags cannot
prevent an external launcher from activating the app. With no flags, normal
macOS chooses the display and the app fills its usable area. These options are per launch,
not saved user preferences. `--display=built-in` requires an available built-in
screen to override placement; it does not alter external-monitor settings.
