# Native app MCP

Coincide now implements an app-owned MCP server, session registry, tool router
and Engine admission path in Swift. Native **Pi**, **Codex**, and captured normal
**Claude** sessions now register those tools through their own protocols. Other
providers' app-MCP registration remains unfinished. Prior local protocol, Engine
and intact Pi package checks are recorded in [VALIDATION.md](VALIDATION.md);
that record separately tracks the new Codex/Claude test results. Hosted UI
acceptance and authenticated-provider verification remain open. This does not
establish full T3 parity.

The product enables app MCP by default. `WorkspaceEngine` library callers opt in
with `appMCPEnabled: true`; its default is false. The separate synthetic GUI app
keeps MCP off unless `COINCIDE_UI_TEST_MCP=1`, because ordinary transport fixtures
do not load real vendor extensions.

## Transport and credentials

`MCPHTTPServer` owns an ephemeral IPv4 loopback listener at
`http://127.0.0.1:<port>/mcp`. It implements the compatibility profiles
**2025-06-18** and **2025-11-25**, including `initialize`,
`notifications/initialized`, `ping`, `tools/list`, `tools/call` and explicit
`notifications/cancelled`. These profiles use the pinned T3 client's handshake;
this is not a claim to implement the newer stateless MCP protocol.

Each POST carries one JSON-RPC message. Requests receive JSON responses;
accepted notifications receive empty HTTP 202 responses. GET returns 405 because
the server offers no SSE feed. There is no replay/resumption stream, public OAuth
discovery route or server-initiated RPC. The optional `MCP-Session-Id` header is
not issued: initialization belongs to the private credential's provider session.
Subsequent requests must use its negotiated `MCP-Protocol-Version`.

The listener checks the exact loopback Host and rejects a supplied foreign Origin.
Headers are bounded to 16 KiB and bodies/responses to 1 MiB, with bounded JSON
depth, connections and concurrent invocations. Tool listing returns the complete
capability-filtered catalogue in one page. The Engine and Pi bridge both allow
660 seconds for tool calls, making the tool's maximum ten-minute wait reachable;
Pi discovery has a separate ten-second deadline.

`MCPSessionRegistry` issues 32 random bytes as an opaque Bearer header and retains
only its SHA-256 hash. A credential binds the provider session, thread/project,
runtime/incarnation, provider instance, workspace, captured permission and
capabilities. It survives ordinary runs on that same runtime. Its 24-hour
liveness is renewed only by trusted owner activity; MCP traffic cannot revive it.
An explicit successor with different captured permissions drains the old runtime,
revokes its lease and receives a new provider session and credential. Changing a
future permission selection cannot expand a still-running lease's authority.
Revocation stops new admission, cancels exact outstanding calls and joins their
callbacks, including callbacks already draining under another revocation.
This private app-tool connection starts no sign-in or browser authorization flow.

The header is runtime-only and redacted. Pi receives it through an app-owned
regular 0600 sidecar in a private directory. Codex and Claude receive it only in
native stdin control/configuration frames. Coincide does not put it in URL
queries, process arguments, environment variables, saved provider settings,
workspace configuration, journal or audit. The stdio transport redacts both the
exact header and bare token from inbound JSON and disconnect diagnostics before
provider errors or notifications can reach projection; provider stderr is not
persisted. Pi cleanup checks file ownership and identity and removes the sidecar
only after the owned process has drained; foreign replacements are preserved.

## Native Pi composition

`PiProtocol.permissionExtension` composes permission handling, `PiInputBridge`
authored-input proof and `PiMCPBridge` into **one awaited async extension factory**.
The bridge initializes over HTTP, lists tools, and registers native Pi tools as
`mcp__coincide__<tool-name>` before declaring readiness. Missing or invalid
readiness refuses prompt admission. App-owned read-only tool annotations are
trusted only for tools registered from that exact owned extension; other tools
retain the captured Pi approval policy.

