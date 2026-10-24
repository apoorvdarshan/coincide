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
