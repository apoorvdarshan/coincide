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

## Current integration and remaining work

- [ ] Finish hosted verification of
  [#277](https://github.com/apoorvdarshan/coincide/pull/277): shared inspectors,
  Settings scroll surfaces and native account storage. The actual Windows setup
  source/DB-ownership failure has a production fix with a native regression;
  its final head still requires all hosted checks.
- [ ] Finish hosted verification of
  [#278](https://github.com/apoorvdarshan/coincide/pull/278): per-thread inspector
  restore and Windows/Linux microphone capture. Its exact callback-lifetime and
  Windows setup fixes require new hosted checks; no personal device was used.
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
