# Native app MCP

Coincide now implements an app-owned MCP server, session registry, tool router
and Engine admission path in Swift. Captured native **Pi** sessions can discover
and invoke those tools through their native extension API. Other providers'
app-MCP registration remains unfinished. Local protocol, Engine and intact Pi
package checks are recorded in [VALIDATION.md](VALIDATION.md). Hosted UI acceptance
and authenticated-provider verification remain open. This does not establish
full T3 parity.

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
Revocation stops new admission, cancels exact outstanding calls and joins their
callbacks, including callbacks already draining under another revocation.
This private app-tool connection starts no sign-in or browser authorization flow.

The header is runtime-only and redacted. Pi receives it through an app-owned
regular 0600 sidecar in a private directory. It never enters URL queries, process
arguments, environment variables, workspace configuration, journal, audit or
diagnostic text. Cleanup checks file ownership and identity and removes the
sidecar only after the owned process has drained; foreign replacements are
preserved.

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

- Other providers' native MCP registration, external-client authorization and
  remote access; MCP Apps/resources/HTML presentation.
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
[Engine facade](../Sources/CoincideCore/AppMCPEngine.swift), and
[Pi bridge](../Sources/CoincideCore/PiMCPBridge.swift).
The transport follows the official versioned
[2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
and [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
contracts.
