# Native OpenCode HTTP integration

The dedicated native HTTP integration remains **in progress**. OpenCode 1 and 2
have separate native `ProviderSession` actors for owned local conversations,
captured model/variant/agent settings, streaming, tools, permissions and Stop.
V1 uses native questions; v2 uses typed forms. Focused offline checks, including
a real loopback HTTP/SSE-to-Engine FIFO test for v1, pass. Hosted acceptance
is pending. Installed 2.1.2 metadata observation is distinct from a native
conversation test; installed 1.x execution has not been verified. Existing ACP
conversations retain their original transport and captured configuration.

## Generation and connection boundaries

`OpenCodeMetadataConnection` distinguishes generation 1 JSON `/global/health`
from generation 2 JSON `/api/info`. An HTML 200 is not identity, and an
authentication rejection never falls through to another generation. Supported
metadata floors follow the pinned T3 reference: 1.14.19 and 2.0.18. Unknown
majors are rejected; decoding metadata is not a promise of all controls on an
unreviewed version. A local v2 connection must match the owned process ID. The
v1 health protocol cannot establish that PID.

`OpenCodeOwnedServer` starts only an explicitly supplied executable. It captures
an ephemeral loopback port and a fresh, runtime-only Basic credential. V2 uses
`serve --stdio --hostname 127.0.0.1 --port 0` and an stdin lease; v1 uses its
legacy serve/listening-text contract. Close awaits the exact owned parent and
joins app-owned pipe readers. It does not signal arbitrary descendants, stop an
existing service, or claim a v1 process-death lease. Default runtime environments
still use normal CLI configuration; a GET-only check does not make plugin
startup or database migration inert. Installed HTTP execution has not been
verified against entirely isolated configuration.

`OpenCodeHTTPClient` accepts an explicit HTTPS origin or loopback HTTP origin.
It rejects redirects, URL credentials and credential-bearing query parameters.
Credentials remain in headers and memory. Ephemeral URLSession state uses no
cookie, cache or shared credential store. Request bodies, incremental response
bodies and headers have explicit bounds. Cancellation closes only owned I/O;
it does not retry a mutation or imply that a server-side action was cancelled.

## Metadata and events

V1 catalogs use connected provider/model records and name-based agents. V2 uses
location-wrapped model, agent and default-model responses. The requested
absolute local directory must match the returned directory exactly. Advertised
provider ID, model ID and variant IDs stay separate; upstream `modelID` and
display names never replace wire selections. Empty initial catalogs remain
valid snapshots. Raw provider request headers, bodies, system prompts and
unknown configuration are discarded. A second identity read fences catalog
observation against server replacement. Closing metadata cancels and joins only
its own reads, preserving a shared event subscription and HTTP client.

`OpenCodeSSEConnection` waits for accepted event-stream headers before returning.
V1 is directory-scoped; v2 is a global feed whose adapter routes exact
native session identities. Framing handles split UTF-8, BOM, CR/LF, comments,
multiline data and committed event IDs. Each line/event is bounded, as are raw
bytes and queued events. Heartbeat bytes refresh a 45-second silence watchdog.
EOF, invalid framing, overflow and silence fail explicitly and require session
reconciliation. They never complete a provider turn or replay a prompt. An
unfinished event does not advance the committed cursor. A cursor alone does not
make OpenCode's global stream durable.

## Captured native conversation configuration

The native provider choice is separate from ACP. Storage version 27 prevents an
older binary from reopening unfamiliar native configuration, run or effect
semantics. Legacy Codex, Claude and ACP payloads still decode without native
OpenCode settings. The durable value captures instance identity, generation,
one local executable, exact provider/model/variant IDs and agent ID. Runtime
credentials, ports, catalogs and inherited environment are not persisted.
Queued turns and runs retain their own configuration when a future header
selection changes. Models, variants and primary agents come from the exact
workspace inventory; menu choices revalidate the current catalog at command
execution. A model's local menu key is never parsed as a wire model ID.

## Native OpenCode 1 conversations

