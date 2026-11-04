# Background host idle checkpoints

`Core::drain` continues to call every live runtime's `take_events`. With no pending
events, it compares cheap native busy, queue count and effective pause state with
primitive facts from the last successful durable checkpoint. Persisted unresolved
prompts keep effective busy true even if the runtime's raw busy flag clears.
Unchanged sources skip the full ledger clone, queue-vector snapshot and metadata
encoding. The listener and idle deadlines are unchanged.

An event, busy/count/pause transition or pending review change enters the existing
transactional path. Explicit controls still take their full queue snapshot before
their durable command commit, including edits whose count does not change and
providers that emit no control event. Async payload changes with unchanged facts
must emit the existing session events, as the native adapters do.

Facts are updated only after a successful `Ledger::commit`. Failed publication
retains pending events and the previous checkpoint; blocked/review recovery and
ACK retry keep their existing behavior. The post-commit cache refresh is noexcept:
if a narrow read fails, it invalidates that cache so a later pump fully validates
it, without turning already-durable events into another delivery attempt.

`Ledger::Facts` returns only primitive values. It exposes no mutable JSON alias.
`Core::busy` checks in-memory prompt presence rather than stringify/parsing the
whole history. Internal `Ledger::Activity` counters count clone attempts, commit
attempts, file reads and successful writes. They are not persisted, exposed by
IPC, logged by production, or used as product telemetry.

The native regression seeds over 2 MB of historical events/catalog plus 1024
command records, then starts three owned synthetic sessions. Across 500 idle
pump/busy rounds it asserts zero clones, reads, commit attempts, writes and full
queue snapshots, while every source is still checked for events. Further checks
cover asynchronous events/catalog order, eventless busy/count/pause transitions,
prompt-held busy, silent same-count edits and storage-failure recovery preserving
sibling events exactly once. The existing Core and IPC assertions remain.

## Read-only queries

Poll, status and list also avoid full-ledger copies. Status decodes only its
selected session's model/prompt/queue metadata. Poll and list read bounded scalar
summaries without decoding those payloads or visiting command/other-session event
history. Public readers return typed plain values or detached selected JSON;
they never expose a mutable original ledger object.

Poll uses the validated contiguous event sequence after ACK to jump past receipts
already fetched by the UI. It deep-copies only selected records, preserving their
safe unknown nested fields, with the existing 128-record and three-megabyte
limits. A poll at the last fetched cursor copies zero receipts even while older
receipts await ACK. Cursor/epoch/key checks and acknowledgement behavior are
unchanged. Explicit status still drains real pending runtime changes as before.

The read regression seeds over 5 MB of independent histories/catalogs plus 1024
command records. It exercises count/byte pagination, stale/future cursors, wrong
epoch/key rejection, legacy launch-hash/queue-count metadata, nested returned-data
tampering and 128 repeated poll/status/list rounds. Those rounds assert zero
whole-ledger clones, file reads, commit attempts/writes and source queue snapshots;
only the selected full status is decoded, and empty polls copy no old receipts.

This work does not change wakeups or polling intervals, and mutation checkpoints
continue to validate and atomically publish the whole ledger. Rare command and
delivery-status reconciliation queries remain separate from these three read
paths. Optimized native Windows validation passes Core 176 in STA and MTA, IPC 45,
proxy 82 and facade 48; the earlier Core 154 idle milestone remains separately
archived. All checks use synthetic fixtures, without real providers/accounts,
models, network or GUI. Integrated app acceptance remains Root's next checkpoint.
