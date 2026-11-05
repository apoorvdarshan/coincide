# Nonblocking hosted AgentSession facade

`HostedAgentSession` implements `AgentSession` around the fixed native connector and authenticated background proxy. Construct it with `HostedAgentOptions{scope, key, client_state, restored_cursor, authorized_start, timeouts}` after Root has durably prepared its client-generation record and workspace v2/cursor marker. Construction starts shared MTA worker state and performs no synchronous file, account, pipe or process operation on XAML. Root should retain a `shared_ptr<HostedAgentSession>` across each asynchronous action; worker/action jobs independently retain the proxy and their plain state until bounded completion.

`snapshot()` exposes typed bootstrap/review/closed phase, error, connection disposition, cached proxy state/revision and read-only mode. `busy`, queue snapshots, `take_events`, `interrupt`, `close`, persistence hooks and snapshot getters access plain local state. Acceptance methods (`send_identified`, queue/steer/edit/remove/resume/pause/models/respond) refuse STA callers and marshal work to MTA action jobs. A waiting acceptance job does not block the event/control worker from dispatching Stop. Work count, payload bytes, action time and proxy requests are bounded. Anonymous `send` deliberately refuses: Root must first persist an exact stable delivery-ID intent.

Bootstrap reads the prepared client binding, connects the exact native host, then authenticates full status for an existing key. Epoch, original launch fingerprint, profile/account and saved cursor must match. A restored absent key never creates a provider. An initially empty original account scope may be filled only from that matching authenticated full status. No in-app runtime fallback exists when the host is held, unavailable, mismatched or uncertain.

Starting a new provider requires explicit `BackgroundAgentStart` authorization matching the original journal fingerprint/profile and cursor zero. Cursor zero alone is never authorization. Root supplies this permit only for a genuinely new explicit generation, never reconstructs it after a crash. Previously accepted/uncertain input intents prevent a fresh start. On restore the proxy receives pending IDs for read-only status reconciliation, not payload resubmission. Every new send/queue/steer also requires its matching still-prepared journal ID and operation; confirmed/uncertain old IDs cannot be sent as another input. Root continues to record actual acceptance/disposition, preserve input payloads and retire intents after durable saves.

Before forwarding account/input/started/completed receipts, the worker obtains actual authenticated full host status as needed. It binds a newly verified original scope in `HostedClientState` before delivery receipts reach Root. `authenticated_status()` returns only that actual cached response, never a status synthesized from event payloads. Root may use a covering exact response for `observe_settled` when auth/setup completed before any input/started or verified scope.

An exact restored generation with scope still empty enters read-only review. It does not construct an input-capable proxy or another provider. The MTA worker can poll its original error/terminal receipts, perform Root-confirmed durable ACKs and dispatch authenticated Stop. An authorized generation that fails auth/setup before scope verification also blocks new input while retaining catch-up and Stop. Root can settle the correlated terminal attempt, save transcript/index, ACK, stop/review and explicitly retire the failed generation without inventing an account or claiming model execution.

The facade has its own issued receipt prefix. Internal proxy draining cannot authorize an ACK for Root's unread events. `pending_persistence` reports only receipts returned by facade `take_events`; `confirm_persisted` accepts only that issued prefix with both real transcript/index durability flags, then queues worker confirmation. `acknowledged_persistence` changes only with actual authenticated server proof. Root still applies the reducer, saves both files and controls all external effects. `replay_unpersisted` is read-only receipt catch-up after Root rollback; no input or outbox is replayed.

Ordinary `close` detaches immediately and never stops the host/provider. `shutdown` queued before `close` remains dispatchable even while bootstrap is pending; close/destruction cannot cancel that explicit Stop. Dispatch is not proof that final receipts are durable: Root owns final catch-up, exact saved/ACKed prefix checks, generation changes and global Quit. Failed/lost Stop response remains review rather than an inferred success.

Only an explicit fixture connector may override the production connection, and it is gated to an exact synthetic TEMP scope marker. The owned `HostedAgentSessionFixture` returns deterministic fake sessions, including auth failure before scope verification; it never launches a real CLI/account/model. Tests cover UI-safe bootstrap/detach, stable intent IDs, worker acceptance, unread-prefix ACK rejection, replay, queue controls, restored binding, shutdown preservation and empty-scope read-only failure recovery. Production main, helper entrypoint, UI routing and persistence remain Root's integration responsibility.

Fresh prepared input IDs refused before enqueue (closed/read-only/unavailable or
bounded local capacity) expose an in-memory `not_submitted` disposition. This is
only current-instance non-dispatch evidence: existing accepted/uncertain and
previously enqueued IDs cannot be downgraded by a later refusal. Opening state
from disk does not restore local preparation freshness. Input methods remain
worker-only; no metadata file writes or pipe waits are added to the refusal path.
Root preserves the draft, records this affirmative proof in the journal and uses
actual transcript/index durability before retiring the ID.

Administrative stopped-input receipts trigger an authenticated full status refresh
before the facade forwards them, just as native account/input/terminal receipts
do. They pass through the normal ordered receipt prefix; returning an operation
reply or draining an event never implies persistence or ACK.
