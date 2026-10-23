# Native provider parity inventory

Coincide's completion requirement is native Swift, end-to-end support for **all
T3 Code provider integrations**, including Claude, Codex, OpenCode, Copilot,
Cursor, Grok, Antigravity, Pi, Muse Code, and ACP Registry agents. A selectable
name, executable path, preset, successful handshake, or passing protocol fixture
does not by itself establish a working integration or complete parity.

This inventory was checked on 2026-10-22 against
[T3 Code `680152e27b2a961686389ca69a1557cbb2c55f08`][t3-root], the native
implementation, its tests, and the official protocol references below. Current
vendor documentation can describe versions newer than the pinned T3 adapters;
implementation must negotiate or verify capabilities rather than assume that
the two contracts are identical. Runtime observations below are recorded prior
verification, not provider calls repeated for this document. Consult
[VALIDATION.md](VALIDATION.md) for their circumstances and limitations and
[PORTING.md](PORTING.md) for the broader port scope.

The separate default Liquid Glass requirement also remains mandatory. Provider
integration work does not satisfy the native chrome, control, accessibility,
older-macOS fallback, or actual visual-verification requirements.

Claude Run History now connects prospective input/root UUID and captured-runtime
proof to durably reserved native fork, T3's inclusive deferred context selection,
one consuming explicit successor, inherited/fresh reset, read-only recovery and
the reviewed workspace-file/prompt-recall flow. Seven independent synthetic SDK
oracle cases cover the underlying reader/fork transform; current-batch test
results are recorded separately. Installed CLI 2.1.304 differs from the pinned
SDK 0.3.276 profile: four generated installed turns verify native fork and
deferred-rewind context recall, unchanged-source proof and SQLite restart.
Broader installed model/history/resume compatibility and hosted history UI
acceptance remain unverified. Legacy history stays gated and no
`resumeDropsTurn` launch is enabled. See [the exact boundaries](CLAUDE_HISTORY.md).

The Codex owned-auth Core layer has offline coverage for PKCE/JWT verification,
the native loopback callback, Keychain byte storage and saved registrations,
serialized rotating credentials, explicit sign-in/cancel/logout coordination,
shared-history/private-auth home layout and literal token-sharing launch values.
It is now connected to production workspace/runtime/Settings through explicit
owned mode, captured opaque account bindings, joined account-change admission
and lazy private-environment process launch. Accordingly, real managed account
acceptance remains unfinished. No real ChatGPT sign-in or owned model execution
is claimed by the synthetic OAuth and stdio tests; signed Keychain acceptance
is recorded separately in VALIDATION.md.

Native Codex skills use a bounded `skills/list` read for the exact physical
workspace and captured runtime/account. Its separate metadata connection cannot
retarget an active turn. The native chooser and typed `$`/optional `/skill:`
suggestions insert the advertised literal `$name ` into the latest draft; skill
files are never read or copied by this feature. Disabled or non-user-invocable
rows are excluded from insertion, and partial/unsupported inventories remain
distinct. Pi and OpenCode now have scoped native command/skill inventories and composer
pickers with offline Engine, protocol and native view checks. Pi expands inline
skills through an owned input bridge with native digest proof; OpenCode v1
supports one leading native skill command, while v2 attaches exact native skill
IDs. Native slash commands and compaction are implemented for these providers.
Other providers' commands/skills and hosted picker acceptance remain unfinished.

App MCP now has source implementation for a native Swift loopback server,
provider-session header leases, 30 capability-filtered tools and durable Engine
mutations. Captured Pi sessions register those tools through the same awaited
extension as permission handling and authored-input proof. Only fresh exact
active runs can write; background writes and other providers' registration remain
gaps. The supported MCP profiles are 2025-06-18 and 2025-11-25. Current-batch
verification is pending; no live provider/authentication or full-parity claim is
made here. See [the MCP contract and unsupported variants](MCP.md).

