# Coincide product and design direction

Updated by user direction on 2026-10-24. Coincide is a native Mac chat app for
**Codex and Claude**. The current goal is the native Codex/ChatGPT app experience;
the earlier full T3 feature-parity effort is paused.

## Reference and implementation

The visual reference is the actual downloaded desktop application at
`/Applications/ChatGPT.app`, version **26.1021.22027**, build **21747**, bundle
identifier `com.openai.codex`. Its Home, Codex/ChatGPT Work navigation, model menu
and General settings were inspected directly on 2026-10-24. Use that
installed application as the reference rather than the earlier Chrome-only
comparison. The rebuilt Coincide chat, sidebar, model menu and Settings were then inspected
with the local CLI screenshot command.

Build the product with **SwiftUI and narrow AppKit integrations**. Use native
windows, menus, popovers, sheets, text editing, keyboard navigation and accessible
controls. Do not replace the app with a website, Electron shell or embedded web
UI to imitate the reference.

## Chat-first layout

- Keep a compact sidebar with **New chat**, **Projects** and **Recents**. Projects
  expand into their chats. Keep search near the sidebar header and secondary
  actions in menus rather than rows of permanent controls.
- Give the conversation most of the window. Center the composer on the empty
  state and place it below messages once the conversation starts. Keep the text
  field, attachments, model selector and Send/Stop controls legible as the window
  resizes.
- Use one consistent system-font scale across the sidebar, chat, composer,
  popovers and Settings. Share spacing, icon sizing and control styles. Reserve
  monospaced text for code and technical identifiers.
- Follow system appearance with restrained surfaces and separators. Preserve
  readable contrast, selection, focus rings and accessible names. Provider logos
  identify the connected integrations; they are not the Coincide app identity.
- Keep tool output, approvals and questions in the conversation. Show details
  when needed without turning the default chat into an operations dashboard.
- Settings uses native navigation and the same typography as chat. Expose only
  controls that are connected to the supported app behavior.

The former inspector/files/Git panels, terminal drawer, remote-workspace scene,
project-action/worktree/settlement controls and run-history navigation are removed
from the current app UI. Do not reintroduce those entry points through toolbars,
menus, keyboard commands or Settings during this pass. Provider tool activity and
approval of provider requests remain part of chat. Historical implementations
may remain internally; this redesign does not claim every backend was deleted.

## Providers and conversation ownership

Codex and Claude are the supported connected providers. Use one searchable model
menu across those two configured CLIs; selecting a model selects its provider.
Settings controls model visibility. Show provider-native reasoning, effort,
permission, service-tier and interaction options only when actually supported.
Other retained provider schema/adapters are internal history, not selectable app
integrations or a reason to add more provider UI.

Coincide owns each chat's identity, messages, draft and imported history. Native
provider session IDs are execution bindings. Switching between Codex and Claude
preserves the conversation and stages portable context for the next explicit
send; switching itself must not start a turn. Running and queued inputs retain
their captured provider/settings, and switching must respect their ownership.

Imports copy conversations into Coincide. They must not resume or write back to
the source CLI session. New replies use an independent binding. Context handoffs
retain the bounded source archive, select public content within the input budget
and omit private reasoning and attachment bytes from text replay.

## Development and verification

Use the app's [local CLI](LOCAL_CONTROL.md) for navigation, model/catalog reads
and screenshots where available. Keep that control private to the local owner;
it is separate from provider-scoped app tools.

Automated tests are deferred by explicit user direction for this development
pass. Native build, signing and launch checks passed; the current UI was inspected
through CLI screenshots. Provider execution was not retested. Record new evidence in
[VALIDATION.md](VALIDATION.md); older porting/cloud documents remain historical
background, not the current UI specification. Preserve all attribution and
third-party license notices when retiring old surfaces.
