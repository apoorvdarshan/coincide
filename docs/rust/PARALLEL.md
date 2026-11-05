# Active parallel implementation ownership

Current user direction: built-in subagents only. All nine separate worker
conversations were stopped and deleted through the app API; their pushed code,
branches, worktrees and reports are preserved. The recently added global
parallel-workers section was removed at the user's explicit request.

This board tracks delivery through integration, tests and acceptance. A pushed
worker checkpoint is ready for integration, not feature completion. The
coordinator assigns the next gap when an owner finishes; status questions do not
pause implementation. All current workers use `gpt-6.1-sol`.

| Owner | Active partial item | Owned files / boundary | Completion evidence |
| --- | --- | --- | --- |
| Coordinator | Integration, Cargo lane, CI and shutdown-owner wiring | root manifests/main, shared registration and evidence | Focused tests, immutable candidates and exact-commit CI |
| Builtin models_sol | Engine admission freeze and provider exit accounting | core API, queue/scheduler guards, provider worker observers | Deterministic fake-worker/persistence tests; actual background join acknowledgement |
| Builtin palette_sol | Frozen draft adapter and immutable acceptance preparation | desktop main adapter; scratch candidate/harness snapshots | One-lock persistence decision, preserved retries, source/hash manifests |
| Builtin native_sol | Pipe portability, control-worker status and allocated native acceptance | updater_helper/control boundaries; isolated fixture apps only | Genuine-pipe validation, TLS join gates, fresh native observations |

The coordinator and built-in owners retain responsibility for the earlier
terminal, GitHub, workspace/Find, credentials, host, packaging, organization and
media-recovery slices. Their separate conversations are retired, not active lanes.

## Shared resources and integration

Current user authorization permits needed native UI/Computer Use testing during
the overnight completion run. Earlier headless-only constraints are superseded.
No ASUS or SSH. Preserve active apps/data, use isolated immutable fixture bundles,
and keep native_sol as the sole Computer Use owner. Do not recreate separate
worker conversations. Source, CLI/API and GitHub Actions checks continue in parallel.

- Coordinator owns root merges, manifests/build registration, cross-module
  registration, immutable candidate builds, checklist updates and CI monitoring.
- One Cargo writer per shared target. Mac target:
  `/tmp/coincide-rust-rewrite-target` (10 jobs). Linux/Windows validation uses
  GitHub Actions; the ASUS lane is closed.
- One Computer Use owner at a time. Native acceptance uses isolated data, fake
  gh/providers/vault/shell and an immutable candidate with recorded source/hash.
- Each code worker uses its own branch/worktree; commit/push with secret review.
  Entry-point ownership is explicit; request integration hooks through coordinator.
- Existing Swift and ordinary Rust app instances/data remain untouched. No real
  provider/vault/model/microphone/TCC/notification operation, installation,
  release or cutover is authorized by synthetic acceptance.

## Current lane queue

1. All five Rust CI jobs passed at `276ec83`; subsequent CLI and Computer Use
   mount changes require their own integrated checkpoint. CLI six focused Mac
   tests and strict core Clippy passed at `9a570dd`.
2. Desktop suite passed 233 tests. Actual service-to-recovery integration passed
   four tests; Computer Use shared-authority collection fencing passed nine.
3. Native candidate13 reveals folded/hidden Find targets correctly but crashes
   on the far-away target with a duplicate accessibility node ID. Find and main
   owners diagnose; native owner records evidence and preserves original apps.
4. Standalone synthetic browser approval harness compiled. Native Allow/Deny,
   revocation and inspection-shield acceptance uses fake vault data only.
5. Host mount is frozen; palette owner registers it outside the Engine guard.
   Models owner implements bounded scalar thread resolution and synchronous
   selection-change revocation; CLI owner consumes the frozen resolver contract.
6. Packaging owner implements the default-off signed helper. Actual shutdown
   hooks and OS/crash custody protection remain open. Linux lane is idle after
   focused CLI validation; no duplicate full-suite work is allocated.
