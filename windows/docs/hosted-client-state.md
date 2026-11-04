# Durable hosted-client generation and input metadata

`HostedClientState(scope)` stores routing IDs only under the app-private physical DataRoot. `open()` returns at most 128 generation records; each holds at most 64 pending delivery IDs. The file contains an epoch, original launch fingerprint, original profile/account scope, marker cursor, operation/disposition and optional observed delivery cursor. It contains no user/provider text, attachment paths, launch arguments, prompts or credentials. It never submits, replays, acknowledges, launches a provider or edits a workspace/transcript/index.

Root must first persist its workspace v2 marker and the new epoch's cursor zero in **both transcript and index**. Only then call `begin_generation(key, binding, HostedClientMarkerProof{receipt, true})`. Preparing metadata is separate from creating a host/provider. Existing active bindings cannot be silently overwritten, including by another begin call that tries to fill an empty account scope. Epochs are unique among retained generation records.

When an initial UI process crashed before recording the provider's verified identity, `bind_authenticated(key, SessionInfo)` may fill the empty scope. Root supplies an authenticated host list/status observation, never agent request JSON. Its key, exact original epoch, launch fingerprint and profile must all match, and the new account scope must be a valid nonsecret fingerprint. Known scopes cannot change. This records the original generation's account identity; existing native per-delivery account checks still verify the currently signed-in account before new work.

Before each actual proxy call, persist `prepare_intent(key, deliveryGUID, send|queue|steer)`. The user text already belongs in the transcript, and queued payloads in `queued_inputs`; this journal never duplicates them. Stable IDs cannot change operation, and preparing an existing ID never resets its disposition. `record_host_status` accepts affirmative authenticated `accepted`/`rejected` replies, or preserves uncertainty for `unknown`/`intent`/`uncertain`. Absence is never proof of non-delivery. A later missing status cannot erase an earlier affirmative acceptance.

`record_not_submitted` is only for an explicit proxy proof that the current instance never dispatched its freshly prepared input. Fresh preparation rights exist only in memory and are cleared by `open()`; a crash-restored `prepared` ID cannot regain that right merely by calling prepare again. Prepared, accepted and uncertain IDs remain available from `reconcile_ids` for read-only proxy status reconciliation. This helper never turns reconciliation into automatic retry.

After the reducer returns applied for an actual `input` or `started` event, call `observe_delivered(key, event)`. It requires that event's exact receipt and local delivery ID, plus the original verified account scope. Queue acceptance alone is not actual delivery. Queued/steered work requires its actual `input` receipt; `started` is a direct-send fallback. The first observed event cursor is retained. `retire_delivered(key, id, actual_saved_receipt)` requires both durable files and a prefix covering that cursor. Taking events or applying them only in memory cannot retire the ID.

Auth/setup can fail before either input or started, including before any verified account scope exists. `observe_settled(key, completed_event, authenticated_full_status)` records the exact correlated terminal processing cursor separately from delivery. It requires the original key/epoch/launch/profile and full authenticated status covering the event. It never claims that input reached a model or was unsubmitted. A legitimately empty account scope stays empty unless that same authenticated original host supplies a real verified scope. `retire_processed` requires both durable files and a prefix covering the terminal cursor; this permits final failed-attempt cleanup without inventing account adoption or replay. A settled ID remains pending until that durable cleanup but is excluded from status-reconciliation/resubmission candidates. The nullable settled field accepts the earlier exact schema-1 row shape as no settlement; unknown fields and future schemas still fail closed.

For definite non-delivery, `retire_not_delivered` requires a prior authenticated rejection or persisted local non-dispatch proof and Root's actual transcript/index durability receipt. Root first preserves the original input in its retained transcript, draft or paused queue. `record_queue_removal(key, id, host_accepted)` is a separate affirmative proof from **accepted `remove_queued(id)`**, never an inferred empty queue. It can resolve queue/steer intents to `cancelled` only before an actual delivery receipt; false/absent removal preserves acceptance or uncertainty. The original queue's accepted delivery status remains consistent with a later confirmed cancellation. A direct send cannot be cancelled through queue metadata. The older `retire_not_submitted` spelling forwards to `retire_not_delivered`.

Generation replacement is explicit. `retire_generation` requires an authenticated full status with the original binding, stopped/nonbusy/nonreview state, no prompts or queued work, no pending client intents, final `last == acknowledged`, and Root's **exact final durable cursor**. This is stricter than Core's replacement gate and does not interpret paused queues as deleted. Only that retired record may begin a different fresh epoch with its own proved cursor zero. Core's process-level `retire` command is not per-key generation retirement.

The user-only file has a strict versioned schema, decoded duplicate-key rejection, bounded UTF-8/structure, exclusive writer lease, revision and stale-snapshot comparison. Strong ancestor/metadata handles pin literal physical paths. Writes stage complete metadata, flush a new private file and atomically replace the original; failed/stale writes retain the prior disk and in-memory snapshots, including ephemeral preparation rights. Unknown/future schemas, unsafe permissions, links and size/count overflow require review and preserve originals. Caller-supplied durability/authentication proofs are internal app contracts; Root must not construct them from tool request JSON.

`Tests/HostedClientStateTests.h` exports `hosted_client_state_tests(report)`. It uses synthetic TEMP metadata only, including crash reopen, immutable bindings, account bootstrap, uncertain/rejected/cancelled cleanup, stale/locked writers, malformed/future/duplicate schemas, permission/hardlink checks and all 128×64 bounded IDs. It performs no real provider, account, model, owner-data, host, network, UI or ACK operation.

## Explicit stopped-input owner recovery

`observe_owner_resolution(key, event, authenticatedFullStatus)` records a separate
`owner_resolution` cursor. It accepts only the exact reserved administrative host
receipt for the original key, epoch, launch fingerprint and profile/account
binding. Full status must be stopped, nonbusy, queue-paused and cover the receipt;
the target must no longer be in the saved queue. Queue-cancellation receipts
cannot resolve direct-send intents. Unknown original identity remains empty
unless authenticated original status verifies it.

This proof preserves the earlier prepared/accepted/uncertain disposition. It
claims neither past non-delivery nor model execution. It is excluded from status
reconciliation and cannot be consumed by `retire_not_delivered`, live queue-removal
proof, or earlier delivery/terminal-prefix retirement. Root first preserves the
original input in its transcript/draft/paused queue, saves the exact receipt prefix
in transcript and index, and calls `retire_owner_resolution` with that actual
prefix. This retires metadata only. No input is migrated or sent automatically.

A same-instance `locally_prepared` query is memory-only; reopening loses that
freshness. The lazy facade uses it to expose `not_submitted` for a definite local
pre-enqueue refusal, without downgrading accepted/uncertain or previously enqueued
IDs. Root preserves the draft and calls `record_not_submitted` and
`retire_not_delivered` only for that affirmative current-instance proof.
