# Native OpenCode HTTP integration

The dedicated native HTTP integration remains **in progress**. OpenCode 1 and 2
have separate native `ProviderSession` actors for owned local conversations,
captured model/variant/agent settings, streaming, tools, permissions and Stop.
V1 uses native questions; v2 uses typed forms. Focused offline checks, including
a real loopback HTTP/SSE-to-Engine FIFO test for v1, pass. Hosted acceptance
is pending. Installed 2.1.2 metadata observation is distinct from a native
conversation test; installed 1.x execution has not been verified. Existing ACP
conversations retain their original transport and captured configuration. Native
v1 history uses verified native clone/adoption with durable candidate recovery;
v2 history uses reviewed fork/rewind and explicit staged-revert recovery. Both
pass local protocol, Engine, reducer and native view checks. No installed-provider
or hosted history acceptance is claimed.

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

The native provider choice is separate from ACP. Storage version 36 prevents an
older binary from reopening unfamiliar native configuration, run, effect and
message-history recovery semantics. Legacy Codex, Claude and ACP payloads still
decode without native OpenCode settings. The durable value captures instance identity, generation,
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

Active v2 steering uses the captured run's native session and original input ID.
Its deterministic, bounded inbox identity binds the run, client message and exact
payload; repeated local requests cannot send the same input twice. The native
`delivery: "steer"` prompt never changes the captured model, agent or permissions.
The receipt retains the original turn even if its HTTP reply arrives after that
run finishes. Exact delivery can establish admission after a lost reply; an
unproven write remains uncertain and is not replayed or converted to a queue.

Successful execution terminals wait for outstanding steers and the next owned
execution when required. Native cancellation settles only its exact inbox entry.
Stop deletes outstanding known-admitted steer entries before interrupting the
original session; unknown admission closes the owned connection conservatively.
A late Stop cannot target a successor run. V1 does not inherit these v2 routes.
Offline protocol and production TCP/SSE-to-Engine checks are separate from
installed-provider acceptance.

## Native OpenCode 1 history

The v1 implementation reads chronological `{info, parts}` pages using only the
opaque `X-Next-Cursor` header. It prepends older pages and refuses repeated
cursors, duplicate identities, oversized pages or inventories. Reads are bounded
to 10,000 messages, 100 pages, 40,000 parts, 4 MiB per page, 16 MiB in total and
30 seconds. Two complete inventories, session metadata, descendant ownership,
statuses and pending permissions/questions must agree. A source with a native
revert marker is refused. These are quiet observations within one process;
OpenCode v1 provides no expected-head compare-and-swap or external-writer lease.

V1's native revert can restore files, so history-only Rewind Before Run instead
forks the exact retained prefix and adopts the verified new native session inside
the same local conversation. Fork After Run creates a separate local conversation.
Both use the native exclusive lexical message cut, verified against the observed
chronological prefix. No revert, unrevert, model turn or native deletion is sent.
An empty retained prefix is valid. Native compaction and its explicit continuation
remain inside their owning run; unrelated synthetic or replayed user input is
not silently claimed.

The canonical copy proof covers complete message information and parts. It
normalizes only native-regenerated message/part/session ownership IDs and the
assistant parent's earlier-user position. Native compaction `tail_start_id`,
tool data, attachments, settings and every other payload field remain literal.
Copied message and part IDs must be disjoint from the entire source inventory.
V1 exposes no fork ancestry field: title, time and subagent `parentID` are never
used to infer one.

After an acknowledged fork, the Engine durably records the exact candidate before
further native reads or clone-only permission configuration. Adoption requires the
full copy proof, exact captured agent/permission readback and an unchanged source.
Rewind preserves the latest local settings, draft and immutable original run IDs;
subsequent cuts resolve those IDs through prior verified positional copy maps.
Storage 36 retains the candidate and mapping evidence. Source and candidate native
sessions remain reserved while the action is pending, including aliases captured
by current headers, active runs or queued inputs.

A lost fork response can leave an unknown separate native conversation. The app
never guesses its ID or retries the fork. A known rewind candidate can be adopted after
restart only through read-only copy and permission verification. An unconfirmed
fork remains a recorded uncertainty; it is not retried or automatically adopted. Otherwise an
explicit **Keep Original Conversation** confirmation rechecks the complete
unchanged source and releases the local hold, warning that a separate native
conversation may remain. It does not delete native history, resend input or alter
files. Installed-provider and hosted history acceptance remain unverified.

