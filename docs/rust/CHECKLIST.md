# Rust replacement monitoring checklist

Updated 2026-11-07. Shared UI/UX parity is required on macOS, Windows, and Linux;
fonts, styling, window chrome, and primary modifiers may follow each platform.
The running Swift app and actual user data remain authoritative. No installation,
cutover, updater activation, or release has been performed by this UI work.

## Verified merged slices

- [x] Account/model restoration and independent native-session restart foundation:
  [#264](https://github.com/apoorvdarshan/coincide/pull/264),
  [#265](https://github.com/apoorvdarshan/coincide/pull/265),
  [#267](https://github.com/apoorvdarshan/coincide/pull/267).
- [x] Shared desktop workflow foundation:
  [#266](https://github.com/apoorvdarshan/coincide/pull/266), including scoped
  native macOS and Windows/Linux input, Settings, selection, draft and restart checks.
- [x] Explicit Instructions Git controls and owned operations:
  [#268](https://github.com/apoorvdarshan/coincide/pull/268). Actual handlers and
  local Git passed with the OS picker response injected; physical picker entry
  is separate from that headless result. Global user instruction files were unchanged.
- [x] Shared navigation rail, sidebar grouping/actions and persisted preferences:
  [#272](https://github.com/apoorvdarshan/coincide/pull/272), tested at
  `a7b632ed746d758e733da1e72dc849a1cb8c8aca` and merged with the identical tree.
  All 14 applicable hosted checks passed. Actual Windows/Linux render, keyboard
  input, separate Settings close, normal Quit and older-selection/draft restart
  passed; both platforms' screenshots were reviewed.

- [x] Shared composer/Settings, Project Defaults, lifecycle actions, text queue
  editing, empty-chat reuse, snooze wake-up and off-by-default Appshots foundation:
  [#274](https://github.com/apoorvdarshan/coincide/pull/274), tested at
  `2c7f4ca97326696c0b77733b60c6d5380bb133a2` and merged as
  `dd89c4884c43ea722e1f873c77600da63233ba67` with the identical tree. All 14
  applicable hosted checks passed. Core 693 and every integration target passed;
  Desktop 503 plus its four integration targets passed. Actual Windows/Linux
  input, separate Settings close, ordinary Quit and older-selection/draft restart
  passed; both platforms' screenshots were reviewed. This is scoped acceptance.

- [x] Shared composer payloads, source-bound replies/context, folder completion,
  provider configuration and main-window polling across Settings close:
  [#275](https://github.com/apoorvdarshan/coincide/pull/275). Exact tested/merged
  tree `8fc944f0b1d60e480d7218b16a222e78827ce796`; all 14 applicable hosted
  checks and actual Windows/Linux Settings/Quit/draft restart passed.
- [x] Bottom/right terminal placement, owned activation, nested environment
  redaction and Hold to Quit:
  [#276](https://github.com/apoorvdarshan/coincide/pull/276). Exact tested/merged
  tree `a3fafcbe03dc3acccbb31f51c1c6b84c787ad18a`; every applicable hosted check
  passed. Both Windows/Linux native double-press Quit and ordinary drain passed.

- [x] Shared inspectors, retained Settings scrollers and native account storage:
  [#277](https://github.com/apoorvdarshan/coincide/pull/277). All applicable
  hosted checks and actual Windows/Linux input/Settings/Quit/restart passed.
- [x] Per-thread inspector restoration and owned Windows/Linux microphone
  capture foundations: [#278](https://github.com/apoorvdarshan/coincide/pull/278).
  Actual native app checks passed. No personal audio device was opened.
- [x] Source-bound composer dictation, shortcut lifecycle and owned Windows
  offline transcription process support:
  [#279](https://github.com/apoorvdarshan/coincide/pull/279). Synthetic dictation
  and real fake-CLI child-process tests passed; native app checks also passed.
- [x] Native account API-key controls, private Voice credentials and owned
  Windows power assertion: [#280](https://github.com/apoorvdarshan/coincide/pull/280).
  Actual fresh macOS/Windows/Linux secret-store write/read/delete/absence checks
  and the Windows power acquire/release test passed on isolated runners.
- [x] Saved Voice device/engine/language/mode pickers, explicit device refresh,
  separate provider Admin usage controls and legacy account home exclusion:
  [#281](https://github.com/apoorvdarshan/coincide/pull/281). All applicable
  hosted checks passed at `d345eece572aaf77dbb3c481656969904fdcbc3b`, merged
  as `d7929a66cf52b550e429941f1a5b6a4e4336aa15` with an identical tree.
  Actual Windows/Linux Settings, native draft input, ordinary and guarded Quit,
  and older conversation/draft restoration passed; screenshots were reviewed.

## Current integration and remaining work

- [ ] Finish [#282](https://github.com/apoorvdarshan/coincide/pull/282): owned
  Windows GitHub operations, reviewed account removal and all-page Settings
  acceptance. A prior run rendered all sixteen Settings routes but hung on
  ordinary Quit; retained child polling has a production fix and private GPUI
  regression, and final native CI remains required.
- [ ] Finish [#283](https://github.com/apoorvdarshan/coincide/pull/283): Windows
  UI Automation and exact-window capture/input. Actual SDK compilation and
  inert/fake tests passed; isolated own-window runtime acceptance is pending.
- [ ] Finish [#284](https://github.com/apoorvdarshan/coincide/pull/284): verified
  local model assets, on-device Apple Speech, Codex authentication lifecycle,
  portable GitHub Engine mounting, Linux notifications, persistent Settings
  headers and original-window native picker completion. Actual Apple final
  linking passed; combined and platform runtime gates remain pending.
- [ ] Complete and verify all provider-account modes, model/account pickers,
  reviewed removal, private Voice credentials and API transcription engines.
- [ ] Verify composer dictation, native shortcut/focus/cancel behavior, Windows
  offline inference, actual audio-level receipts, device selection and local models.
- [ ] Finish all remaining screens, menus, dialogs, shortcuts, scrolling,
  accessibility and loading/error states against Swift on every platform.
- [ ] Complete browser/password, terminal/Git/GitHub, scheduling/bot, background/
  power and remote workflows and their end-to-end acceptance.
- [ ] Complete real-account and failure/restart acceptance within the permitted
  providers. Antigravity live testing remains off; its fake gates are separate.
- [ ] Resolve signed updater/process identity, installation/rollback and data
  cutover acceptance only within separately authorized migration work.

The broad inventory in [STATUS](STATUS.md) counts fully accepted feature groups;
it is not a weighted completion percentage. Source implementation, automated
checks, scoped native UI checks and full feature acceptance remain distinct.
Appshots is off by default. Its capture/hook/permission acceptance is unperformed,
and automatic front-window Appshots on Wayland remains unavailable.
