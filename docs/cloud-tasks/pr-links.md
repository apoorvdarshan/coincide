# Pull request links and watching

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/pr-links-20261024`.

Implement arbitrary pull-request link/unlink/watch/unwatch as a real durable thread relationship feature, with reachable native linked-PR controls and matching app MCP routes. Own PullRequestLink*/PullRequestWatch* files. Preserve existing proven create/checkout lineage and automatic-settlement semantics; a user-added link is not proof of ownership or permission to settle. Inspect pinned T3 polling and terminal status behavior. Capture intended repo, PR and thread; poll using existing authenticated-source abstractions, deduplicate notifications, stop and join on owner removal/shutdown. No automatic merge or replay. Offline GitHub peer tests should cover stale owner, link identity, status transitions, duplicate notifications, cancellation and failure recovery. Leave PR review/comment editing to the separate review task.
