# Rust replacement monitoring checklist

Updated 2026-11-06, 15:47 IST. This is a manual progress snapshot.
The Rust preview works; the full replacement is unfinished. There is no measured,
weighted overall completion percentage. The 7/32 count in [STATUS](STATUS.md)
counts completely accepted feature groups and hides progress within open groups.

## Verified workflows

- [x] Independent macOS build; Windows/Linux compilation checks.
- [x] Lossless import, original-file capture, unknown-field preservation and rollback.
- [x] Scoped project/history workflows, saved-state restart and transcript actions.
- [x] File attachment, duplicate prevention, scoped paths and saved-card restart.
- [x] Named Codex model selection and independent restart proof locks.
- [x] Usage display and standalone `/usage-limits` routing.
- [x] Keyboard settings, bulk selection, Pin Undo and Archive/Restore.
- [x] CLI socket/message compatibility and create-only option validation.
- [x] Actual shipped CLI-to-server creation, atomic rejection, unsent draft and
  storage preservation; normal server shutdown passed.

These checkmarks apply to the scoped flows in STATUS, including their stated
limitations; they do not claim complete feature-group parity.

## Active work

- [ ] Native file suggestion keyboard acceptance: V1 failed before popup
  validation on an unexplained submission; V2 is prepared with checks after every
  input. No passing keyboard acceptance is claimed.
- [ ] Read final creation-batch CI results after the local checks passed.

## Remaining full-replacement work

- [ ] Finish and verify remaining UI, shortcut, focus, scroll and accessibility parity.
- [ ] Close remaining provider/account, conversation and CLI behavior gaps.
- [ ] Finish and verify integrated browser/password, terminal/Git/GitHub,
  scheduling/bot, voice and remote workflows.
- [ ] Complete real-account, failure/restart and full end-to-end acceptance.
- [ ] Resolve the updater's authoritative process-identity blocker; verify signed
  install and rollback without weakening the guard.
- [ ] Rehearse safe data cutover, then retire the old desktop only when authorized.

Latest combined source checks: 584 Core unit tests, every Core integration target,
12 CLI socket tests, strict Core Clippy, 421 desktop unit tests, all four desktop
integration targets (19/10/14/11), formatting and ordinary build passed. These
automated passes do not substitute for the open native or real-account checks.
The new actual CLI/server regression and the full three-test headless CLI suite
also passed, followed by strict Core Clippy.
