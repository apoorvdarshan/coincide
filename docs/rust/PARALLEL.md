# Active parallel implementation ownership

This board tracks delivery through integration, tests and acceptance. A pushed
worker checkpoint is ready for integration, not feature completion. The
coordinator assigns the next gap when an owner finishes; status questions do not
pause implementation. All current workers use `gpt-6.1-sol`.

| Owner | Active partial item | Owned files / boundary | Completion evidence |
| --- | --- | --- | --- |
| Builtin models_sol | Strict selection and runtime model catalog | core composer_selection/model_catalog, API and tests | Atomic rejection/no silent loss, bot lock, synthetic protocol tests and CI |
| Builtin palette_sol | Composer controls, Settings search, parent Find/browser mounts | desktop main/settings, composer presentation; narrow provider-settings binding fix | Integrated build/workflow tests and native routing/draft preservation |
| Builtin native_sol | Palette focus and terminal/IME acceptance | isolated native fixture; terminal_workspace/command_palette fixes only | Screenshot/API/PTy readbacks, no duplicate input, stable split geometry |
| Terminal thread | Shell markers, cwd and command output | core terminal.rs, terminal_shell.rs and fixtures | Synthetic PTY/shim tests; untrusted output never executes or changes cwd |
| GitHub thread | Inline review threads, pagination and mentions | new core/desktop github_threads modules, narrow shared runner accessor | Scoped fake-gh pagination/cancellation and mounted read UI |
| Workspace thread | Native transcript Find | transcript_find.rs and narrow transcript state/highlight hook | Unicode rendered ranges, folded/offscreen reveal, focus and copy preserved |
| Credentials thread | Browser profiles and password approval/settings | browser.rs, credentials/credential_settings, new browser_settings | Synthetic profiles/vault/pages, Allow/Deny/revocation, no secret leakage |
| Host thread | Computer Use adapter, broker and permission UI | new core/desktop computer_use modules and native shim | Default-off/inert startup, strict grants/tokens, injected tests and compile |
| Packaging thread | Installer/helper transaction and rollback | updater_install.rs, staged updater handoff, optional settings module | Temporary-filesystem/process recovery tests; real trust adapter code |
| Organization thread | Historical image workflow and overlay | legacy_media_service.rs and named Store opener/CAS helpers | Existing-only DB open, source/overlay conflicts, partial receipts and renderer verification |

## Shared resources and integration

- Coordinator owns root merges, manifests/build registration, cross-module
  registration, immutable candidate builds, checklist updates and CI monitoring.
- One Cargo writer per shared target. Mac target:
  `/tmp/coincide-rust-rewrite-target` (10 jobs). Linux target:
  `/home/apoorv/coincide-work/rust-gpui-rewrite/target` (12 jobs).
- One Computer Use owner at a time. Native acceptance uses isolated data, fake
  gh/providers/vault/shell and an immutable candidate with recorded source/hash.
- Each code worker uses its own branch/worktree; commit/push with secret review.
  Entry-point ownership is explicit; request integration hooks through coordinator.
- Existing Swift and ordinary Rust app instances/data remain untouched. No real
  provider/vault/model/microphone/TCC/notification operation, installation,
  release or cutover is authorized by synthetic acceptance.

## Current lane queue

1. Composer contract/API tests: passed 7 + 7 on Mac.
2. Paired desktop compile: fix stale provider-settings model binding, then rerun.
3. Historical-media service/opener/CAS fixtures after reviewed checkpoint.
4. Native terminal resize regression on next immutable integrated candidate.
5. Register and validate subsequent worker deliveries as they arrive; keep
   independent work running while builds and CI execute.
