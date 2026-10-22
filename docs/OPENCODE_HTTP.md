# Native OpenCode HTTP integration

The dedicated native HTTP integration remains **in progress**. OpenCode 2 now
has a native `ProviderSession` for owned local HTTP conversations, captured model
and agent selection, streaming, tools, permissions, forms and explicit Stop.
This is an implementation and offline-fixture boundary; installed HTTP/provider
compatibility has not yet been established. Existing OpenCode ACP conversations
retain their original transport and captured configuration. Native OpenCode 1
chat, history, steering and complete T3 provider parity remain unfinished.

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

## Native OpenCode 2 conversations

The native provider choice is separate from ACP. Storage version 26 prevents an
older binary from reopening unfamiliar native configuration, run or effect
semantics. Legacy Codex, Claude and ACP payloads still decode without native
OpenCode settings. The durable value captures instance identity, generation,
one local executable, exact provider/model/variant IDs and agent ID. Runtime
credentials, ports, catalogs and inherited environment are not persisted.
Queued turns and runs retain their own configuration when a future header
selection changes. Models, variants and primary agents come from the exact
workspace inventory; menu choices revalidate the current catalog at command
execution. A model's local menu key is never parsed as a wire model ID.

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

Remaining work includes a shared instance lease registry, native v1 chat,
bounded reconnect/backfill reconciliation, complete autonomous/early-child
recovery, native steering and session import/history. V1 and v2 history have distinct
semantics; files remain under Coincide's reviewed checkpoint service. Native
setup/authentication, commands, skills, usage and installed-provider verification
also remain required by [the full parity inventory](PROVIDER_PARITY.md).

Sources: [pinned T3 OpenCode implementation](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-opencode),
[official v2 API](https://dev.opencode.ai/v2/docs/api),
[2.1.2 model routes](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/model.ts),
[2.1.2 event contract](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/event.ts).
