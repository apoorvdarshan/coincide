# Local CLI control

Open Coincide, then use `script/coincide` in a source checkout. In a packaged app,
**Settings → General → Command-line tool** installs the `coincide` command. Its
folder-opening behavior remains available as `coincide /absolute/project/path`.

Commands return JSON and never submit your unsent draft. `compact` explicitly
asks the active provider to summarize its context, which may use model tokens.

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
./script/coincide sessions codex
./script/coincide sessions claude
./script/coincide session-details claude CLAUDE_SESSION_ID
./script/coincide integrations --kind skills --provider claude
./script/coincide configuration codex --scope user
./script/coincide export /tmp/conversation.md
./script/coincide export /tmp/conversation.json --format json --thread THREAD_UUID
./script/coincide compaction --thread THREAD_UUID
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
  `models`, `conversations`, `keyboard`, `about`, `skills`, `commands`, `mcp`,
  `plugins`, `hooks`, `configuration`, and `sessions`. It opens embedded Settings
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
- `export PATH --format markdown|json` exports a captured conversation to a new
  private file (0600) and refuses existing files or symlinks. `--thread UUID`
  selects a saved chat; otherwise it uses the currently selected chat. The chat
  header's Conversation actions menu offers the same formats through a native
  Save sheet. Exports include visible message text and attachment names/types/sizes,
  excluding private reasoning, rewound messages, drafts, attachment bytes and
  provider state. Tool output beyond 256 KiB per message is marked as truncated.
  JSON is a portable public transcript, not a database backup/import format.
- `compaction --thread UUID` reads manual compaction availability and the latest
  saved operation. `compact --thread UUID --confirm` requests compaction for the
  exact idle provider connection owned by Coincide. Omit `--thread` to use the
  selected chat. A copied import or saved history without an active independent
  connection is unavailable; send a normal reply first. Busy or queued work,
  approvals and conflicting conversation operations also block compaction.
  The chat's Conversation actions → Compact context and `/app:compact` open a
  native confirmation for the same operation. Cancellation preserves the draft,
  including a typed `/app:compact` command. Completion does not clear that draft.
  No public messages are removed or replaced by the provider's private summary.
  An accepted request can still fail if the provider does not support the native
  operation. Only `completed` confirms success; `pending`/`running` are progress,
  and `unconfirmed` means the request may have run. Read `compaction` again before
  retrying a failed or lost CLI response; requests are never retried automatically.
  `requestAccepted: true` confirms durable acceptance, not completed compaction.
  The progress banner offers Stop. CLI cancellation requires the exact operation:
  `compaction-cancel --thread UUID --operation OPERATION_UUID --confirm`. It closes
  only that owned provider runtime; a request already dispatched can remain
  `unconfirmed`. The operation's public conversation and draft remain intact.

The Python client uses Coincide's authenticated loopback service. The local-owner
credential is held in a private `Control` directory under Application Support;
it is separate from provider-scoped MCP sessions and is never passed to agents.
The client rejects non-loopback endpoints and redirects. Do not copy its
connection file into projects, logs, or automation output.

This is control of the running native app. It is not yet a standalone headless
agent runtime or a public network API.

## Integrations and configuration

`integrations` discovers local CLI integration metadata. Filter with
`--provider codex|claude` and `--kind skills|commands|mcp|plugins|hooks`.
Use an exact integration ID from that response with:

```sh
./script/coincide integration-import INTEGRATION_ID
./script/coincide integration-remove INTEGRATION_ID
./script/coincide integration-use INTEGRATION_ID
```

Skills and saved commands import as Coincide library copies. MCP servers,
plugins and hooks import as references to their original provider configuration,
without copying credentials or activating them in another provider. Removing
an import removes only its Coincide copy/reference. Use adds a supported item
to the selected conversation's draft without sending it. Discovery and import
do not execute hooks, start MCP servers, or install provider plugins.

`configuration PROVIDER --scope user|project|local` reads supported structured
settings from the selected runtime and project. Available scopes and fields
depend on the provider. The response includes field IDs, allowed controls,
editability, notices, and a review ID valid for 300 seconds. To save one field:

```sh
./script/coincide configuration-set REVIEW_ID FIELD VALUE
```

Each review ID can be used once. The editor checks that the source file is
unchanged since the read and rejects a stale review. It accepts only the
supported nonsecret fields; credentials and arbitrary CLI configuration are
not exposed through this interface. An empty value removes the selected
scope's override where supported. Read configuration again after each save.
Provider-owned settings may require a new CLI session to take effect.

Expired, consumed, or stale configuration reviews return a recovery error. Read
`configuration` again for the same provider and scope, review the current fields,
then submit a new `configuration-set` request. Validation failures also consume
the review ID. Integration failures ask you to refresh `integrations` and check
the selected workspace and item ID; completed imports remain available. The CLI
does not retry either action automatically or display arbitrary provider errors.

## Local provider sessions

**Settings → Sessions** and `sessions codex|claude` inspect sessions owned by
the selected CLI configuration. They are separate from Coincide's saved chats.
Use the exact `id` returned by `sessions` with `session-details PROVIDER ID` to
read bounded recent output and obtain a terminal resume command. Copying that
command does not execute it. Running it continues the original provider session;
**Import a copy** instead creates an independent Coincide conversation.

- Codex uses its existing WebSocket control socket at
  `<CODEX_HOME>/app-server-control/app-server-control.sock`. It never starts a
  daemon or resumes a thread for inspection. It lists up to 200 recent sessions,
  including subagents, and reads up to 10 recent public turn summaries. A saved
  thread without a live daemon status is shown as **Saved · not loaded**.
  Standalone Codex processes that do not share this daemon may not appear as
  running. Internal reasoning and tool output are excluded from this view.
- Claude uses `agents --json --all`. Background sessions support recent terminal
  output through `logs`; interactive sessions remain controlled in their
  original terminal. These commands require a Claude Code version that exposes
  the session-management commands.
- `session-stop PROVIDER ID --confirm` affects the original provider session.
  It refreshes and revalidates that ID first. Codex interrupts only an exact,
  freshly identified active turn; Claude stops the selected background session.
  The response confirms the provider accepted the request, so refresh the list
  to observe its resulting state. There is no automatic retry after a lost reply.

The native page confirms Stop before acting. Unknown states never enable Stop.
Provider errors do not start a fallback process. This surface does not provide
cloud/remote control, arbitrary TUI shortcuts, or full CLI feature parity.

For a new development launch, pass `--display=built-in --background` to the app
executable. The first option places each main window on the built-in display;
the second suppresses Coincide's explicit app activation for launch, Settings,
and conversation links. Use a background-capable launcher too: the flags cannot
prevent an external launcher from activating the app. With no flags, normal
macOS chooses the display and the app fills its usable area. These options are per launch,
not saved user preferences. `--display=built-in` requires an available built-in
screen to override placement; it does not alter external-monitor settings.
