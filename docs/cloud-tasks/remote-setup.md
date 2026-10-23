# Reviewed remote worktree setup

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/remote-setup-20261024`.

Complete remote worktree creation/reuse setup-script review and execution using the existing RemoteProjectScriptProtocol/Service and remote script store/views. Discovery never executes code. Show the complete captured command, shell, environment source and cwd; Approve/Stop/Skip/Retry and bounded owned output must be reachable. Queued first input remains held until the exact worktree and setup run are actually ready. Reuse existing remote Settle cleanup review without conflating setup/cleanup roles. Preserve original IDs, setup receipts, host physical checkout ownership, remote-only path resolution, drain and unknown outcome recovery. Add offline actual-helper fixtures for approved success, decline/skip, changed script/source, stop/drain, reconnect and no accidental queued-input start. Do not alter local setup trust policy or silently promote inherited scripts to trusted actions.

Preserve ThreadWorkspacePreparation.permitsProjectSetup: reuse of the main/base checkout must NEVER run setup. Only owned dedicated linked-worktree creation/reuse is eligible, subject to explicit review.
