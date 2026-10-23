# Worktree inventory cleanup and retention

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/storage-cleanup-20261024`.

Implement native storage/worktree inventory and explicitly reviewed cleanup of owned clean linked worktrees with a reachable Settings surface. Own WorktreeCleanup*/StorageInventory* and related native store/view files. Default retention is OFF. Never delete base repositories, foreign/rebound roots, dirty/untracked user files, busy worktrees, unpushed commits or scratch conversation files. Validate actual Git/physical ownership immediately before mutation, use original durable operation IDs and truthful unknown-outcome recovery, and keep per-item outcomes. Retention must use the same gates and require explicit user setup; it cannot silently erase pre-existing data. Add private bare-Git fixture tests for clean vs dirty/untracked/unpushed/busy/base/foreign/replaced worktrees, cancellation and interrupted deletion inspection. Keep user-facing sizes/readiness accurate and bounded. No real worktree deletion outside test fixtures.

Deletion must also refuse unknown pushedness, missing upstream, and missing remote-tracking refs. An ahead count of zero without verified upstream/tracking evidence is not proof the commits are pushed. Do not turn uncertainty into permission to delete.
