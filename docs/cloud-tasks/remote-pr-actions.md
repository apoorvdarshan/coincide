# Reviewed remote pull request actions

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/remote-pr-actions-20261024`.

Expose existing native PR actions (merge/auto-merge, draft/ready, update, close/reopen, delete/revert/workflow approval where currently supported) through the remote environment transport and actual remote PR UI. Own RemotePullRequestAction* plus focused existing transport/view wiring. Reuse native durable reviews and original command receipts on the host; do not invent a second unreviewed command path. Capture exact repo/head/review generation, host-held capability and original command identity. Old helpers must disable unavailable actions, uncertain replies must remain recoverable without replay, and remote paths must never be resolved locally. Add actual offline helper/transport tests for capability mismatch, stale target, reconnection, denial, cancellation, and receipt idempotence. Do not expand GitHub write action semantics or touch PR links/review-comment features owned by other tasks.