V1 uses directory-scoped `/session`, `/event`, `/session/status` and
`/session/{id}/prompt_async` routes with unwrapped responses and `properties`
event envelopes. Its SDK's `/v2` export still describes the 1.x server; it must
not be confused with OpenCode 2's `/api` protocol. Session creation returns a
server-generated ID. A lost create reply is uncertain and never triggers guessed
adoption, a second create or a replayed prompt. Resume verifies the exact native
ID, directory and root ownership; missing or reverted history is not silently
replaced or moved.

Explicit captured model provider/id, variant and agent travel with each prompt; session
permission rules are applied and reread first. Native agent restrictions and
narrow plan-file allowances survive without overriding supervised command
approval. Future header changes do not alter an accepted run. Images use bounded
native file parts; the actor does not load arbitrary paths.
An explicit Default Model selection omits model and variant so the native server
resolves its agent/history/config defaults; per-provider catalog defaults are
not treated as a proven global choice.

HTTP 204 acknowledges admission, not completion. The native authored message ID
and an assistant's exact `parentID` prove run ownership. Early idle waits for
admission and a fenced status read; assistant completion alone does not drain
the FIFO. Snapshots replace text and deltas append in order. Child `task` links
retain their original run after parent completion; a launcher completing is not
child success. Unknown child or assistant frames are never assigned to a later
run merely because it is active.

Permission replies distinguish once, conversation-rule grants and native
workspace-wide grants. Questions preserve ordered exact labels, multiple
selections and custom answers; native reply/rejection events settle local
requests. Stop before any native input evidence remains uncertain even after a
204 response, because v1 has no exact inbox cancellation. An observed Stop sends
native root abort and attempts verified descendants. Close drains the owned
parent and app-owned I/O; neither operation proves all OS descendants exited.

## Native OpenCode 2 conversations

Each conversation actor owns its loopback process, HTTP client and global event
subscription. Metadata uses an independent actor/runtime and never creates a
native session. Session creation uses an exact intended ID and explicit title;
adoption verifies ID, directory and root ownership. Missing native history is
not replaced by another conversation. Captured agent, permissions and model are
applied and reread before input. Existing active/inbox work blocks a new send.
Preparation rechecks cancellation before every subsequent mutation.

HTTP prompt success acknowledges durable inbox admission. A run completes only
after its owned delivered input, actual execution start and matching terminal
evidence; step completion and old terminals do not settle the next run. Deltas
append exactly, while ended snapshots replace. Projection keys preserve native
instance, session, assistant and item identity, with separate bounded projection
state for each retained original run. Proven child calls retain that original
run after foreground completion, and a background launch is not child success.

Permissions offer explicit once, conversation and workspace scopes. Cancel and
Decline have different native operations. Forms preserve exact option values,
multiple selections, optional fields and native UTF-16/count constraints.
Unsupported hidden, conditional or other field types remain visible and can be
cancelled. A pending local request maps to one exact native session/request on
that runtime. No rendering or default selection submits a response.

Unresolved create/prompt acceptance and event disconnection fail conservatively
and pause the queue. Conclusive delivered-input events can establish admission
when the HTTP reply is lost; a late reply still belongs to its original run.
Stop before either HTTP or native admission evidence closes and drains that
owned runtime and preserves uncertain delivery: an early inbox deletion cannot
prove that a still-pending POST was cancelled. Native history and unresolved work
are not automatically replayed, and cancelling local HTTP I/O is not represented
as native Stop.

## Remaining integration

Remaining work includes a shared instance lease registry,
bounded reconnect/backfill reconciliation, complete autonomous/early-child
recovery, native steering and session import/history. V1 and v2 history have distinct
semantics; files remain under Coincide's reviewed checkpoint service. Native
setup/authentication, commands, skills, usage and installed-provider verification
also remain required by [the full parity inventory](PROVIDER_PARITY.md).

Sources: [pinned T3 OpenCode implementation](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-opencode),
[official 1.14.19 SDK contract](https://github.com/anomalyco/opencode/tree/v1.14.19/packages/sdk/js/src/v2),
[official v2 API](https://dev.opencode.ai/v2/docs/api),
[2.1.2 model routes](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/model.ts),
[2.1.2 event contract](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/event.ts).
