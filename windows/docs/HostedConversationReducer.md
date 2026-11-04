# Transactional hosted conversation events

`Runtime/HostedConversationReducer.h` applies plain `SessionEvent` values to a
loaded `Thread` and a plain `HostedConversationState`. It performs no UI, clock,
filesystem, network, provider calls, notification, schedule dispatch, or host ACK.
JSON parsing uses the existing model/usage contracts; state retains no COM object.

## Contract

Root initializes `HostedConversationState.thread_id`, `provider`, `epoch`,
`profile_id`, and verified `account_scope` from its authenticated runtime binding.
Root must load the complete transcript and explicitly arm its existing
`Thread.host_cursors` entry before consuming receipt-bearing events. The reducer
never invents a host generation or account adoption. Provider/thread identity,
profile/account invariants, cursor identity, and each new contiguous sequence are
validated before application.

`HostedConversationReducer::apply(Thread&, state, event)` returns
`HostedApplyResult` with `status` (`applied`, `duplicate`, or `review`), a bounded
`HostedReviewReason` enum, and plain effects. On `review`, no field or buffer in
Thread/state changes and no effect is returned. Matching already-applied receipt
sequences are `duplicate`; they never append text deltas or repeat completion,
notification, usage, or input effects. Future gaps and other epochs require review.

New events stage only their affected output string/new message, optional session
or queue rows, bounded runtime state, cursor and effects. The loaded transcript,
attachments, draft and unrelated settings remain borrowed; no receipt copies a
whole `Thread` or its historical message bodies. A delta targeting an existing
message prepares its bounded text separately and swaps only that string. Complete
thread identity/duplicate-ID validations still run; this optimization does not
cache trust across external edits.

Validation, parsing, and result allocations finish before commit. When adding a
new message, vector capacity reservation is the last fallible step; a statically
checked nonthrowing Message move then appends into the reserved slot. Existing
strings, small row collections, runtime state and cursor commit with nonthrowing
swaps/assignments. Return moves are statically checked nonthrowing. A failed staged
update, including one that already inserted a prompt into its staged map,
discards all staged data without touching original buffers.

Every applied receipt advances the Thread cursor and returns `durable_changed`,
`index_changed`, `cursor_advanced`, and `applied_cursor`. The equivalent epoch is
normalized to the exact incoming receipt spelling for proxy ACK compatibility.
These flags require saving **both transcript and index**, even for status-only
receipts. Root must not confirm persistence based on the proxy's highest issued
cursor or an event that returned review: use only this successfully applied prefix.

On a storage failure, preserve the applied in-memory model or roll back the whole
batch before `replay_unpersisted()`. Replayed already-applied events are harmless;
the caller still must save both files before ACK. An ACK remains Root's separate
operation after both durable saves succeed. The reducer cannot claim persistence.

## Effects and original data

`HostedConversationEffects` provides rendering flags, activity/wake intentions,
response/completion notifications, completion outcome/success/uncertainty, model
and prompt refresh flags, optional decoded usage, native session/turn IDs, and the
applied cursor. Root owns localized presentation, timestamps, usage accounting,
schedule completion, and notification dispatch. Dispatch external effects only
after the corresponding model commit and required durable saves; no callback runs
inside the reducer.

Input correlation prefers `receipt.delivery_id`. Only when that field is absent
may an event ID match an already-known local queue/user message. An unknown receipt
ID never falls back to a coincidentally matching provider-generated GUID. The
reducer never copies provider `event.text` into a user input: queued text and
attachments come from the saved `QueuedInput`, and existing direct user messages
remain unchanged. `delivered_input` returns original queued model/effort/tier/
plan/access/attachment metadata to Root for actual-delivery usage accounting.
Attachment/text conflicts preserve both originals and require review. Drafts,
selected models, metadata, and other providers' histories stay intact.

Native session IDs remain provider-owned. A repeated session ID preserves its
acknowledged message count; a newly bound session resets that count. Only a
successful nonfailed `completed` event acknowledges the actual committed message
count. Interrupted/failed turns do not acknowledge incomplete history. Duplicate
completion callbacks cannot issue repeated completion effects. Verified account
updates use existing `valid_session_binding` rules; a saved scoped conversation
requires the matching current account before input/output can resume. Setup/status
errors remain applicable so the owner can review failures without losing receipts.

## Read-only snapshots

Provider prompts retain the real adapter shape: `event.text` is normalized question/approval JSON and `event.detail` is its bounded method name. The reducer validates that JSON without changing either field.

Nonreceipt events are limited to status, local proxy error/catalog notices,
models, prompts, and resolved prompts. They can update only runtime view state;
Thread buffers and cursors are untouched. Local transport errors do not mark a
real turn failed or completed. Cached prompts/models have no durable, usage,
activity, wake, or notification effect. Duplicate cached prompts/catalogs do not
reissue corresponding change flags. Other nonreceipt event kinds require review.

Receipt usage events advance normally. Invalid optional metrics produce
`usage_malformed` with no decoded usage value; they do not block a conversation.
Root still verifies usage turn/session ownership before recording observations.

Bounds preserve existing data rather than truncating it: output messages are
limited to 8 MiB, event text/details to 1 MiB, catalogs to 512 KiB/4096 entries,
prompts to 64 entries/512 KiB, and loaded transcript count to 100000 messages.
Invalid/oversized new data returns review with the original model preserved.

## Isolated native validation

`Tests/HostedConversationReducerTests.h` exports
`hosted_conversation_reducer_tests(report)` for an initialized native MTA console.
It uses synthetic values only: a 4096-row/16-MiB history with 64 Unicode deltas
and deterministic untouched-buffer identity checks, long-history status/replay/
malformed/8-MiB target-limit rollback, delta replay, contiguous prefixes, epoch/provider/
account rejection, direct/queued ID correlation, original text/attachments,
malformed-event rollback, post-insertion prompt cap rollback, cached snapshots,
optional usage, completion outcomes, and exact native-session acknowledgment.
It opens no UI, provider, workspace store, credential, network, or host endpoint.
The test harness writes only its isolated result report.