The native semantics above follow the pinned [1.14.19 session implementation](https://github.com/anomalyco/opencode/blob/27db54c859be74aa4caed3e58ae14ecc8bc34b30/packages/opencode/src/session/index.ts)
and [session routes](https://github.com/anomalyco/opencode/blob/27db54c859be74aa4caed3e58ae14ecc8bc34b30/packages/opencode/src/server/routes/session.ts).

## Native OpenCode 2 history

Native v2 history now has a dedicated message-ordered read, reviewed Fork After
Run and history-only Rewind Before Run path. It does not invent native turn IDs
from app runs or observed input messages. The actor reads the exact native root,
captured instance/generation and physical workspace, while durable evidence keeps
the registered workspace spelling. Ordinary metadata and history inspection do
not create sessions, apply settings or clear a pending revert.

A read requires two matching ascending message inventories, matching session
metadata and quiet source/linked-descendant observations. Each inventory is
bounded to 10,000 records, 100 pages, 4 MiB per page and 16 MiB of payload; the
read operation has a 30-second deadline. Only the first request sends `order`;
subsequent requests use the native cursor. A final empty page is valid. Omitted
cursor fields are native optional fields; accepting null is explicit compatibility
with older recorded responses. Unknown message shapes fail decoding; unsettled
records cannot support a reviewed mutation.
See the official [message query handler](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/server/src/handlers/message.ts#L35).

A review binds terminal, attributed local runs to their observed native opening
inputs and steers. Fork After Run retains the whole selected run, including
verified steering inputs and intervening control, assistant and tool records:
its cut is exclusive of the next run's opening message, or the native head when
there is no later run. Rewind Before Run cuts exclusively at that run's opening
message. A retained input with uncertain delivery cannot become a verified
prefix merely because the last user-message ID matches.

Native fork creates a fresh session and regenerates every copied message ID.
Coincide compares the complete ordered semantic prefix, normalizing only the
top-level message ID and compaction `keepID` references to their prior inventory
positions. Native ancestry must also match the reviewed source and boundary.
Durable evidence stores bounded identities, message kinds and canonical hashes;
it does not store raw native message or tool bodies. The official
[fork projector](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/core/src/session/projector.ts#L192)
defines the copied-ID and compaction-reference changes.

Rewind requires an exact clean source, stages the exclusive boundary with literal
`files: false`, checks the unchanged original inventory and exact history-only
stage, then commits once and verifies the retained prefix with no remaining stage.
A preexisting stage is refused: native staging can restore a previous stage's
files even when the new request says `files: false`. File restoration remains a
separate reviewed Coincide checkpoint action. See the native
[stage/commit implementation](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/core/src/session/revert.ts#L22).

A possibly dispatched mutation whose result is unproven holds further provider
work. It is never replayed, and snapshot reads never hide a cleanup write.
Explicit Clear Pending Revert is a separate durable action, allowed only for the
exact observed history-only stage belonging to the reviewed operation. A native
clear wakes execution; Coincide accepts only a proven empty maintenance cycle,
and its HTTP acknowledgment is insufficient to settle maintenance. Coincide requires the observed start and terminal event IDs, a clean
stage, and exactly the prior inventory plus one settled idle record whose ID is
derived from that terminal event. The persisted receipt binds the prior inventory
hash and both event IDs to that idle record. A lost acknowledgment can be resolved
by this exact observed execution and read-back; missing, extra or unrelated work
stays uncertain. Fresh inspection cannot manufacture the receipt or globally
ignore idle records. These effects follow the official
[clear lifecycle](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/core/src/session/session.ts#L341)
and [terminal-to-idle projection](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/core/src/session/message-updater.ts#L63).

Storage 35 retains the review, dispatch/uncertainty state and maintenance receipt.
After restart, accepted work is not dispatched automatically and a possibly
sent mutation remains unconfirmed. Inspection compares the full original or
expected resulting prefix and clean stage; a persisted maintenance receipt is
required to account for its exact idle append. A confirmed clear supplies
maintenance evidence only: a separate read-only inspection still settles the
rewind outcome. Unknown maintenance remains held.

Source/descendant activity, inboxes, permissions and forms are checked before and
after reads, and the local actor rejects conflicting work. These are process-local
quiet observations, not a native compare-and-swap or exclusion of external writers
sharing OpenCode storage. The official routes have no expected-head CAS parameter.
The direct, reducer, native view and TCP/SSE-to-Engine history checks pass
locally, including the complete serial suite. These offline peers do not
establish installed or hosted history acceptance.

## Remaining integration

Remaining work includes a shared instance lease registry,
bounded reconnect/backfill reconciliation, complete autonomous/early-child
recovery, v1 steering, session browsing/import, broader native history
compatibility and installed/hosted history acceptance. V1 and v2 history have
distinct semantics; existing ACP history remains unsupported and does not inherit
the native v2 path. Native setup/authentication, commands, skills, usage and
installed-provider verification also remain required by
[the full parity inventory](PROVIDER_PARITY.md).

Sources: [pinned T3 OpenCode implementation](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08/packages/provider-opencode),
[official 1.14.19 SDK contract](https://github.com/anomalyco/opencode/tree/v1.14.19/packages/sdk/js/src/v2),
[official v2 API](https://dev.opencode.ai/v2/docs/api),
[2.1.2 model routes](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/model.ts),
[2.1.2 event contract](https://github.com/anomalyco/opencode/blob/a517687fde98a7329ada3ae644a01a9fc6c4e99e/packages/protocol/src/groups/event.ts).