Skill/template expansion and steering continue through their existing native
input path. The nonce-bound bridge still independently checks actual native user
entries; adding MCP does not replace input digests, invent native turn IDs or
upgrade unavailable history evidence. Pi itself remains the vendor CLI, which
may use Node/TypeScript. Coincide does not run a T3 Code Node server or Electron
frontend to provide these app services.

## Native Codex and Claude registration

Codex first reads native `mcpServerStatus/list` without a thread to refuse a
collision with the owned `coincide` server name. `thread/start` or `thread/resume`
then receives only the dotted `mcp_servers.coincide` override, leaving foreign
servers, including `t3-code`, intact. The override carries the loopback URL,
Authorization header and native timeout. A successful thread response and a
scoped native tool catalogue containing the app read tool are required before
each prompt. Present native runtime/origin/server identity fields must agree;
older status responses may omit newer optional fields. Unsupported, partial or
contradictory registration closes the attempt with a fixed error and no prompt
fallback.

Owned ChatGPT mode forwards the runtime-only connection through
`CodexOwnedSession`. Its lazy child receives registration before connecting;
credential-epoch replacement closes and joins the old child, configures the new
one, and fences obsolete events. The MCP credential is separate from the Codex
account credential and is never added to its saved account configuration.
Native Codex `mcpToolCall` items project bounded arguments, status and result onto
the observed active run. A late update after that run terminates is dropped;
this does not establish broader background-tool ownership.

Native MCP write approvals use Codex's `mcpServer/elicitation/request` empty
form with `codex_approval_kind: mcp_tool_call`. Coincide presents the native
message and exact tool arguments in its existing Approve Once / Decline panel.
Requests must belong to the current native thread and turn; changed, answered,
unsupported or unowned requests cannot authorize a tool. Responses never persist
session-wide or permanent permission. Nonempty forms, URL consent and user
verification remain unsupported.

Claude registration is available only for the captured normal stream-json
launch, not arbitrary legacy argument invocations. Before prompting, native
`mcp_status` must show no owned-name collision or other dynamic/SDK servers that
`mcp_set_servers` could replace. The native control acknowledgement must add
exactly `coincide`, remove nothing and report no errors. Settings/plugin servers
remain native; Coincide does not read or copy their credential-bearing settings.
Concurrent startup shares that registration barrier. Failure refuses input with
a fixed error; metadata/history workers receive no app-tool connection.

Separate no-model native probes confirm registration/catalog compatibility for
installed Codex **0.163.0**, the pinned managed Codex **0.156.1** package and
installed Claude **2.1.308**. They use private homes/configuration, an isolated
synthetic loopback MCP catalogue, external-network denial and joined process
cleanup. Native scratch scans found no header/token persistence. No prompt,
tool invocation, login, saved account or authenticated model service was used.
These observations leave Codex's existing 0.163.x history/steering gates intact;
they do not grant those capabilities to the managed 0.156.1 runtime.

A separate opt-in model-driven acceptance check passes with installed Codex
**0.163.0** and Claude **2.1.308**, using their existing CLI logins. Each provider
reads and renames a generated thread through the real app server, then reads its
new title in a second turn on the same runtime. The check requires native tool
events, exact answers, a preserved unsent draft, unchanged workspace bytes and
successful journal rebuild/SQLite restart. It authorizes only the generated
read/rename requests. This proves those installed app-tool flows, not managed
authentication, all thirty tools, or rendered approval interaction. Run explicitly
with `COINCIDE_LIVE_APP_MCP=1 swift test --no-parallel --filter installedProvidersUseAppMCPThroughNativeEngineAndRetainChangesAcrossRestart`.
Successful checks delete their generated app database; provider-native test
conversations remain in the CLI's history.

## Tools and durable authority

The catalogue contains 30 tools, with supported variants routed to existing
Engine services:

