# Local provider feature coverage

Reviewed 2026-10-24 against installed **Codex CLI 0.164.0**, its running
**app-server 0.164.0**, and **Claude Code 2.1.308**. Coincide uses Codex's
app-server and Claude's stream-json/control interface. It does not embed their
TUIs, and using their executables does not provide every terminal feature.

**Implemented** means there is an app path and supporting code; it does not
mean every account, model, CLI version, or configured integration was exercised
live. **Conditional** means the provider must advertise/support the capability
and the saved conversation must satisfy its guards. **Not exposed** describes a
Coincide gap, not a claim that the provider has no API for it.

| Area | Codex | Claude | Current boundary |
| --- | --- | --- | --- |
| Chat and streaming | Implemented through app-server | Implemented through stream-json | Native transcript, tool activity, attachments, stop, queues and supported steering; not a terminal emulator. [Adapters](../Sources/CoincideCore/ProviderSession.swift), [Codex](../Sources/CoincideCore/CodexSession.swift), [Claude](../Sources/CoincideCore/ClaudeSession.swift). |
| Models and model options | Conditional live catalog, effort, service tier, Default/Plan | Conditional catalog, effort, fast mode, thinking/context options | Unified picker and visibility settings. Only supported controls should be offered; a catalog response does not prove model execution or billing availability. [Picker settings](../Sources/Coincide/Views/ModelPickerSettings.swift), [Claude options](../Sources/CoincideCore/ClaudeModelControl.swift). |
| Permissions | Implemented native sandbox/approval mapping | Implemented native permission-mode mapping | Per-conversation controls remain distinct from global CLI defaults and managed policy. Not every possible CLI permission override has a composer control. |
| Tools | Provider executes its available tools; app renders supported events | Same | Shell/file/search and configured integration tools remain provider capabilities. Coincide does not independently recreate every tool or terminal interaction. [Tool presentation](../Sources/Coincide/Views/ToolCardViews.swift). |
| Approvals and questions | Command/file, known MCP and user-input requests | `can_use_tool`, including supported user questions | Known requests have native UI. Unknown interactive protocols fail explicitly; they are not silently approved. [Approval UI](../Sources/Coincide/Views/ApprovalView.swift). |
| Skills | Native `skills/list` plus local discovery/import | Native/local skill discovery and dispatch | Separate Skills page; reusable instruction/assets can be copied into Coincide and inserted into a draft. This is not automatic execution. [Discovery](../Sources/CoincideCore/ProviderIntegrationDiscovery.swift), [skill dispatch](../Sources/CoincideCore/ClaudeSkillDispatch.swift). |
| Slash commands | App commands and imported saved instructions | App commands, advertised provider commands and imported instructions | `/app:*` is Coincide's namespace. Codex TUI built-ins are not automatically translated to app-server actions. Claude's advertised commands are not a promise that every terminal-only slash command works. [App commands](../Sources/Coincide/Views/CoincideSlashCommand.swift), [Claude commands](../Sources/CoincideCore/ClaudeCommands.swift). |
| MCP servers | Discover configured metadata; selected enable settings | Discover configured metadata; selected project approval/disable settings | Separate MCP page. Imports link to original configuration/authentication; they do not copy secrets, migrate a server across providers, connect/test it, or complete OAuth. Add/remove/authenticate workflows are not fully exposed. |
| Plugins | Discover installed/configured plugin metadata; existing plugin enable flags editable | Same | Separate Plugins page. Linked import is a library reference, not installation or activation. No complete marketplace/install/update/uninstall UI. |
| Hooks | Discover configured hook metadata | Same; global disable setting editable | Separate Hooks page. CLI owns execution. Discovery/import never runs a hook; no full hook-command authoring UI. |
| CLI configuration | Allowlisted TOML defaults, existing feature/MCP/plugin toggles | Allowlisted JSON defaults, permission rules, existing plugin flags | User/project/local availability depends on provider. Revision checks prevent overwriting a file changed since review. Secrets, arbitrary fields and every CLI flag are not exposed. [Editor](../Sources/CoincideCore/ProviderConfigurationEditor.swift). |
| Local background/session management | Existing daemon list, public recent turn summaries, exact current-turn interrupt | `agents --json --all`; background logs/stop | Separate Agent sessions page. Saved/unloaded Codex history is not called running; standalone processes may lack daemon status. Claude interactive terminals cannot be stopped/read through background-only commands. [Sessions](../Sources/CoincideCore/ProviderSessions.swift). |
| Resume a provider-owned session | Copy exact terminal resume command | Copy exact resume/attach command | Explicit command affects the original provider session. Coincide never auto-attaches it when browsing; importing a copy remains separate. |
| Saved history, fork and rewind | Conditional reviewed 0.163 profile and stable 0.164.0 paginated-history contracts | Conditional validated transcript boundaries and captured runtime identity | Native review/guards exist. Unsupported versions, uncertain outcomes, changed sources and unsafe boundaries are refused. A rewind is not an unconditional filesystem rollback. [Codex history](../Sources/CoincideCore/CodexHistoryClient.swift), [Claude history](../Sources/CoincideCore/ClaudeHistoryService.swift), [review UI](../Sources/Coincide/Views/ConversationHistoryReviewSheet.swift). |
| Import conversations | Project-scoped local transcript import | Same | Import creates a Coincide-owned copy; future replies use an independent binding rather than continuing the original CLI session. Imported history may not include every provider-private event. [Import](../Sources/CoincideCore/AgentSessionImport.swift). |
| Switch providers in one chat | Implemented | Implemented | Coincide owns the transcript and prepares portable historical context for the next provider. This does not transfer private reasoning, native runtime state or unlimited context verbatim. [Context handoff](../Sources/CoincideCore/ContextHandoffService.swift). |
| Context and compaction | Conditional native manual compaction for the active owned session | Same, plus supported auto-compact threshold and reported usage | Chat action and `/app:compact` require confirmation; `compact --confirm` has matching local control. The session must be idle and owned by Coincide. Progress, provider-confirmed completion and uncertain outcomes are distinguished; visible history and drafts stay unchanged. Native capability checks may reject unsupported connections. A configured auto-compact threshold alone does not prove compaction. [Operation](../Sources/CoincideCore/ContextCompaction.swift), [controls](LOCAL_CONTROL.md). |
| Export | Coincide-owned conversation to Markdown/JSON | Same | Native Save and local CLI export current public history; individual plan/attachment save also remains. Private reasoning, rewound messages, runtime credentials/configuration and attachment bytes are excluded. Visible chat/tool text is included as written. Tool text above 256 KiB is explicitly marked as truncated; oversized complete transcripts fail clearly. [Exporter](../Sources/CoincideCore/ConversationExport.swift). |
| Terminal-only flags and shortcuts | Not fully exposed | Not fully exposed | No arbitrary launch-argument editor, full TUI keymap, terminal pager/editor modes, or every experimental flag. Use the provider CLI for these workflows. |
| CLI control of Coincide | Implemented local-owner control | Same | Inspect/navigate chats, models, integrations, settings and provider sessions through `script/coincide`; session stop requires exact ID plus `--confirm`. This is not a headless model runtime. [Commands](LOCAL_CONTROL.md). |

