# Parallel work for Coincide

Use a normal ChatGPT Work cloud chat, or Batsy coordinating Work tasks. No dedicated Codex Cloud environment is required by this workflow. The worker needs a writable checkout, shell/Git tools, network access to the public repository, and whatever GitHub write access is available. State any unavailable capability instead of pretending work started.

This is the first group of eight independently assigned implementation tasks. It is not a claim that all T3 parity work is covered or complete.

## Starting checkpoint

Start only when remote branch `parallel/baseline-20261024` exists. Clone the public repository if necessary, fetch the branch, and pin its full commit SHA. Never edit main or the baseline branch. The local integration lane owns native builds, shared-file conflict resolution, and final acceptance.

For each task, first inspect existing task records, remote branches and open pull requests. If the assigned branch exists, reuse it only after verifying the pinned baseline is an ancestor; preserve all its current work. If it does not exist, create it from the pinned baseline SHA. Never reset an existing task branch, create duplicate workers, or start from a stale prepared checkout.

The checkpoint includes scratch conversations, Codex provider plan controls and fresh plan implementation, first-send worktree defaults, remote composer/steering/queue/thread actions, keybinding JSONC preservation, transcript correctness, and scratch history ownership checks. Do not reimplement those.

## Task assignments

| Task ID | Feature brief | Assigned branch |
| --- | --- | --- |
| secret-requests | [Scoped secure secret requests](cloud-tasks/secret-requests.md) | `parallel/secret-requests-20261024` |
| pr-links | [Pull request links and watching](cloud-tasks/pr-links.md) | `parallel/pr-links-20261024` |
| pr-review | [Native pull request review workspace](cloud-tasks/pr-review.md) | `parallel/pr-review-20261024` |
| remote-pr-actions | [Reviewed remote pull request actions](cloud-tasks/remote-pr-actions.md) | `parallel/remote-pr-actions-20261024` |
| remote-setup | [Reviewed remote worktree setup](cloud-tasks/remote-setup.md) | `parallel/remote-setup-20261024` |
| storage-cleanup | [Worktree inventory cleanup and retention](cloud-tasks/storage-cleanup.md) | `parallel/storage-cleanup-20261024` |
| media-previews | [Native and remote media previews](cloud-tasks/media-previews.md) | `parallel/media-previews-20261024` |
| diagnostics | [Native runtime diagnostics and redacted export](cloud-tasks/diagnostics.md) | `parallel/diagnostics-20261024` |

## Coordinator workflow

1. Read `cloud-tasks/README.md` and each assigned brief. Use the exact checkpoint and branch rules above.
2. Assign one writer per task in an isolated Git worktree/checkout. A shared directory is not isolation. Use as many workers as the current tools actually support and queue the rest; do not promise eight simultaneous workers without confirming they started.
3. A Work coordinator can use subagents. Batsy can delegate to Work tasks when its tools support that, or use its own cloud checkout and available helpers. If a launcher, writable checkout or shell/Git access is unavailable, report the exact limitation and provide manual-chat instructions. Never invent task IDs or claim submission.
4. Every worker implements the real feature path and tests, including focused shared-file wiring. Put most implementation in feature-specific files. List shared-file changes for the integrator; do not reserve all wiring for imaginary future work.
5. Commit and push only the assigned branch when authorized writes are available. Otherwise preserve the full patch and report the write restriction. Never put credentials in commits, logs, prompts or URLs. No app release, service deployment or external messages are part of these tasks.
6. Track task links/IDs where available, branch SHAs, exact checks run, failures, and unrun macOS acceptance. Distinguish queued, running, source-complete, built, tested and integrated. Do not equate a finished agent run with a working feature.
7. Leave main, the baseline branch and installed apps unchanged. The local macOS lane integrates shared files and runs native builds and final hosted CI/UI checks. Linux cloud work must not pretend to validate AppKit/SwiftUI behavior.

## Separate work preserved locally

Usage dashboard implementation is preserved as unfinished source, including native provider event ingestion and native views; remote wire/old-reader compatibility and tests remain incomplete. Browser preview has preserved design notes but no implementation. Do not duplicate either lane. They need separate handoffs.

Future groups include shared external MCP configuration/OAuth/resources, interactive HTML/MCP Apps, provider/environment management, broader device tools, signed distribution, cloud/persistent access, richer context/layout and other outstanding T3 capabilities. The eight tasks here do not replace those requirements.

## One ChatGPT Work coordinator

Open a new cloud Work chat and paste:

```text
Work on https://github.com/apoorvdarshan/coincide in your cloud workspace. Clone it or use an authorized checkout, fetch origin/parallel/baseline-20261024, and read docs/CLOUD_TASKS.md from that checkpoint. Coordinate its eight tasks with parallel subagents, each in a separate Git worktree on its assigned branch. Use available concurrency and queue the rest. Follow each brief and the shared contract; preserve the reserved Usage/browser lanes and leave main unchanged. Commit and push assigned branches when GitHub write access is available; otherwise preserve complete patches and report the restriction. Report actual worker statuses, commit SHAs, checks and unrun macOS acceptance. Native integration remains with my local Codex session. Do not create a Codex Cloud environment.
```

## Batsy coordinator

Send this to Batsy:

```text
Coordinate the first eight Coincide tasks using ChatGPT Work tasks or your own cloud checkout and available background agents. Use https://github.com/apoorvdarshan/coincide, fetch origin/parallel/baseline-20261024, and follow docs/CLOUD_TASKS.md from that checkpoint. Give each task one owner, its assigned branch and an isolated checkout. Use actual available concurrency; queue the rest and avoid duplicates. Preserve the reserved Usage/browser lanes. Track results and give follow-up instructions until each feature is implemented and handed off. Report actual task links, pushed commits, checks and blockers. Leave main unchanged; my local Codex session owns macOS integration. Do not create or require a Codex Cloud environment. Report any missing Work launcher or repository-write capability honestly.
```

## Separate manual Work chats

Use one new cloud Work chat per task if you prefer direct control. Replace `TASK_ID` with one ID from the table; do not simultaneously assign it to a coordinator.

```text
Work on https://github.com/apoorvdarshan/coincide in your cloud workspace. Fetch origin/parallel/baseline-20261024 and read docs/CLOUD_TASKS.md plus docs/cloud-tasks/TASK_ID.md from that checkpoint. Implement only TASK_ID in an isolated checkout on its assigned branch, including real UI/protocol wiring and meaningful tests. Follow the shared contract and preserve other tasks. Report the pushed commit or complete patch, exact validation and remaining macOS checks. Do not merge main or create a Codex Cloud environment.
```
