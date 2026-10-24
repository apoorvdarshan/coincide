# Changelog

All notable changes to Coincide are listed here. Versions follow
[Semantic Versioning](https://semver.org/).

## 0.1.0 — 2026-10-24

First tagged pre-release. Coincide is a native macOS app for the Codex and
Claude Code CLIs. It uses your existing CLI installations and sign-ins.

### Features

- Chat with Codex and Claude: streaming replies, tool calls, approvals and
  questions, files and images, Stop, Queue and Steer.
- One model picker across providers, with reasoning effort, speed and
  permission controls where the provider supports them.
- Saved chats and drafts, projects, search, pinning, archiving, and sorting by
  Newest, Recently active, Priority, Name or Custom order.
- Switch providers within a chat with a saved-context handoff; import CLI
  sessions as independent Coincide copies.
- Manual context compaction (`/app:compact`, the chat menu or
  `coincide compact`), and Markdown/JSON export.
- Skills, Commands, MCP, Plugins and Hooks pages that read your Codex and
  Claude setups; skills and commands can be imported.
- Provider configuration editor, agent session management, worktrees,
  checkpoints and diffs, pull request creation and checkout, project scripts
  and a terminal.
- Local `coincide` CLI for status, chats, models, sending, compaction, export,
  integrations, configuration, sessions and screenshots.

### Removed

- Pi, OpenCode, ACP (Cursor, Grok, Copilot), Antigravity and Muse providers.

### Fixed

- The packaged app crashed on Macs without the local build folder when it drew
  a provider logo.
- Debug builds could overflow a worker thread's stack in the workspace reducer.
- Settings now reads the Codex CLI account automatically, and chats started
  without a project show as selected in Recents.
- The `coincide` CLI reports malformed connection files and replies instead of
  crashing, and accepts only the exact local endpoint the app writes.
