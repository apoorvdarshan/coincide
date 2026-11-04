# Explicit stopped saved-work recovery

`cancel_stopped_queue` removes only future saved queue work after a real explicit
owner confirmation. `resolve_stopped_input` administratively resolves an original
pending ID that has no remaining saved queue row, including a direct input with
an uncertain crash outcome. Neither action proves that an earlier attempt did
not run. Neither sends, resumes, recreates or migrates provider work.

Both commands require the original key and epoch, `owner_reviewed=true`, exact
`expected_launch_fingerprint`, `expected_profile_id`, `expected_account_scope`,
and `expected_delivery_digest`. Read the latter from authenticated
`delivery_status.command_digest` when known; an absent command remains unknown,
and requires an empty digest. A known command digest cannot be omitted or
substituted. Saved-queue cancellation additionally requires `queued_fingerprint`
from the exact reviewed `AgentQueuedTurn`; generic input resolution requires an
empty queue fingerprint and refuses any target still present in the saved queue.

The host requires stopped/nonbusy state, no owned runtime and a paused queue.
The saved row removal, correlated administrative receipt and dedupe proof share
one atomic metadata checkpoint. Separate `owner_resolutions` storage admits at
most 8192 records and does not consume or erase ordinary command history. A lost
response retry with a new transport command ID returns the same receipt; changed
review parameters refuse. A stopped generation replacement prunes its old
administrative dedupe only after the existing explicit fully ACKed/reviewed Core
replacement gate. Event/storage limits still apply, requiring durable catch-up
before another resolution when full. Native runtimes cannot emit reserved
administrative receipt details.

Accepted replies include `resolution`, `delivery_unknown=true`,
`resolution_receipt` (normal LoggedEvent) and authenticated full `session`.
Receipt kind is `queue_changed`; native `id` and separate `delivery_id` identify
the original input. Details are `stopped_queue_cancelled_reviewed` or
`stopped_input_resolved_reviewed`, with exact constant disclosure text.
Original delivery dispositions and review state remain intact. A saved queue
snapshot can be stale after a crash; cancelling it cancels only future saved
work, while past delivery remains unknown.

Root must retain the original payload, apply/persist this receipt with transcript
and index, then use `HostedClientState::observe_owner_resolution` and
`retire_owner_resolution`. It must never feed this result into live native queue
removal/non-delivery proof. Review and final ACK remain separate, explicit
lifecycle gates. Any later send uses a new explicitly authorized ID.

Validation uses synthetic TEMP-only Core, journal and authenticated owned-child
IPC fixtures, including dropped responses, crash-stale queue snapshots, full
ordinary history, failed atomic publication, exact binding and saved-prefix
rejection. No provider, account, model or owner data is used.
