# Hosted AgentSession proxy

`BackgroundAgentSession` implements `AgentSession` over the authenticated, user/session/image-bound private host pipe. It never launches a host, provider, account flow or model itself. Root owns the packaged helper entrypoint, verified native factory, profile/account/launch resolution, tool bridge and app activation policy.

Construct `BackgroundAgentOptions` with the fixed physical `Scope`, exact thread/provider `Key`, and either a restored cursor or explicit `authorized_start{epoch,Launch}`. Supply the expected nonsecret profile/account scope and optional original launch fingerprint. Adoption requires `allow_adoption`, a restored known epoch, and verified account scope; unknown/legacy bindings fail closed for owner review. An old cursor below the host's acknowledged prefix, a cursor beyond host history or a different epoch also requires review. For a new start, persist the selected epoch/cursor zero before constructing/submitting. A live start with an identical epoch is accepted only after the host checks the exact initial launch fingerprint.

`host_owns_current_tool_context` is a required factory contract: the verified native HOST factory must set `AgentLaunch.tool_context` to a fresh, non-UI supplier. The proxy transports original user text, attachments and settings. It never inserts UI curl instructions into queued payloads or a serialized launch snapshot. The provider worker fetches current references immediately before actual new/queued/steered delivery. A missing UI must yield an empty current reference snapshot, which the existing runtime wrapper explicitly invalidates in conversation context.

## Dispatch and lifetime

- `send_identified`, queue, steer and supported control methods wait on the dedicated worker for actual durable server acceptance. They refuse STA/XAML callers; Root dispatches these actions in the background and displays a pending state. Production uses `send_identified` with an already-persisted stable local delivery GUID.
- True means the host accepted the action at its native session boundary; provider startup/model failure can still arrive later as normal events. False may be definite rejection/not-submitted **or uncertain**. Root keeps uncertain intent and checks `delivery_disposition(id)`/the typed outbox; it must not infer that false means a turn never happened.
- A lost response is reconciled only through read-only durable delivery-status queries. Unknown/intent/uncertain results enter review and are never resubmitted automatically. Duplicate delivery IDs are refused locally. Outbox/command/event buffers are bounded.
- `interrupt` and `shutdown` enqueue authenticated control asynchronously. `close` detaches local UI ownership without stopping a host turn. Destruction never joins a blocked pipe; the shared worker owns its buffers/state until its bounded deadline settles. A failed explicit shutdown cannot leave that worker waiting forever.
- When the user retains background work, WindowClosing must use detach (`close`), not the former in-process close-plus-shutdown sequence. Explicit Stop/Quit remains a separate owner action. No image-name kills or in-app fallback is used when ownership is held or unavailable.

`snapshot()` is one plain-value atomic snapshot with a semantic revision. Full authoritative `Client::status` replaces queued/model/prompt caches only after ordered event catch-up. Lightweight list/poll metadata never clears heavy caches. `queue_known` is false while a changed queue count awaits its full snapshot; do not dereference a separately fetched queue based on a previous count. Prefer one `snapshot()`/`queued()` value for a UI update. Unchanged prompt/model snapshots are not emitted again on idle polls. Native IDs, stream item IDs and text/detail remain unchanged.

## Durable receipts and ACK

`SessionEvent.receipt` optionally carries `{epoch,sequence,delivery_id}`; `event.id` remains the provider's native identity. Direct, queued and steered local delivery IDs are a separate correlation channel.

1. Set `restored_cursor` before the worker starts polling.
2. Drain ordered events with `take_events()`. The call does not ACK. `pending_persistence()` returns the highest receipt actually returned to Root, never unread/fetched future events.
3. Apply the full prefix, save the cursor atomically with its transcript, then finish the index save. Only after both durable operations succeed call `confirm_persisted({cursor,true,true})`.
4. Confirmation validates the same epoch, a nonregressing issued prefix and both durability flags. It queues ACK and returns promptly; `acknowledged_persistence()` advances only after server proof/readback.

A crash before durable save replays identical event IDs from the old cursor. A crash after both files persist but before ACK restores the newer durable cursor and can safely ACK that already-applied prefix without replaying inputs. Merely displaying a reply, updating memory, or draining a prompt never acknowledges storage. Root must preserve a failed apply batch or restore its durable state before `replay_unpersisted()`; that method replays events only, never sends input.

## Synthetic validation

`background_agent_session_tests(report, exact_fixture_executable)` uses `BackgroundAgentSessionFixture.cpp`, a separate console helper gated to owned temporary directories with an explicit synthetic marker. It covers actual client-process crash/replay, durable-save-before-ACK restoration, failed receipts, account/epoch mismatch, authoritative queue controls, fresh host-side context on queued delivery, response loss with accepted/unknown outcomes, and bounded detach/shutdown under stalled/unavailable IPC. No provider, model, account sign-in, browser, desktop or user repository is involved. Root adds the test route/helper build when integrating.