The integration pages share [discovery](../Sources/CoincideCore/ProviderIntegrationDiscovery.swift),
[library semantics](../Sources/CoincideCore/ProviderIntegrationLibrary.swift), and
[native UI](../Sources/Coincide/Views/ProviderIntegrationsView.swift). Skills and
saved commands are **independent copies**. MCP servers, plugins and hooks are
**links to original provider configuration**, retaining its provider and account
scope. Importing one does not enable it for the other provider.

## What this audit verified

- Read-only version checks for both CLIs and the managed Codex daemon.
- Claude's installed `agents --json --all` output includes interactive and
  background rows; their actions are deliberately different.
- A native Unix WebSocket connection to the existing Codex daemon completed
  initialization and metadata-only `thread/list`, returning active and unloaded
  session states. No daemon or conversation was started.
- The installed Codex 0.164.0 experimental schemas were compared with the
  official 0.163.0/0.164.0 protocol definitions. Existing history requests remain
  compatible; the added fork prediction flag is unused. The gate accepts stable
  0.164.0 specifically, not all future 0.164 releases.
- Native Default/Plan requests now send `developer_instructions: null`, which
  [Codex documents as using its built-in instructions for the selected mode](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/app-server-protocol/src/protocol/v2/turn.rs).
  Coincide keeps the explicit mode/model/effort and no longer injects the copied
  T3 mode prompt.

Source review and offline tests do not establish live execution of every model,
tool, MCP server, plugin, hook, stop, history mutation or compaction path. This
audit deliberately sent no model prompts and did not stop, resume, fork or
rewind the user's actual provider sessions. Build/CI results should be reported
separately for the exact tested commit.

## Remaining local work

Conversation export now has a dedicated public-history serializer and native
Save flow, shared with the local CLI. It operates on a captured Coincide
conversation without attaching to or resuming a provider. JSON version 1 is a
portable transcript format, not an app database backup or a promise of reimport.

Further local work includes MCP connection/auth management, plugin
installation/update controls, hook editing, and additional supported CLI settings.
Each needs its own protocol and behavior checks. Native compaction is implemented
conditionally; offline protocol fixtures do not establish successful execution
against a live model or every installed provider version.

Cloud/remote control is intentionally outside this local milestone. None of the
above constitutes full Codex/Claude TUI feature parity.
