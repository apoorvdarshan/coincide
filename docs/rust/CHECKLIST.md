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

## Current integration and remaining work

- [ ] Complete [#275](https://github.com/apoorvdarshan/coincide/pull/275), including
  [#273](https://github.com/apoorvdarshan/coincide/pull/273)'s reviewed executable,
  environment and external-terminal provider setup controls, metadata checks and
  captured worker configuration. Focused synthetic checks pass; full combined and
  all-platform validation remain required.
- [ ] Verify newly integrated selectable context details, source-bound selected
  replies, folder/file autocomplete, named-account queue dispatch and Send Now.
  Actual private GPUI fixtures passed the context readonly/copy case, both reply
  selection cases and all eight composer dispatch cases before payload integration.
- [ ] Verify image/context payloads through queued, steered and interrupted
  follow-ups, Queue Edit and Send Now. These are implemented in the next combined
  head; prior text-only acceptance does not cover their new content paths.
- [ ] Complete remaining provider account modes and General thread settings.
- [ ] Finish all remaining screens, menus, dialogs, shortcuts, focus, scrolling,
  accessibility and loading/error states against Swift on every platform.
- [ ] Complete browser/password, terminal/Git/GitHub, scheduling/bot, voice,
  background/power and remote workflows and their end-to-end acceptance.
- [ ] Complete real-account and failure/restart acceptance within the permitted
  providers. Antigravity live testing remains off; its fake gate tests are separate.
- [ ] Resolve signed updater/process-identity, installation/rollback and data
  cutover acceptance only within separately authorized migration work.

The broad inventory in [STATUS](STATUS.md) counts fully accepted feature groups;
it is not a weighted completion percentage. A source implementation, a passing
unit suite, a scoped native test and full feature acceptance are separate results.
Appshots is off by default. Its macOS/Windows/X11 source and synthetic lifecycle
checks do not establish actual capture or permission acceptance, and automatic
front-window Appshots on Wayland remains unavailable.