| Surface | Implemented boundary |
| --- | --- |
| Capabilities and reads | Provider/model capability observations; environment, registered projects, bounded thread/history search and reads, configuration, queues, pending questions and current worktree status. Listing tools does not launch providers; an explicit capability query can request metadata. |
| Threads | Batches of up to 20 new conversations inheriting captured settings, independent launch, rename, pin/archive, supported idle settle/resume, and same-provider-instance model/options changes. New worktree launch uses native preparation gates. |
| Delivery | Literal input, explicit queueing, compatible active steering, bounded wait and exact observed run/runtime interruption. Current drafts and captured active/queued settings are preserved. |
| Queue and questions | Edit ordinary queued text, cancel/reorder, compatible promotion to steering, and exact pending question answers. A tool cannot approve its own permission grant as a question. |
| History and projects | Fork through an available reviewed native history contract. Project creation registers an explicit existing local directory; project registration/rename/removal requires full access. |

The Engine resolves a fresh invocation context and checks it again at command
commit, including after asynchronous preparation. **Writes require the exact
current active run.** An idle session can perform available reads; retained
background output does not grant write authority. Targets must fit both the
credential's captured permission ceiling and the caller's current permission.
Automatic review and automatic edit approval are distinct, incomparable policies;
provider model/agent options are not treated as permission ranks.

Only nonsecret owner identifiers enter command authority. The durable receipt
fingerprint binds that scoped command; the complete command payload is not
retained. Created threads separately retain their parent/session/run origin.
Batches validate before reduction and publish together; later refusal publishes
none of the earlier mutations. Supported client request IDs use durable command
deduplication, and transport request IDs cannot be reused within the lease.
There is no automatic resend after HTTP or native delivery uncertainty.

Pi sends explicit cancellation for an aborted owned tool request. TCP disconnect
alone does not cancel an admitted action. Cancellation is not rollback: a command
already durably admitted may finish, and loss of its response is not permission
to repeat it. Shutdown/revocation joins accepted callbacks and owned networking.

## Remaining parity work

The catalogue is not a promise that every upstream argument variant works.
Unsupported cases return fixed errors and remain visible through
`AppMCPTools.unsupportedCapabilities`:

- OpenCode, Muse, Antigravity and ACP providers' app-MCP registration,
  external-client authorization and remote access; shared native MCP
  configuration editing and MCP Apps/resources/HTML presentation.
- Background-run write ownership, delegated/app-owned subagents and wakeups,
  scheduling, secret requests, preview/browser/device services and review guides.
- Cross-provider or foreign-instance model changes, restart delivery, deferred
  own-run settlement and client-keyed steering without reserved native input IDs.
- Editing steering-reserved queued text, managed project allocation, creating
  missing workspace directories and remote worktree fetch.
- Attachment uploads, PR links/watch services, merge-back, active worktree
  handoff and environment preferences.

Existing provider-native MCP configuration may still work through that CLI's
own settings. That is separate from Coincide's app-tool registration and does not
establish a shared MCP configuration editor or full provider parity.

Implementation: [transport](../Sources/CoincideCore/MCPHTTPServer.swift),
[registry](../Sources/CoincideCore/MCPSessionRegistry.swift),
[protocol](../Sources/CoincideCore/MCPProtocol.swift),
[authority](../Sources/CoincideCore/AppMCPAuthority.swift),
[tool catalogue](../Sources/CoincideCore/AppMCPTools.swift),
[Engine facade](../Sources/CoincideCore/AppMCPEngine.swift),
[Pi bridge](../Sources/CoincideCore/PiMCPBridge.swift),
[Codex session](../Sources/CoincideCore/CodexSession.swift),
[owned Codex forwarding](../Sources/CoincideCore/CodexOwnedSession.swift), and
[Claude session](../Sources/CoincideCore/ClaudeSession.swift).
The transport follows the official versioned
[2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
and [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
contracts.
