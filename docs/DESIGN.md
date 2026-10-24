# Coincide product direction

Updated by user direction on 2026-10-24. Build a native macOS coding app focused
on **Codex and Claude**. Full T3 Code parity and cloud-worker work are paused.

- Follow the user's ChatGPT desktop screenshots: New chat, Projects and Recents
  in the sidebar, expandable projects with nested chats, and a centered composer. Search lives in
  the header; sorting controls do not occupy the main sidebar.
- Keep file editing, Git, terminal, approvals and useful existing functionality
  available without making the default chat look like a dashboard.
- Build in SwiftUI with narrow AppKit integrations, native menus and accessible
  controls. Follow system appearance, resizing and keyboard navigation.
- Operate the app through the local CLI where available. Computer-use automation
  is not the default development interface.
- During this development pass, prioritize incremental builds and live use.
  Automated test runs are explicitly deferred; do not claim unrun checks passed.
- Other providers are removed from the supported app. Historical schema types
  remain internal to the existing persisted format, not selectable integrations.

The next priorities are reliable new/resumed Codex and Claude conversations,
complete session import, a clean chat UI, and direct CLI control.

The composer offers one searchable model list across installed Codex/Claude
runtimes. Selecting a model selects its provider. Settings → Models controls
which rows appear by default; All models reveals the rest. Use provider-native
permission names and advertised model capabilities rather than generic T3
configuration labels. Provider marks identify integrations, not Coincide itself.

Coincide owns the conversation, including its messages, draft, and imported
history. Switching providers keeps that same conversation and stages portable
context for the next explicit message. Provider session IDs are execution
bindings, not the identity of a Coincide chat. Imported transcripts are copied:
new replies start an independent session and never resume the source CLI ID.
Older imports detach before their next submission; old queued continuations are
paused rather than resumed against the original session. Context transfers keep
the full bounded import/archive locally, select public text within an input
budget, and omit private reasoning and attachment bytes from replay.

Settings is a full-window sidebar with Personal and Coding pages. Scheduling,
automatic settlement, checkpoints and context-transfer controls are removed from
the primary chat/settings UI. Their historical persistence/runtime code is not
purged in this visual pass. File, Git and terminal tools remain available.

On 2026-10-24 the reference was inspected in the user's Chrome with explicit
approval: home, model/effort menus, General and Appearance. The native desktop
app was not installed; the user subsequently accepted Chrome as the reference.
