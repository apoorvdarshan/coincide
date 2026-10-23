# Coincide product direction

Updated by user direction on 2026-10-24. Build a native macOS coding app focused
on **Codex and Claude**. Full T3 Code parity and cloud-worker work are paused.

- Follow the user's ChatGPT desktop screenshots: New chat, Projects and Recents
  in the sidebar, a centered conversation, and a provider/model menu in the composer.
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
