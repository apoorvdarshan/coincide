# Active implementation ownership

Current user direction: work in this conversation with built-in subagents, and
prioritize UI parity alongside the remaining core work. The nine separate worker
conversations were stopped and deleted earlier; their pushed code, branches,
worktrees and reports remain preserved. The recently added global parallel-work
rule was removed at the user's explicit request. This board records current
ownership, rather than imposing a global concurrency rule.

| Owner | Current work | Boundary / evidence |
| --- | --- | --- |
| Coordinator | Integration, serial Cargo lane, CI, checklist and elapsed-time reporting | Reviewed commits, actual test results and exact-head CI |
| discard_native | Correct bottom-aligned transcript completed-layout geometry | Vendored List geometry plus media visibility accessors; geometry regressions |
| limits_review | Assistant transcript body/footer presentation parity | Source-backed Swift comparison; existing action/selection guards preserved |
| limits_ui | Native image-display and UI acceptance | Isolated V4 fixture, approved synthetic data, exact byte guards, actual Quit |

Each implementation owner uses an isolated checkout. Shared entry-point changes
have distinct function scopes and are integrated by the coordinator. A committed
checkpoint is ready for review and validation; it is not feature acceptance.

The coordinator owns the single Cargo writer for
`/tmp/coincide-rust-rewrite-target` (10 jobs). Linux and Windows validation runs
through GitHub Actions. The ASUS/SSH lane remains closed.

Needed foreground native testing is explicitly authorized. Only one owner uses
Coincide Computer Use at a time, currently limits_ui when its exact candidate is
ready. Candidates use unique bundles and task-owned data; the active Swift app
and user data remain untouched. Synthetic acceptance does not authorize a
production cutover, install, release, real vault operation or provider submission.

The broad acceptance checklist in STATUS.md remains open. The latest source and
runtime evidence there supersedes historical worker reports. Elapsed wall time
includes the inactive overnight gap; work must not be described as continuous.