Pi and Muse active steering are now implemented in native source, with new
offline steering fixtures passing focused checks and the full local serial suite. Pi uses an explicit
adapter-run fence instead of a native turn ID; new captured runs retain separately
validated native entry evidence. Its atomic prompt command provides admission ACK
evidence only. Muse uses native `expectedTurnId`,
UUIDv7 commands and matched native steered user-message evidence. Storage 34
preserves the typed target distinction in durable steering records. No installed
Pi or Muse calls were made, and these additions do not establish full parity.

OpenCode v2 now has source implementation for bounded message-ordered history,
reviewed fork and history-only rewind. Exclusive message cuts retain whole runs
and steers; cloned-ID proof compares the complete normalized semantic prefix.
Rewind stages `files: false` before commit. An explicit durable clear requires
an exact empty native execution and its terminal-derived idle receipt; storage
35 retains this recovery evidence. Local protocol, Engine, reducer and native
view checks pass in the full serial suite; installed and hosted history
acceptance remain unverified. V1 history now has source implementation for exact native clone-and-adopt cuts,
durable candidate publication, immutable input mapping across repeated rewinds and
explicit keep-original recovery. Its local protocol, Engine, reducer and native view checks pass; no
installed or hosted v1 history acceptance is claimed. ACP history remains a
separate unfinished path. See [the native history contract](OPENCODE_HTTP.md#native-opencode-2-history).

## Inventory and evidence

The pinned [built-in driver registry][t3-drivers] registers eight dedicated
drivers plus `acpRegistry`. Copilot is a concrete integration through that ACP
driver, with additional Copilot-specific event handling; it is not absent merely
because it has no top-level driver enum case. The ACP Registry is a dynamic
catalog, not a ninth fixed vendor list. Its official CDN returned HTTP 403 during
this audit, so this document does not invent a current catalog count or claim to
have enumerated its live contents.

Evidence labels mean:

- **Installed:** a recorded test or native interaction used the actual installed
  provider. Its tested capabilities and version remain the limit of that claim.
- **Fixture:** deterministic local peers exercised the native implementation;
  this does not prove current vendor compatibility, authentication, or service
  availability.
- **Preset:** a saved invocation can select the generic ACP adapter. It is not
  independent runtime evidence for the named provider.
- **Missing:** no provider-specific native integration or verification is
  established by the inspected sources and evidence.

| Integration / pinned driver | Pinned T3 implementation | Coincide evidence and current boundary | Work required for parity |
| --- | --- | --- | --- |
| Codex / `codex` | App-server protocol, local and managed runtime paths, dynamic catalog and options, approvals/questions, native history, steering, skills/commands, account and usage controls. | **Installed existing CLI:** native turns, resume, images/files, exact reviewed fork/rewind, and acknowledged same-turn steering. **Native/source:** installed CLI remains default; explicit managed complete 0.156.1 package or custom executable, captured runtime/home, scoped catalogs, private bounded executable checks and leases protecting in-use packages. **Installed managed package:** the exact previously hash-verified macOS arm64 archive passes production extraction, activation, initialize-only execution and owned removal in private scratch. The native network download check remains unverified; no managed login or model turn is claimed. Read-only CLI account/allowance Settings keeps email private and bounds identity/stale handling. Bounded catalogs, advertised reasoning options, captured effort and cwd-aware CLI defaults retain their existing boundaries; history and steering remain limited to the reviewed 0.163.x profile. | Native downloader acceptance and authenticated managed conversations; actual ChatGPT OAuth/model acceptance and portable account profiles; turn/historical usage telemetry; broader protocol/tool/subagent coverage; skills, slash commands and MCP/configuration controls; session browsing/import; broader history compatibility and recovery. |
| Claude / `claudeAgent` | Claude Agent SDK and bidirectional query stream, native controls, approvals/questions, subagent ownership, steering, fork and rollback. | **Installed:** prior native conversation, resume and image/file turn evidence; current CLI version read as 2.1.304. **Fixture:** `priority: now` steering, interruption, root-task ownership, coalesced startup/root identity and owned drain. **Native/source:** prospective input/root UUIDs and captured runtime, reserved exact-file native fork, inclusive deferred rewind consumed by one explicit run, inherited/fresh reset, alias ownership, read-only recovery and native review/file-restore/prompt-recall integration. Underlying SDK 0.3.276 transform has seven independent synthetic oracle cases. **Installed 2.1.304:** four generated turns verify native fork and deferred-rewind context recall, exact unchanged-source/selected-chain proof, and SQLite restart. This does not verify installed steering or broader native histories. | Broader history/resume compatibility and hosted UI acceptance; session browsing/import; complete model/effort/control/configuration behavior; richer questions, hooks, skills, usage/auth/setup and subagent metadata. No managed installer/auth migration or `resumeDropsTurn` launch is included. |
| OpenCode / `opencode` | Dedicated, generation-selected OpenCode 1 and 2 HTTP adapters, provider/model configuration, permissions/questions, commands/skills, steering, fork/revert, sessions and usage. | **Native/fixture:** separate v1/v2 conversation actors over owned HTTP/SSE, captured model/variant/agent/rules, exact session/message ownership, text/tool/child projection, scoped permissions, v1 questions, v2 forms and Stop; v2 active steering with exact inbox ownership, original-turn receipts and held execution terminals. Real loopback HTTP/SSE-to-Engine FIFO checks are separate from hosted acceptance. **Native/offline checks pass:** v2 bounded message snapshots, steer-aware reviewed fork/history-only rewind, cloned-ID semantic proof and explicit staged-revert maintenance with exact idle receipts. **Native/source:** v1 clone-and-adopt history with durable candidate and read-only recovery; new offline checks are recorded separately. **Installed:** 2.1.2 read-only HTTP metadata is not a native chat or history verification; no installed 1.x test. Prior OpenCode ACP v1 discovery/marker turns remain separate evidence. | Provider authentication, v1 steering and ACP history, session browsing/import, installed command/skill acceptance, full child/autonomous recovery, reconnect reconciliation, usage, broader history compatibility and installed/hosted HTTP conversation/control/history verification. Preserve the working ACP path. See [HTTP implementation boundaries](OPENCODE_HTTP.md). |
| Cursor / `cursor` | `@cursor/sdk` 1.0.35, browser/API-key authentication, settings sources, models, tool/plan/subagent events and account usage. | **Native/fixture:** explicit ACP profile, independent initialization status, exact single/multiple question choices, explicit plan review, bounded todo merge/replace and task/image activity. V1 and experimental v2 retain flavor and local request identity across cancellation/wire-ID reuse. Installed CLI session/model discovery works, but the marker turn returned a plan-upgrade notice instead of the expected response. | Native authentication, complete settings/SDK tool/subagent equivalence, usage and applicable recovery; successful installed model/tool/approval/history verification. Official ACP is a starting transport, not automatic equivalence to the pinned SDK. |
| Grok / `grok` | ACP via `grok agent stdio`, xAI completion/background-task extensions, explicit runtime permission mode, authentication, skills and usage. | **Native/fixture:** explicit profile in both ACP adapters, captured launch modes from existing `PermissionMode`, prompt-correlated completion and background/task ownership, xAI cancellation metadata, typed plan/questions with selections and notes in the durable outbox. Focused checks pass; hosted acceptance is pending. Initialize-only status does not prove authentication, model access or a paid turn. **Installed:** none claimed. | Installed auth/model/tool/question/Stop and background verification; complete auth/setup, models/configuration, skills/usage and recovery. Exact-parent process cleanup does not prove descendant exit. |
| Antigravity / `antigravity` | Managed ACP server plus paired local harness, installation, Google/auth-method flows, model options and usage. The pinned macOS artifacts include `agy_acp_server.par` and `localharness_external`. | **Native/offline peers:** dedicated bounded ACP connection and paired process lifecycle; captured account generation/model/native mode; explicit Google/Enterprise/key/Agent Platform setup with transient browser URLs, staged profiles, Keychain credentials and Engine draining; exact permission/question options and security warnings; workspace-anchored delegated files; resume and prompt-terminal Stop. Explicit managed installation checks pinned archive identity and the pair, initializes before activation, retains running-session leases across updates and protects removal. Legacy captures remain external. Runtime checks are initialize-only and do not prove account access. **Installed:** the pinned 1.3.0 macOS arm64 archive passes download/hash/extract/native initialization/activation/removal in private scratch storage; no installed login or model is claimed. The IDE editor handoff remains separate. | Installed authentication/model/tool/Stop verification, usage, skills/MCP, portable handoff and broader recovery. |
| Pi / `pi` | Long-lived JSONL RPC subprocess, model/provider/thinking selection, extension UI, steering, persisted session-file history, fork/rollback and usage. | **Native/fixture:** separate JSONL actor, captured provider/model/thinking/policy, exact command correlation, structured text/thought/tools, four native extension dialogs, validated session-file resume, settled-plus-idle completion and run-fenced Stop. Existing stdio peers exercise the production factory, Engine FIFO, policy replacement and durable projection; native view/store checks pass. **Offline steering checks pass:** typed adapter-run steering through `prompt` with `streamingBehavior: "steer"`, correlated admission ACK, preserved captured settings/session file, stale-idle fencing and no replay of uncertain delivery. `/compact` maps to its native command. No native expected-turn or per-prompt turn ID is invented. **Native/source:** captured launcher/workspace/storage intent; observed 0.80.5+ profile; exact live entries/leaf preparation committed before prompt, and reserved steering input markers before write. Terminal proof retains native entry IDs and maps durably owned inputs only against an unchanged baseline and matching ancestry/order/digests. Unverifiable windows remain unavailable; process-loss recovery retains preparation without replay. Storage 40 additionally preserves authored-to-expanded skill ownership; scoped native inventories and command/skill pickers have offline coverage. Reviewed native head/historical fork and exclusive-user rewind now connect durable candidate publication, operation-owned lifecycle controls, ordered event barriers, read-only candidate/Keep Original recovery, immutable adoption lineage, reviewed file restoration and once-only prompt recall. Explicit empty-context intent binds one consumer and actual reopened identity; uncertain work stays held and is never replayed. Graph/fork source oracles and stdio/journal/Engine/Store/hosted evidence are recorded separately in VALIDATION.md. See [native history boundaries](PI_HISTORY.md). **Full pinned package:** actual 0.80.5 native RPC verifies historical fork, first-user metadata persistence behavior and CLI head fork with networking denied and no prompts. A separate production Engine/Session acceptance uses the intact package with a local synthetic stream to verify inline/native skills, templates, active steering, digest-only proof and SQLite restart. No authenticated model service is exercised. | Nonempty unpersisted cuts (including model/thinking-only first-user reset), session browsing/import; installed version/setup/auth/model and end-to-end verification; extension status/widgets/editor behavior, broader tools/MCP and usage. Parent drain does not prove descendant exit. |
| Muse Code / `muse` | Muse Session Protocol (MSP), through `@muse-code/sdk` 1.4.6 and `muse serve`; capabilities, revisioned items, approvals/questions, resume and steering. | **Native/fixture:** dedicated bounded MSP transport, captured models/efforts/policy, exact admission/terminal ownership, revisioned text/tools/background items, scoped staged approvals and selectable questions with notes. Session/profile proof, native Stop, production-factory Engine FIFO/policy replacement, durable restart and native view/store paths have offline peer coverage. **Offline steering checks pass:** native `turn/steer` with exact `expectedTurnId` and UUIDv7 command ownership; matching admission or native steered user-message evidence retains the original session/turn without changing settings or proving model consumption. **Installed:** no Muse call was sent. | installed version/login/model verification; active/pending-session adoption, full history/gap recovery, MCP/settings/skills/usage and portable handoff. Older hosts without permission-profile read-back are refused before prompts. Native fork/rewind is not a pinned Muse capability. Exact parent drain does not prove descendant exit. |
| GitHub Copilot / ACP `github-copilot-cli` | ACP Registry/local Copilot invocation plus `github.com/copilot/sessionEvent` and opt-in raw assistant/subagent attribution. | **Native/fixture:** explicit stdio profile, initialize-only status and raw assistant/reasoning/subagent bridge. Child messages/tools and background completion retain their original run after parent idle and another foreground turn. V1 and experimental v2 protocol fixtures exercise the actual adapters. **Installed:** CLI unavailable on this machine; no live claim. | Actual negotiated auth/model/mode/options and installed permission/session/restart/Stop verification; native setup/auth, supported launch controls and usage. |
| Other ACP Registry / `acpRegistry` | Official registry and local commands; binary/npx/uvx distributions, preparation, authentication, elicitation, provider configuration, session browsing/import/delete and provider-specific extensions. | **Fixture:** native ACP v1 and opt-in current v2 draft, same-connection v1 fallback, models/options, streaming, tools, permissions, resume and lifecycle. **Installed:** only the OpenCode path described above. No registry/install/auth UI is established. | Full catalog/installation/authentication lifecycle, richer client methods/media, session/provider management, capability-aware history/handoff and the named extensions below. Verify each offered integration; do not label every registry row tested. |

## ACP is a foundation, not an all-provider completion claim

Native [ACPSession](../Sources/CoincideCore/ACPSession.swift) deliberately
advertises no filesystem, terminal or authentication client capabilities. The
explicit Copilot profile adds only its raw-event metadata. It supports session creation and
capability-gated loading, drains replayed history without duplicating the native
journal, handles text/images, tool/plan updates and exact permission choices,
and applies select options or legacy model/mode controls. It rejects
unnegotiated filesystem, terminal, authentication and elicitation requests.

Native [ACP2Session](../Sources/CoincideCore/ACP2Session.swift) is opt-in. It can
adopt ACP v1 on the same transport, supports select/boolean options, native
entities and session-level permissions, and distinguishes prompt insertion from
foreground completion. Lost acknowledgments, agent-initiated work and background
permissions do not imply a new user turn or automatic retry. Neither ACP adapter
implements the native steering/history methods in
[ProviderSession](../Sources/CoincideCore/ProviderSession.swift); their defaults
are explicitly unsupported.

OpenCode, Cursor, Copilot and Grok have named shortcuts in
[SettingsView](../Sources/Coincide/Views/SettingsView.swift). The generic saved
[ACPAgentConfiguration](../Sources/CoincideCore/ACPAgentConfiguration.swift)
captures an invocation and optional explicit vendor flavor, not an installation/auth
receipt. A connection observation only proves initialization. Agent tool output in the transcript does not mean Coincide implements
delegated client filesystem or terminal operations.

Pinned T3 has explicit [ACP flavor extensions][t3-acp-flavors] that must remain
in scope:

| Agent | Pinned extension | Native gap |
| --- | --- | --- |
| GitHub Copilot (`github-copilot-cli`, or local Copilot executable) | Opt-in raw assistant/reasoning events and subagent lifecycle; map task tool IDs to child-session authors in wire order. Background tasks finish on the corresponding completion event, not merely the launching tool result. | Native bounded bridge and both adapter fixture paths exist; installed proof remains unavailable. |
| Claude ACP (`claude-acp`, or local `claude-agent-acp`) | Experimental v2 environment selection, agent work-state following, provisional/asynchronous tool ownership and subagent/session events. | Generic ACP capability only; the separate native Claude adapter does not prove Claude ACP behavior. |
| Devin (`devin`) | `cognition.ai/subagentSupport` and message-grouping metadata; normalize session/tool updates and child-agent attribution. | No named capability metadata or normalization. |
| Factory Droid (`factory-droid`) | Extract provider-specific elicitation forms. | Native ACP authentication/elicitation UI and Droid form handling absent. |
| Mistral Vibe (`mistral-vibe`) | Registered provider extensions and provider-specific rate-limit failure mapping. | No Vibe extension or failure mapping. |

Other registry agents use the negotiated generic contract unless source evidence
establishes another extension. A registry entry's own model providers are also
distinct from the agent integration; for example, an OpenCode model named after
another vendor does not implement that vendor's dedicated CLI/session behavior.

## Control and history fidelity

Pinned capability declarations and implementations differ materially:

| Transport | Active steering in pinned T3 | History behavior that must be preserved |
| --- | --- | --- |
| Codex | Native expected-turn steering; interrupt/restart is a distinct path. | Native exact-boundary fork/rewind where the reviewed protocol supports it. Coincide's existing version and ownership guards remain authoritative. |
| Claude | Native query input; root/background-task ownership matters. | Native reserved fork and T3's inclusive root-assistant deferred selection are implemented with prospective identity proof, one explicit consuming run and read-only recovery. Files and prompt recall remain separately reviewed stages. Legacy histories and installed compatibility remain gated; no transcript deletion or `resumeDropsTurn` launch. |
| OpenCode | Native steering and a separate interrupt/restart path. | V2 source now implements bounded ordered-message snapshots, exclusive whole-run cuts including steers, semantic cloned-ID proof, `files: false` staging/commit and explicit clear with an exact persisted maintenance-idle receipt, with passing local protocol/Engine/native view checks. V1 has a separate native clone-and-adopt implementation with durable candidate publication and read-only recovery. Installed and hosted history acceptance remain unverified for both generations; ACP defaults remain unsupported. See [native history boundaries](OPENCODE_HTTP.md#native-opencode-2-history). |
| Cursor SDK | No direct steering; interrupt/restart supported. | No native fork or rollback in the pinned adapter. Portable context handoff must not be described as native history mutation. |
| Pi | RPC steering and reviewed native history with durable candidates, lifecycle dialogs, explicit recovery and fresh-context consumption. | Durable nonempty/no-assistant cuts, session browsing/import and actual installed acceptance. |
| Muse | Native MSP expected-turn steering. | Pinned adapter rejects native fork/rollback and uses portable handoff. |
| Generic ACP / Grok | Generic ACP direct steering unavailable; interrupt/restart path. | T3's generic rollback can replace the runtime and clear its native projection. This is not proof of a provider-side exact-boundary rewind. Fork/portable handoff is capability-dependent. |

Sources include [Cursor capability/unsupported paths][t3-cursor],
[OpenCode adapter][t3-opencode], [Pi adapter][t3-pi],
[Muse adapter][t3-muse], [Grok ACP extensions][t3-grok] and
[generic ACP replacement/history handling][t3-acp-history]. Preserve these
distinctions rather than fabricating a uniform API capability. Where upstream
uses a portable handoff, that applicable behavior remains part of completion.

## Installation, authentication and usage

T3 supports multiple named instances of a driver, per-instance configuration and
environment, enablement, workspace-scoped discovery and stable continuation
identity. See [instance contracts][t3-instances] and
[registry hydration][t3-hydration]. Coincide's captured ACP invocations are useful
foundation, but the current provider/runtime captures are not a complete native counterpart
to this provider-instance inventory.

[T3 managed installation][t3-install] is explicitly available for managed Codex
and Antigravity. [ACP Registry preparation][t3-acp-install] additionally resolves
platform distributions and exact-version binary/npx/uvx packages with bounded
registry/download/process handling and installation evidence. Other drivers have
their own discovery and maintenance policies; do not claim T3 automatically
installs every CLI. Native integration must preserve existing user installations,
use explicit installation/update actions and verified destinations, and avoid
replacing or removing a binary still owned by another instance/session.

Coincide keeps installed Codex as the default. Its explicit managed mode selects
the pinned complete 0.156.1 package; it does not silently replace that choice with
another PATH installation. Custom executable and optional absolute home settings
are captured per conversation and queued input. Empty home preserves inherited
CLI behavior. Explicit executable inspection uses private temporary homes, and
reports the observed source/path/version without reading account access. Runtime
changes invalidate owned account/catalog/default reads; catalogs remain scoped to
the conversation binding. The reviewed 0.163.x history/steering gates are not
relaxed for the older managed package. Managed binary installation does not
implement T3's separate managed ChatGPT authentication/profile flow.

[ProviderAuthService][t3-auth-service] serializes credential changes and drains
sessions sharing the credential binding. It uses the actual runtime binding,
not the future model selected in a header. The [auth contracts][t3-auth-contract]
include owned flows, browser consent, device codes, terminal interactions,
credentials, completion, cancellation and logout. The
[ACP auth implementation][t3-acp-auth] selects negotiated agent/terminal methods
and handles URL elicitation; terminal methods must not be blindly replayed as
ordinary `authenticate` requests.

Native auth must use an explicit user action, scope cancellation to its own
flow/process, preserve captured queued settings and keep credentials,
authorization URLs/callbacks and one-time codes out of the workspace journal,
audit payloads and logs. Shared credential mutation needs a session-drain
boundary; a status refresh must not close an active conversation's transport.
T3-managed ChatGPT profiles are a separate credential/runtime mode from an
existing local Codex CLI login, not an implicit migration of that login.

Account status, subscription allowance windows, turn token telemetry and
historical cost/token activity are different features. T3 has dedicated usage
readers for Claude, Codex, Grok, Pi, OpenCode, Antigravity and Cursor in the
[driver registry][t3-drivers]. Muse reports its own protocol/usage information
but is not in that same historical usage-reader array. The
[usage-limit contract][t3-limits] distinguishes unsupported accounts from
transient probe failures: unsupported clears windows, while a failed refresh can
retain stale last-good windows. Sparse updates merge by stable identity. A reset
timer is not proof that provider work may resume. Credit redemption, logout,
credential replacement and sending account emails are mutations, not probes.

Coincide's native Codex account panel now reads the existing CLI identity and
subscription allowance on an owned metadata connection. It does not reuse or
close an active conversation transport. Identity is read before and after limits;
an account-change notice discards the observation, with one retry on the same
connection inside the original deadline for startup notices. Ordered sparse
updates preserve other buckets and missing window fields; a changed interval
does not retain another interval's reset timestamp. Account observations have no
persistence conformance and never enter the workspace journal. This read-only
panel does not complete native authentication, managed account switching,
turn-token telemetry or historical usage/cost reporting.

## Official current protocol checks

These pages were opened during this audit. They establish transport options, not
installed native verification, and do not override the pinned reference's
version-specific semantics.

- [OpenAI app-server documentation](https://learn.chatgpt.com/docs/app-server)
  describes Codex account/authentication, models, history, turn control and usage.
  Native compatibility remains capability/version-aware; credentials stay with
  the installed CLI unless a separately implemented explicit auth flow changes
  that ownership.
- [GitHub Copilot ACP](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server)
  documents `copilot --acp --stdio` and marks ACP public preview. Effort/tool
  filters can be server-launch settings rather than `session/new` values; capture
  those settings without pretending a per-session setter applied them.
- [Cursor ACP](https://cursor.com/docs/cli/acp) documents `agent acp`, existing
  CLI authentication, session loading, modes and permission requests. This route
  can support a native Swift integration, but its capability surface must be
  compared explicitly with T3's pinned SDK before claiming parity.
- [OpenCode v2 ACP](https://dev.opencode.ai/v2/docs/cli/acp/) documents a private
  server behind ACP v1 and use of existing provider sign-in. Its terminal-auth
  method is a separate login invocation followed by reconnect. The dedicated
  [OpenCode HTTP server API](https://docs.opencode.ai/docs/server/) is a wider
  integration surface than the preset.
- [Pi RPC](https://pi.dev/docs/latest/rpc) documents language-independent JSONL
  subprocess control. Prompt acknowledgment does not establish completion;
  `agent_settled` accounts for automatic follow-up, retry and compaction work.
- [Grok ACP](https://docs.x.ai/build/cli/headless-scripting) documents
  `grok agent stdio`; prompt metadata and streamed assistant output are distinct.
- [Google Antigravity integration documentation](https://antigravity.google/docs/ide/extensions)
  describes editor integration. The pinned installation/harness implementation
  must still be verified rather than inferred from the IDE brand or CLI name.
- [Meta Muse MSP documentation](https://meta-models.github.io/muse-code-sdk/next/guides/msp-concepts/)
  describes versioned wire/session/item state, command acknowledgments,
  approvals, resume and host-loss semantics.
- The [official ACP Registry](https://github.com/agentclientprotocol/registry)
  is the source for dynamic agents and distribution metadata. Registration and
  its auth-handshake checks do not establish Coincide compatibility.

## Implementation order and completion gate

The sequence below is an implementation order, not permission to omit later
providers or reduce the full native Swift goal:

1. Establish stable driver/instance identity, capability/status/setup inventory
   and native provider management while preserving legacy conversation, queue,
   model and credential ownership. Do not turn every future provider into an
   untyped Codex permission/configuration path.
2. Add named Copilot and Cursor onboarding and complete ACP authentication,
   lifecycle, session management and extension routing. Verify the actual named
   CLIs instead of equating presets with support.
3. Complete dedicated OpenCode generation-aware HTTP controls while retaining
   its working ACP integration and captured invocations.
4. Complete Pi and Muse controls/history/recovery and installed verification on
   their native Swift transports and actual lifecycle contracts.
5. Complete Grok's provider-specific ACP, background/auth/configuration and
   installed verification; finish Antigravity's installed account/model execution,
   recovery and usage behavior.
6. In parallel, finish Codex/Claude account, controls, skills, history and usage
   gaps; complete portable handoff and applicable generic registry behavior.

For each offered integration, completion requires a capability matrix and
evidence for the applicable end-to-end chain:

- Executable/distribution discovery, supported-version detection, explicit
  installation/update/removal and actual authentication/setup behavior.
- Dynamic models, defaults, provider/mode/reasoning/options, command/skill/MCP
  discovery, and exact per-input captured configuration.
- Native send/resume, attachments, streaming and structured tools/plans/questions,
  exact permissions, background/subagent attribution, Stop and process cleanup.
- Correct accepted/submitted/acknowledged/completed boundaries, explicit
  configuration-changing restart behavior, and no fabricated native turn IDs.
- Durable intent before external mutation, stale/incarnation/path fences,
  cancellation/removal/shutdown drains, honest unknown outcomes and no automatic
  duplicate delivery/replay after lost acknowledgments or process loss.
- Advertised session browsing/import and applicable exact native history or
  portable handoff, with source and target ownership and user data preserved.
- Account/usage display and recovery behavior where supported, with unsupported,
  stale and unavailable states distinguished and no hidden credential mutation.
- Meaningful offline protocol and engine/store tests, installed-provider marker
  smoke tests with bounded cost and exact task-owned cleanup, and native UI
  interaction/accessibility checks. Record the tested version, capabilities and
  exceptions; fixtures and successful builds do not replace installed evidence.

An upstream-unavailable capability should remain honestly unavailable; an
applicable but unimplemented capability remains a parity gap. Full provider
parity and default Liquid Glass adoption are **not complete** until these gates
and the broader [port requirements](PORTING.md) have been satisfied.

[t3-root]: https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08
[t3-drivers]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/provider/builtInDrivers.ts#L29-L63
[t3-instances]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/providerInstance.ts#L26-L94
[t3-hydration]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/provider/ProviderInstanceRegistryHydration.ts#L36-L70
[t3-install]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/provider/providerInstallation.ts#L53-L101
[t3-acp-install]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-acp-registry/src/server/AcpRegistrySupport.ts
[t3-acp-flavors]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-acp-registry/src/server/adapter.ts#L185-L246
[t3-cursor]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-cursor/src/server/adapter.ts
[t3-opencode]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-opencode/src/server/adapter.ts
[t3-pi]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-pi/src/server/adapter.ts
[t3-muse]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-muse/src/server/adapter.ts
[t3-grok]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-grok/src/server/acpSupport.ts
[t3-acp-history]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-acp/src/server/adapter.ts#L8332-L8423
[t3-auth-service]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/provider/ProviderAuthService.ts#L72-L198
[t3-auth-contract]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/providerSetup.ts#L45-L163
[t3-acp-auth]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-acp-registry/src/server/auth.ts#L230-L314
[t3-limits]: https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/providerUsageLimits.ts#L13-L67
