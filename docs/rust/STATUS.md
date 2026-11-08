# Rust / GPUI rewrite

This is a replacement implementation in progress, not a replacement release.
The running Swift application and its data remain authoritative until cutover.
The new desktop uses `Coincide Rust`, a separate data directory and control socket.
Do not point both applications at one mutable data store.

## Acceptance checklist

This inventory counts fully accepted feature groups. It is not a weighted
engineering completion percentage: a group can contain many implemented and
verified workflows while remaining open for other required behavior. Report
recent workflow results separately instead of treating 7/32 as overall progress.
An implemented but untested item remains unchecked. The inventory is based on the macOS README, app structure,
provider protocols and CLI command parser. Expand it when another behavior is found.

- [x] Rust workspace and independent GPUI macOS build.
- [x] Native Linux desktop compilation and scoped input/Settings/Quit/restart checks.
- [x] Native Windows desktop compilation and scoped input/Settings/Quit/restart checks.
- [x] Lossless source-file capture and transactional thread import.
- [x] Preserve unknown fields, attachments, drafts and provider session references.
- [x] Rollback invalid/duplicate imports and refuse symlink traversal.
- [x] Display imported conversations in the macOS preview.
- [ ] Match Swift UI and UX in shared Rust on macOS, Windows and Linux, allowing
  platform-appropriate styling: window/sidebar layout,
  typography, spacing, colors, icons, transcript/composer, panels, menus, dialogs,
  shortcuts, focus, scrolling, loading/error states and accessibility. Verify
  equivalent screens and interaction flows side by side before migration.
- [ ] Complete projects, bots and projectless-chat navigation.
- [ ] Search, pin/archive, multi-select, undo/redo and snooze parity.
- [ ] Fully selectable, virtualized transcript, markdown, media and previews.
- [ ] Composer: attachments, context, file mentions, slash commands and drafts.
- [ ] All six agent providers, account selection and model catalogs.
- [ ] Streaming, approvals, user questions, plan/full-access modes, cancellation.
- [ ] Resume, mid-thread handoff, steer, queue, fork, rewind and edit/resend.
- [ ] CLI/API command parity, thread-scoped access and machine-readable errors.
- [ ] Terminal PTY, tabs, splits, selection and shell integration.
- [ ] Git diff, checkpoints, worktrees and hosted change-request operations.
- [ ] GitHub PR workspace, reviews, exact-head merge and mentions.
- [ ] Browser profiles, tabs, downloads, frames, agent bridge and human handoff.
- [ ] Password managers, imports, autofill and passkeys.
- [ ] Computer-use bridge and permissions.
- [ ] Scheduling, approval cards, busy-thread behavior and persistence.
- [ ] Bots, instructions, task records and CLI-session import.
- [ ] Dictation and transcription settings/providers.
- [ ] Usage/limits dashboard and histories.
- [ ] Settings, shortcuts, themes, localization and accessibility.
- [ ] Background agent host, keep-awake, power helper and appshots.
- [ ] Notifications, remote companion connectivity and iCloud alerts.
- [ ] Signed packaging, updater, rollback and installation/distribution.
- [ ] Real-account acceptance, full test parity and data cutover rehearsal.
- [ ] Remove superseded Swift/C++ desktop implementation and build tooling.

## Current integration (2026-11-07)

Checkpoints [#277](https://github.com/apoorvdarshan/coincide/pull/277) through
[#282](https://github.com/apoorvdarshan/coincide/pull/282) are merged after
exact-head checks and identical-tree verification. They add shared inspectors,
Settings scrolling and retained child polling, native credential controls,
source-bound dictation, device pickers, organization usage, reviewed account
removal and owned Windows/Linux platform foundations. Actual Windows/Linux
app input, separate Settings close, ordinary/guarded Quit and older selected
conversation/draft restart passed; screenshots and reports were reviewed.
The final #282 run also rendered all sixteen Linux Settings routes. These
results do not prove personal-device audio capture or live provider setup.

[#283](https://github.com/apoorvdarshan/coincide/pull/283) through
[#290](https://github.com/apoorvdarshan/coincide/pull/290) remain drafts pending
final combined checks and native runtime acceptance. The current sources add
Windows UI Automation, verified Voice models and Apple Speech, account lifecycle,
Linux notifications, persistent Settings controls, activity routing, native
browser history/dialogs/keys, isolated browser profiles, inline dictation,
Linux Computer Use and PR involvement filters. Actual SDK tests have exposed
and are driving repairs to Windows provider connection timing, browser history
self-navigation rejection and a Linux controlled-window freshness boundary.
Earlier failures remain recorded; compilation or fake tests do not close them.

The Apple Speech bridge compiled and linked against the actual SDK with a
macOS 14 deployment floor. It was not executed on the personal host. Windows
notification delivery and safe PR checkout remain separate implementation work.
No user microphone, vault, desktop-control permission, live provider or external
review was exercised during this unattended continuation. Antigravity live
testing remains off. The running Swift app and user instruction files are unchanged.


Shared UI/UX parity applies to macOS, Windows and Linux. The current verified
merged sidebar is [#272](https://github.com/apoorvdarshan/coincide/pull/272),
exact tested head `a7b632ed746d758e733da1e72dc849a1cb8c8aca`, merged as
`677c7a7049392dff1b20cf3e8d3dfcbef061b5b7` with the identical tree. All 14
applicable hosted checks passed, including actual Windows/Linux native input,
Settings open/close, normal Quit, and restoration of an older selected chat and
its unsent draft. This is scoped workflow acceptance, not full UI acceptance.

Instructions Git [#268](https://github.com/apoorvdarshan/coincide/pull/268) is also
merged after exact-head checks. Its headless test exercised the actual native
handlers and real local Git operations with an injected picker response; no
physical picker-entry result or modification of global user instructions is claimed.

[#274](https://github.com/apoorvdarshan/coincide/pull/274) is merged as
`dd89c4884c43ea722e1f873c77600da63233ba67`, with the identical tree to tested head
`2c7f4ca97326696c0b77733b60c6d5380bb133a2`. All 14 applicable hosted checks passed.
Core 693 and every integration target passed; Desktop 503 and all four integration
targets passed. Actual Windows/Linux input, separate Settings close, ordinary Quit
and older-selection/draft restart passed and both platforms' screenshots were
reviewed. Its composer, Settings, Project Defaults, lifecycle, queue editing,
empty-chat reuse, snooze wake-up and Appshots results remain scoped; actual
Appshots capture/hooks/permissions are unverified.

[#275](https://github.com/apoorvdarshan/coincide/pull/275) is merged as
`6b0496e944c3fa8c0fe34c83bc4a0759109c579e`, with the identical tree to tested
`f8f4655fc94af4202f027af31a954d920e29e897`. All 14 applicable hosted checks
passed. Its provider executable/environment/setup controls, selected replies,
context details, folder autocomplete, named-account queue dispatch, Send Now and
image/context follow-up payloads passed the combined Core/desktop checks. Actual
Windows/Linux input, separate Settings close, ordinary Quit and exact older-chat
selection/draft restart passed; screenshots were reviewed. The Linux provider-page
screenshot proves navigation, not completed configuration loading or live login.

Opening Settings had also exposed a shared-owner window-association bug: closing
it stopped the main polling loop. The fix captures the main window explicitly.
A real GPUI regression reproduces the old failed lookup and verifies continued
revision observation, ordinary Quit admission and actual closed-main refusal.

[#276](https://github.com/apoorvdarshan/coincide/pull/276) is merged as
`fd7b2cf33720ddb8693dbbe63d0b8c5e81aac6a4`, with the identical tree to tested
`290facc0a3c205df24819ace4f1d4d92463f2040`. Every applicable hosted check passed.
It adds bottom/right placement of the same cached terminal workspace, persisted
geometry, terminal activation handshakes, nested account-environment redaction,
and Hold to Quit. Both Windows/Linux native runs proved the first brief Ctrl+Q
kept ordinary admissions available and the second within 1.5 seconds exited
normally, preserving selection and draft across restart. This does not establish
real shell/IME, provider authentication or hardware acceptance.

The platform and composer results above supersede the older pending notes for
#277–#281. Actual Appshots capture/hooks/permissions, complete provider workflows
and full Swift screen-by-screen acceptance remain distinct unfinished gates.

See [CHECKLIST](CHECKLIST.md) for the current concise worklist. The following older
checkpoints retain their original evidence and limitations; their pending notes
may have been superseded by the scoped results above.

## Historical combined checkpoint (2026-11-06)

The broad inventory remains 7 of 32 accepted areas. Partial source and scoped
native results do not close a full feature row.

- The ordinary 83990b9 account/keyboard run passed native profile creation,
  per-thread selection/default restoration and explicit fake device-challenge
  cancellation/reap, with exact preserved data. Keyboard recording persisted,
  but Done followed by the custom New shortcut failed; the mapping worked only
  in a separately labeled real composer-focus diagnostic. The original failure
  remains preserved. A later live-root source-pin check also failed because the
  coordinator allowed source integration during the frozen-binary run; no guard
  was edited or weakened. The run quit normally and remains failed/unfinished.
- The focus fix moves Settings route transitions to the persistent navigation
  owner. Both real headless draw/dispatch regressions passed without composer
  focus. Bulk Select/Pin/Archive/Restore and scoped Undo passed six Core tests,
  the full 568-unit Core run and every integration target, plus strict feature
  Clippy. The combined desktop passed 402 units and all four integrations.
  Fresh ordinary 4585755 keyboard/bulk V2 acceptance subsequently passed all
  26 frozen checkpoints and both normal exits (11m56.50s combined runtime).
  Done followed by the custom New shortcut worked without a composer click;
  recording, disable, conflicting bindings, restart and reset-all passed.
  Two-row selection did not navigate, Pin Cancel wrote nothing, Pin Undo
  restored exact raw/cache/FTS snapshots, and Archive/Restore returned both
  originals byte-exact. Eight denied Git probes, zero other executable
  categories; every frozen source/data guard passed. The prior V1 failure
  remains preserved. Exact 4585755 also passed all six Rust CI jobs,
  packaging, general CI and iOS tests.
- Named Codex model catalogs and the explicit composer project-file picker are
  now integrated for combined validation. Named discovery authenticates the
  captured private profile before paginated model/list; model selection and
  actual turns require the matching account/thread/directory/auth generation.
  The isolated fake protocol integration and strict Core Clippy passed before
  integration. The file picker appends path-only reference data, preserves
  message text and checks exact thread/project/file freshness before committing.
  The combined Core run passed 577 units and every integration target; strict
  feature Core Clippy passed. Desktop passed 406 units and all four integration
  targets (19, 10, 14, 11). A follow-up bounds the file results while keeping
  Close/Search reachable and adds file-specific accessibility labels; its final
  full desktop check passed. Fresh native acceptance is in progress. A follow-up
  adds focused-caret file suggestions and guarded native @query completion;
  its combined tests and native acceptance are pending. Broader named-profile
  options remain open.
- The first ordinary 58609d3 file-picker native run found clipped controls when
  existing reference cards occupied the composer accessory. One real scroll
  confirmed the layout defect; an offscreen Search action did not establish an
  imported-thread refusal. The run stopped with normal exit zero after 128.81s,
  all four raw rows/imported sources/cache/FTS and frozen guards exact, one denied
  Git probe and no file listing, attachment or restart. That failure remains
  preserved. The follow-up gives the open picker the primary accessory viewport,
  temporarily compacts the draft and hides competing footer/status content;
  stored draft/context/selection are retained. Fresh native verification is pending.
- Automatic file completion uses the existing editor's explicit UTF-16 range
  edit only after current draft/context/caret/IME and grapheme-boundary checks.
  Context attaches first; changed input afterward keeps its newer text and the
  committed reference. Surrounding bytes are preserved. Secondary carets follow
  the editor's collapse behavior; folder completion, keyboard result selection
  and exact Swift popup placement remain open.
- Ordinary 170cef9 passed the fresh file-picker V2 native workflow: all 13
  checkpoints, imported-thread refusal, Unicode query changes, Close, real
  thread-change revocation, project isolation, one path attachment, duplicate
  no-op and saved-card restart. Both normal exits were zero (10m22.02s combined).
  Draft/context/session/unknown/source/file/cache/FTS guards passed. Six denied
  Git probes and seven scoped fake listings; no other executable category.
  Controls fit the observed 820x552 minimum frame; exact content bounds were
  not measured. Results require an actual inner scroll. A newer compact-list
  presentation is integrated for validation, with native first-row visibility
  still pending. The earlier V1 layout failure is unchanged.
- The same ordinary candidate verified focused-caret automatic suggestions,
  stable blink/dismissal intervals, real caret-move reopening, exact native
  completion of only `@src/café`, and restart readback with Unicode prefix,
  suffix and both remaining spaces intact. Both normal exits were zero.
  Ten original checkpoints passed. The original restart-loaded checker failed
  because it required the first process's socket to remain absent after a
  legitimate restart. Its failure and source remain preserved; a separate
  read-only supplement proved the prior exit, exact saved state and kernel
  ownership of the new socket before the remaining original checks passed.
  This is qualified application acceptance, not an as-written fixture pass.
- Named-profile native A refresh and model selection passed on 170cef9. Native
  B selection then retained a stale active-thread capability lock, so no B
  refresh or restart was attempted. Normal Quit exited zero after 326.09s;
  exact preserved data/source/private homes and A1/B0 RPC counts passed. The
  source fix performs the trusted owner handoff and capability read under the
  same nonblocking Engine lock, while retaining real model-proof locks. Its
  three focused owner/cache regressions passed against a real Store/Engine;
  full-suite and fresh native verification are pending.
- Exact 170cef9 passed all six Rust CI jobs, packaging, general CI and iOS tests.
  The new `/usage-limits` opener passed four regressions and the isolated full
  413-unit desktop suite plus every integration target; it opens only existing
  reported default Codex windows without starting another provider read. It and
  the compact file list are integrated with the owner fix for combined checks.
- Exact 7a8d3cc passed all six Rust CI jobs, packaging, general CI and iOS tests.
  Its three real Store/Engine owner regressions and full desktop suite passed
  (416 units plus 19, 10, 14 and 11 integration tests).
- Fresh ordinary 7a8d3cc named-model V2 passed all 15 native checkpoints. The
  formerly failing B transition enabled its own controls without a workaround;
  A/B catalogs and model-only selections stayed scoped. After restart each saved
  explicit model remained locked until its own profile refresh; A's proof did
  not unlock B. Default repair/reselection and both normal exits passed.
  Four synthetic catalog reads (A2/B2), no turns or login, all exact preservation
  guards passed. The original V1 failure remains sealed.
- The same candidate passed all 11 standalone Usage native checks: initial
  local refusal retained the command, one explicit fake limits read showed
  reported 42.5% with absent values left unreported, then `/usage-limits` cleared
  only its exact draft and opened the existing observation without another read.
  Settings search reset, actual Cmd+, routes, normal Quit and restart Idle all
  passed with exact data/source guards and no provider turn. Native focus identity
  was not exposed. Both normal exits were zero (4m41.40s combined runtime).
- Automatic file suggestions now have scoped keyboard selection/activation and
  a measured scroll handle in source. Input actions are captured before native
  submission; held Enter/Tab custody remains through pane hide. Rejected choices
  are revoked and errors shown first. Combined compilation/tests passed on
  8ce2b21: 421 desktop units plus all four integration targets (19, 10, 14, 11),
  577 Core units plus every integration target, strict feature Core Clippy,
  formatting and the ordinary desktop build. Native key acceptance is pending;
  no keyboard runtime pass is claimed yet.
- Explicit CLI socket routing, multiword and bounded UTF-8 stdin messages,
  global `--json`, and empty/context-only text forwarding passed five shipped
  binary socket regressions on the same checkpoint. Task-owned default and
  inherited Swift socket decoys remained untouched. These changes retain Core
  content admission and do not complete the broader CLI/API parity row.
- The scoped CLI follow-up passed all nine compatibility regressions and strict
  feature Core Clippy: exact restore/decline aliases, authoritative user-question
  listing with opaque fields retained, read option equality forms, and help
  aliases. Malformed inputs are rejected before transport, and stale target
  resolution cannot trigger a mutation. Rich thread creation and other CLI
  behavior remain separate open work.
- Structured new-thread options now validate the complete provider/model/account
  and mode tuple before one transactional save. Exact unsent title/draft text is
  retained; omitted options inherit existing validated defaults. Seven real
  Engine/Store regressions passed, including rejected input and cache-write
  rollback with no orphan row or index/revision change. The combined source
  passed 584 Core units and all integrations (including 12 CLI socket checks),
  strict feature Core Clippy, 421 desktop units and all four desktop integration
  targets, formatting and the ordinary desktop build. New-thread Send/Open/Wait
  behavior remains unsupported in this slice.
- The shipped CLI now passed an actual owned server/Engine composition regression:
  exact create-only flags and unsent Unicode API drafts, committed raw rows and
  search indexes, untouched defaults/originals/unrelated data, atomic rejection,
  no provider/Open/Wait effect, and normal shutdown. The full three-test headless
  CLI suite and subsequent strict feature Core Clippy passed as well.
- The first ordinary b8c32dc file-keyboard native run stopped before popup
  acceptance: after focus, End and four Left reads retained the original draft,
  the fifth Left read showed an unexpected synthetic submission. No Send,
  Enter/Return or Tab action was requested. One denied fake provider attempt and
  the changed target row/cache are preserved; causal attribution is unproven.
  Normal foreground Cmd+Q exited zero after 335.53s; earlier background AX Quit
  actions had no observed outcome. Imported originals, the other target, source,
  binary, instructions and input files stayed exact, and native control was
  released. The frozen data checker correctly failed; no restart/replay or
  overall keyboard pass is claimed. A fresh fixture is being prepared.
- Frozen ordinary 6b9645a passed the combined native project/history V2 run:
  real directory-picker duplicate Add, Rename, Locate path field, duplicate
  refusal, counted Remove Cancel/confirm and raw Restore; history picker/review,
  import without navigation, profile isolation and explicit local-page Open.
  The same binary restarted and automatically loaded both saved records.
  Both normal exits were zero; all raw threads, restored projects, originals,
  attachments, working files, source bytes and profile data passed exact guards.
  Nine denied fake Git probes, zero other executable categories. Multi-folder
  Add, a separate Add-picker Cancel and authoritative native focus were not
  exercised. A transient Recovery busy error was retained; the next candidate
  adds an explicit Reload control. The original Swift application is untouched.
- Native Codex profile list/create/scoped selection and explicit device sign-in
  are integrated with keyboard recording/disable/reset for eight existing
  commands. Device enrollment avoids the upstream shared callback-port cancel
  behavior, opens no page automatically, and checks matching completion plus
  subscription authentication. Ephemeral challenges stay out of persistence.
  Keyboard writes retain unsupported imported commands and opaque settings.
  The full Core run passed 562 units and every integration target; strict feature
  Clippy passed. The combined desktop run passed 398 units plus all four
  integration targets (19, 10, 14, 11). Native account/keyboard acceptance and
  real-account verification remain open. A separate audit confirmed both Swift
  and Rust scope global AGENTS to the selected Codex home; no new restriction or
  role-changing developerInstructions workaround was added. Shared HOME skill
  roots survive; default-home plugin/system-cache continuity remains unverified.
  No protected global instruction file was copied, linked or changed.
- Integrated Rust-owned Codex login profiles with private launch homes, captured
  account/session binding and pre-turn subscription authentication. Six profile
  units, the captured-session unit and the actual isolated fake Engine/app-server
  integration passed. The parent exercised its intentionally ignored child.
  Native enrollment/account Settings acceptance and named model/catalog/limits
  parity remain open; no real login or provider submission was performed.
- Integrated native project add/rename/relocate and explicit counted removal with
  transactional raw recovery and Restore, plus profile-bound history review,
  import, restart persistence, saved list and explicit new-tab open. The combined
  Core unit run passed 560 tests (seven intentional ignored fixtures); the subsequent
  full integration/desktop batch passed as listed above; combined native project
  and history acceptance subsequently passed in the scoped V2 run above.
- The ordinary transcript fixture on exact 5b5a9a2 passed user/assistant layouts,
  reasoning/tool Expand/Collapse, hidden-tail Find and Next/Previous, visible
  Unicode selection, full assistant Copy and one real Edit branch. A real Core
  HistoryPlan comparison verified that branch before a native paste verified the
  full copied source. Original raw rows/documents and all frozen files remained
  exact; normal Quit exited zero. Three denied fake Git probes, zero provider or
  vault calls. Exact selected-range clipboard and native AX focus remain open.
- Explicit Codex commandExecution display metadata passed five focused tests and
  strict Core feature Clippy. The historical image viewer now declares a Dialog
  role and label; this semantic correction passed desktop compilation but does
  not establish native focus restoration.
- Exact 6b9645a passed all six Rust jobs, packaging, general CI and iOS tests.
  Both completed Linux main-archive provisioning samples took 47 seconds, versus
  prior 23-second and 15m09s Azure samples. The bounded mirror change retains all
  packages/checks; runner variance prevents a fixed runtime promise.
- Updater/cutover remains blocked by unresolved authoritative identity of two
  existing processes. The strict guard remains closed; no install or rollback
  success is claimed. The active Swift application/data remain authoritative.

## Current UI parity slices

These narrower results do not close the broad UI/UX row above.

| Slice | Source / automated checks | Native acceptance |
| --- | --- | --- |
| Persistent rail, collapsible list, compact toolbar | Integrated and tested | Scoped pass, including focus/draft preservation and minimum-width reachability |
| Saved-selection composer footer | Integrated; guarded selection flow retained | Scoped pass for footer/disclosure |
| Pinned and Chats sections | Integrated and tested in the combined suite | Grouping/search/snooze/archive observed; strict fixture failed its zero-executable guard on two denied fake Git probes, leaving no pre-Pin raw baseline |
| Assistant body-first layout and compact signature/actions | Integrated and tested in the combined suite | Scoped ordinary-build pass |
| Historical image preview and enlarged viewer | Actual completed-geometry fix and paint/rollback token guard integrated; all 43 List tests pass, including seven new regressions | V5 passed full-image containment at wide/minimum/widened sizes, Escape/Close, normal Quit and exact preservation; focused-element proof remains unverified |
| Sidebar drag resizing | Integrated using verified Swift dimensions; four bounds, gesture and Store-preservation fixtures pass | Foreground min/max, narrow/wide behavior and restart preservation passed; content geometry measured approximately from screenshots |
| User bubble/actions, project/branch subtitle and left-aligned sidebar labels | Follow-up passed 382 desktop tests and every integration target | Header/subtitle, sidebar alignment and compact image action observed in V5; user bubble/actions observed in the ordinary roles fixture |
| Keyboard recorder and Codex account Settings | Integrated; 402 desktop units/all integrations, 568 Core units/all integrations, strict Core Clippy and two actual GPUI focus regressions passed | Profile create/scoped selection/fake device cancellation passed in V1; fresh keyboard recording/disable/conflict/restart/reset-all passed all V2 guards; real login remains open |
| Counted bulk selection, Pin/Archive/Restore and scoped Undo | Integrated; full Core/desktop checks passed | V2 passed selection without navigation, review Cancel, exact Pin Undo and Archive/Restore, both normal exits and all preservation guards |
| Named Codex profile model catalog | Integrated; actual fake protocol integration, combined Core/desktop checks, strict Core Clippy and three owner/cache regressions passed | Fresh V2 passed all 15 native checks, independent restart proof locks, default repair and both exits; V1 failure preserved; real-account verification remains open |
| Composer project-file path references | Explicit picker and bounded results integrated; six Core and three desktop regressions passed | V2 passed all 13 native checks and both exits with exact preservation; results require inner scrolling; compact-list follow-up pending native visual verification |
| Automatic caret file completion | Unicode/grapheme, IME-veto, revision and scoped key-controller regressions passed | Exact native query removal and restart verified with 10 original stages plus a separate restart-owner supplement; the subsequent keyboard V1 stopped on an unexplained submission before popup validation; keyboard/folder/multi-caret parity remains open |
| Standalone `/usage-limits` | Four regressions and full desktop suite passed; only current reported default Codex windows are supported | All 11 native checks, one explicit fake refresh, opener without another read, Cmd+, routing and both normal exits passed |
| Tool/reasoning work-card header and disclosure | Explicit known status/title/category metadata only; 385 desktop tests plus every integration target pass | Ordinary native disclosure, hidden-tail Find, full Copy and one verified Edit branch passed |

## Overnight checkpoint (2026-11-05)

Work is coordinated in this conversation with built-in subagents. The earlier
headless restriction was explicitly lifted for isolated acceptance; the original
Swift app and user data remain untouched. No ASUS or SSH validation is used.

Latest verification and current gates:

- V5 ordinary-build containment passed at wide, minimum-clamped 820px native
  width and widened sizes: all four image borders remain visible without aspect
  distortion, and Close/help remain reachable. Escape/Close and normal Quit while
  open passed with actual exit zero, exact raw source rows/files/backup and every
  frozen V1–V4 artifact unchanged. Two denied fake Git probes, zero provider/vault
  calls. Header subtitle, left-aligned sidebar and compact Enlarge were observed.
  Focus remains unproven because native readback reports AXWindow. Earlier failed
  containment evidence remains preserved.
- Exact 71ef2c8 passed all six Rust CI jobs and packaging. Exact 0773e1a also
  ultimately passed all six jobs; its completed log confirms Azure archive
  downloads took 14m52s and full provisioning 15m09s. The first main-archive
  experiment completed provisioning in 47s and passed Linux compilation/tests;
  its second completed sample also took 47s. All packages and checks are retained.
- The work-card follow-up passed 385 desktop unit tests and every integration
  target (19, 10, 14, 11), including explicit-status/neutral-unknown/Unicode-title
  cases. Thinking/Thought labels require explicit stored status; raw tool text
  never becomes metadata or authority. The real disclosure action and Find/text
  controllers are preserved, including the reasoning provider label.
- Native ordinary 0773e1a acceptance displayed the approved historical image and
  assistant body/footer, exercised Enlarge/Escape/Close and thread rebinding, and
  quit normally with exact synthetic rows/files and earlier failure artifacts
  preserved. Enlarged containment failed because the image's intrinsic layout
  exceeded its flex viewport; the next candidate places the same verified image
  inside an absolute contained viewport. Focus visibly returned, but no exact AX
  focused-element readback was recorded, so authoritative native focus acceptance
  remains open. All four denied executable attempts were fake Git probes; no
  provider/vault call occurred.
- Separate fresh sidebar grouping exercised real Pin, two unique rows, search,
  snooze and archive confirmation/filter behavior, then quit normally. Its frozen
  zero-executable guard failed on two denied Git probes before the pre-Pin raw
  baseline was recorded. That failure is preserved; only subsequent post-Pin
  exact changes are proved by the separate read-only receipts. No strict overall
  fixture pass is claimed. The separate resize fixture passed both normal exits,
  real 240/400 bounds, narrow/wide preference preservation and restart readback:
  zero threads, only listWidth changed, all other data exact, zero executable
  attempts. Narrow-window content geometry is approximate screenshot evidence.
- The next UI follow-up passed 382 desktop unit tests plus every integration
  target (19, 10, 14, 11). It includes body-first user cards with existing actions,
  the selected project's saved-branch subtitle, corrected real Button label
  alignment and compact image controls. V5 uses an ordinary immutable build.
- Exact 0773e1a passed five Rust CI jobs, packaging and general CI; Linux desktop
  remained in package provisioning for more than twelve minutes. Historical logs
  show the same Azure Ubuntu archive install taking over sixteen minutes versus
  23 seconds on another runner. A focused mirror experiment selects the official
  main archive and separates update/install steps, retaining every package, test,
  signature check and timeout. The current stalled command's exact cause and the
  new mirror's performance remain unconfirmed until Actions logs are available.
- The combined UI source passed 379 desktop unit tests with all notification,
  microphone, Computer Use and helper adapters enabled, plus every desktop
  integration target (19, 10, 14, 11). All 43 vendored List tests passed, including
  seven completed-geometry regressions and actual aborted-prepaint/deferred-effect
  rejection. CI now explicitly runs all seven new tests and rejects a zero-test
  result. Source review also verified the native sidebar drag/release lifecycle;
  native display, drag and relaunch acceptance remain pending. One completed-drag
  preference save retains the existing Store SQLite busy timeout of five seconds;
  drag motion itself stays in memory.
- The latest local core run passed 529 unit tests and every integration target,
  including the finite output-overflow/actual-reaping regression. Strict feature
  Clippy passes after removing an obsolete EOF flag. The Mac CI output-overflow
  failure is addressed by pipe-readiness polling, retaining the existing byte
  caps, absolute deadlines and process-group cleanup. New exact-head CI is pending.
- Native uninstrumented e7d72f8 acceptance passed the saved-selection footer and
  disclosure, but the historical image preview still failed. A separate V3
  diagnostic-only build isolated the cause: the bottom-aligned List returned
  its end anchor (item 1 of 1) instead of the actual visible first row (item 0),
  yielding no image candidates or load attempts. A read-only core diagnostic
  returned the verified image successfully. Correct completed-layout geometry
  and a new uninstrumented native acceptance run remain in progress. All exact
  synthetic thread/documents and source/managed image bytes were preserved;
  both native runs quit normally with zero provider/vault calls.
- Follow-up e7d72f8 passed 370 desktop unit tests with all notification,
  microphone, Computer Use and helper adapters enabled, plus all four integration
  targets (19, 10, 14, 11). The new saved selection footer remains an explicit
  disclosure to the unchanged guarded Apply/Discard flow. The native footer
  passed subsequently; the image-display fix did not, as recorded above.
- Native b493885 rail/header checks passed: persistent rail, list hide/show with
  exact focused-search/query/draft preservation, real palette/Escape, idle Usage
  and Accounts routes, More/Snooze reachability, and an observed 820px minimum
  window width. Normal Quit exited zero with exact isolated one-thread data and
  zero executable attempts. This accepts the scoped controls, not full UI parity.
- The eebee66 image fixture passed native mapping/validation/copy/durable handoff
  but failed to display the transcript preview, so Enlarge/Escape/Close checks
  were not reached. Exact threads and source/managed bytes were preserved and
  normal Quit exited zero; four denied fake-git invocations prevented its strict
  zero-executable assertion passing. An actual read-only core render diagnostic
  returned one verified image, zero failures and an actual worker-return receipt.
  The first candidate UI fix records completed list layouts instead of treating
  splice-invalidated measurements as an empty visible list. Native restart
  validation failed; actual bottom-aligned List geometry must also be corrected
  before the image viewer is accepted.
- Exact 1f03785 Rust CI passed five jobs, but its macOS desktop test exposed an
  existing synthetic regrant fixture assuming an immediately drained request.
  Its test-only correction waits for the actual drain boundary under the same
  original deadline and retains Revoked/zero-backend-call assertions. The exact
  all-adapter local suite above passes. Exact 4f030ee subsequently passed its
  macOS desktop job and the other four non-Mac-core Rust jobs; Mac core failed
  the credentials overflow fixture addressed above. Packaging and general CI
  passed. No rerun is counted as a correction without a source-backed fix.
- UI parity is now the active priority. A private native comparison confirmed
  the missing persistent rail, oversized wrapping header and obscured composer
  controls. The first presentation batch adds a 60px navigation rail using real
  existing actions, an independently collapsible list with focus handoff, a 44px
  icon toolbar with explicit secondary actions, and enlarged verified historical
  images with Escape/Close and freshness revocation. The exact combined source
  b493885 passed 364 desktop unit tests and all four integration targets
  (19, 10, 14, 11). Native acceptance is pending. This is partial UI parity;
  sidebar ordering/resize, all Swift destinations and full composer matching
  remain open. No core authority, arbitrary image path or updater gate changed.
- Work resumed on 2026-11-06 at 04:18 UTC after an inactive gap; the overnight
  work was not continuous. The broad acceptance checklist remains incomplete.
- The new explicit default-runtime Codex limits reader and separate Usage panel
  passed 528 core unit tests, every core integration target, 360 desktop unit
  tests and all four desktop integration targets (19, 10, 14, 11). Strict feature
  core Clippy passes after fixing enum names without suppressions or wire changes.
  The reader retains cancellation and actual worker joins, rejects stale results,
  and does not claim a selected account identity, billing or entitlement. Native
  live limits acceptance passed on ab1b8e4: one visible Refresh showed actual
  timestamped provider windows/plan/reset/credits, missing fields stayed unknown,
  and normal native Quit exited zero with isolated data and Swift preserved.
  Exact 9724e58 then passed all six Rust jobs (42162788718), packaging validation
  (42162788723), and general CI (42162788714).
- e88132a passed all six Rust CI jobs (42128919172), packaging validation
  (42128919100) and general CI (42128919184), verified on the exact pushed SHA.
  Local outcome-diagnostic and cookie-notification changes passed 511 core unit
  tests and every core integration target, strict feature core Clippy, 351 desktop
  unit tests and all four desktop integration targets (19, 10, 14, 11).
- Isolated native credential acceptance on dfdcc88 passed visible Deny without
  individual secret reads, separate Allow once with exact synthetic field/event
  assertions and zero submissions, public Read/Tabs/Console shielding, and pending
  approval revocation after document replacement and thread switching. Normal
  fixture Quit joined its workflow workers and the retained launcher exited zero.
  Only synthetic vault data was used. This does not prove real-vault integration,
  passkeys, full-product shutdown or native WebKit release.
- A separate opt-in per-WebView release receipt prototype compiled and passed its
  eight token tests and nine GPUI release tests. Actual isolated native checks
  passed: the per-view receipt stayed Owned through Rust Drop and became
  SuperDeallocReturned only after an actual held callback block/target released.
  The independent content manager was still held at that point. Normal fixture
  exit returned zero. The prototype is not integrated into the main application;
  strict native release remains Unknown and global updater readiness is unproven.
- Native cookie acceptance on immutable dfdcc88 passed choosing the synthetic
  closed SQLite source, host/count review, explicit four-cookie import, exact
  asynchronous native readback and a new unselected profile with no automatic
  navigation. After explicit profile selection, actual owned HTTP requests and
  page JavaScript proved HttpOnly visibility, path restrictions, expired-cookie
  exclusion and cross-host isolation (127.0.0.1 versus localhost). Normal native
  Quit exited zero; exact thread/context/image bytes, unknown data and source
  bytes were preserved, with zero provider attempts. The owned server exited
  normally and Computer Use was released. WebKit delivered the Secure cookie
  over loopback HTTP; this is an observed platform behavior, not a successful
  HTTPS delivery check. Trusted HTTPS, domain/subdomain scope, restart persistence
  and full browser migration remain unverified. An event-driven notification fix
  now publishes parsed cookie review/cleanup changes without periodic repaint;
  its two regressions pass, but native retesting of that small fix is pending.
- Separate signed/notarized/stapled V6 helper fixtures passed actual native
  eligibility. The positive fixture reached Armed, then native menu Quit flushed
  and closed its actual isolated Store/control workers, observed their joins,
  received clean-consent acknowledgement and exited normally with status zero.
  Installation did not complete: the helper disappeared with an Armed journal
  and consent retained, while the original target fingerprint stayed unchanged.
  A subsequent actual stopped-target probe refused live processes whose native
  executable paths were unavailable; those user processes were preserved. The
  exact historical helper rejection was not recorded. New bounded diagnostic
  outcome/stage receipts address that observability gap without changing guards,
  recovery authority or exchange behavior. Positive installation and rollback
  remain blocked; the product helper stays unavailable by default.
- f8d1103 passed all six Rust CI jobs (42117508742) and packaging validation
  (42117508764), plus general CI (42117508739). The earlier 50f1aa1 Linux desktop job stalled installing system
  packages before compilation and was superseded by this fully passing run.
- The combined native model-control fixture on a30013f passed visible failed
  catalog refresh, stale effort/speed repair, explicit model replacement and
  normal native Quit with exact draft/context/image preservation, two catalog
  calls and zero runtime provider calls. Offscreen action attempts were excluded.
  An external selection-change setup exposed Discard using cached settings;
  07d47c7 now reloads authoritative selection fields without replacing local
  composer content, with all 36 focused selection tests passing. This reload fix
  passed native retesting on e88132a: one actual Discard reloaded a validated
  external model/effort/speed/mode change without Apply or a refresh workaround.
  Normal native Quit exited zero with actual Store/control completion, exact
  content/image preservation, one catalog call and zero runtime calls.
- Native bookmark acceptance passed on isolated f703202: choosing/reviewing
  showed no saved library or HTTP requests, explicit Save produced 23 unique
  bookmarks from 24 rows, Reload/paging worked, and Open displayed the exact
  owned local page in the same thread. Normal Quit and read-only checks preserved
  source bytes, draft/context/image metadata and bytes, unrelated data and empty
  history. The owned server was stopped and its actual exit collected. No native
  restart, cookie import or existing-account/session migration is claimed.
- The closed-file Firefox cookie snapshot parser passed 14 synthetic tests,
  including sidecar/partition/schema refusal, source preservation and explicit
  private-copy cleanup custody. Three callback/lease fixtures passed for its
  checked asynchronous macOS setter. The typed desktop flow is now mounted:
  explicit host review and a new unselected destination, per-cookie asynchronous
  completion/readback, profile revision fences and retained cleanup ownership.
  Closing revokes further dispatch and waits for actual owned work; a minimal
  cleanup-only retry remains reachable. All 13 focused mounted cookie tests pass,
  including late readback after revocation and foreign profile changes. The full
  feature run passed 508 core unit tests (six isolated parent-invoked child
  entrypoints), every core integration target, strict core Clippy, 349 desktop
  unit tests and all four desktop integration targets (19, 10, 14, 11). Native
  cookie acceptance and remote CI for this new batch remain pending; no existing
  Firefox profile or sign-in has been read.
- The model-control follow-up passed 494 core unit tests (six isolated child
  entrypoints invoked by parents), strict core Clippy, 333 desktop unit tests
  and all four integration targets. Explicit Codex speed and Standard controls
  preserve effort/modes; stale effort/speed has separate minimal repair actions.
  Exact explicit Astra models now keep stored null while using Medium only when
  a current private catalog actually advertises it. Reported and app defaults
  are labelled separately. Missing proof blocks execution while explicit catalog
  refresh or validated model replacement remains available. Synthetic protocol
  tests passed; the scoped combined native follow-up is recorded above.
- The isolated native effort v4 flow passed catalog discovery, High, Plan
  preservation, explicit provider-default clear and failed-refresh repair.
  Ordinary Quit exited normally; exact draft, context, image metadata/bytes,
  unknown fields and empty history were preserved, with two catalog calls and
  zero runtime provider calls. This is scoped acceptance on fb6f447, not a claim
  that the later Astra policy or every provider is accepted natively.
- The next local feature batch passed 489 core unit tests (five isolated child
  entrypoints are invoked by parent fixtures), strict feature core Clippy over
  all targets, 12 bookmark core regressions and 11 desktop browser-settings
  regressions. The full feature desktop run passed 323 unit tests and all four
  integration targets (19, 10, 14 and 11 tests). Bookmark opens now prepare an opaque saved-ID proof off UI and
  enqueue only after synchronous Settings-route and selected-thread checks;
  close/reopen between polls invalidates old work. Source files are rechecked
  before explicit Save. Native bookmark acceptance passed as recorded above. Codex speed now
  admits only exact catalog-backed tiers and sends an explicit Standard reset
  after a resumed nondefault tier; the actual fake-protocol regression passed.
  Explicit one-field and combined stale-option repair preserve unrelated data.
  Desktop speed controls are implemented; native effort acceptance passed above.
- a296e7c passed all six Rust CI jobs (run 42112221154), plus packaging
  validation (42112221196). A Windows-only test assumption was corrected to
  expect the platform's Unsupported catalog state; proof revocation and refusal
  to reuse an older catalog remain asserted. Local full feature validation passed
  470 core unit tests and all integration targets, 319 desktop unit tests and
  four integration targets, and strict core Clippy. Strict desktop Clippy still
  fails unused/unmounted APIs; no suppression or success claim was added.
- Native terminal Edit guards passed all four disabled commands with actual PTY
  focus and restored standard responder routing afterward. Native standalone
  /plan, /build and /model controls passed without creating messages, sessions
  or provider attempts, then normal Quit preserved the exact final draft.
  Codex effort proof, explicit clear and revoked-catalog repair have backend
  regression coverage; scoped native effort and bookmark acceptance passed above.
- cbc7eef passed all six Rust CI jobs (run 42105540376): macOS GPUI build,
  Linux/macOS/Windows core, Windows GPUI check and the new Linux GPUI check.
  Linux checks both desktop configurations and all eight headless release-receipt
  fixtures; this does not establish Linux GUI acceptance. The earlier 6dc104e
  checkpoint passed all five then-existing jobs (run 42092151516). The prior 4ae5db4 checkpoint
  also passed all five jobs, including the Linux output-limit fixture
  correction and fixed SQLite. Native Saved Usage/defaults acceptance passed
  real filtering, details, paging, exact project/global choices and invalid-default
  no-orphan behavior; source document hashes stayed unchanged. Native text-only
  steering passed one acknowledged message on the same turn, exact retained
  draft, duplicate-submit prevention and saved last-request usage. Reference
  Quote/cards passed. The 95b0002 native retest passed visible Queue refusal,
  independently scrolling references with pinned editor/actions and context-only
  Send preserving the exact raw reference before successful admission. Earlier
  offscreen action attempts remain excluded; all window sizes are not verified.
- The 95b0002 batch connects ordinary Codex Plan/full-access modes with explicit
  model requirements, immutable bot/import restrictions and source-bound runtime
  policy. Its full core run passed 434 unit tests and all integration targets;
  desktop tests passed 295 unit tests and four integration targets, and strict
  core Clippy passed. Native controls then passed Plan/Full-access selection and
  the exact strict fake-provider request, followed by Build/Approval reset on the
  same provider thread. These mode requests were never sent to a real provider.
- A separate inherited-file-description writer-lock bug was reproduced with a
  deterministic duplicate-descriptor test. Recovery leases now explicitly unlock
  before closing, including constructor error paths; the regression and all
  eight recovery-store tests pass without sleeps or retries.
- Browser callback lifetime accounting now separates invocation ACK from final
  callback/block Drop and counts retained credential targets independently. The
  ordinary Quit policy is unchanged; strict native release remains unconfirmed.
  Nine focused shutdown tests passed, followed by all 299 desktop unit tests and
  all four integration targets (19, 10, 14 and 11 tests). The first full-target
  compile exposed a missing real shutdown-module registration in an integration
  fixture; that registration was fixed without mocks or lint suppression.
- The additive pinned WebView release registry distinguishes actual Rust Wry
  Drop return and retained foreground-task completion from native deallocation.
  Eight headless receipt tests and the complete desktop suite passed. Actual
  native release remains Unknown. The first native fixture incorrectly retained
  arena-backed AnyElement output across frames; its failure is retained as fixture
  evidence, not proof of a production leak. A concrete owned element-payload API
  supports the corrected fixture without arena allocation or manual Render.
  The PRE v2 native test passed physical hiding, close veto, separate Entity,
  payload and handle retention, actual Rust Drop return, callback block/target
  release and normal fixture exit. Native remained Unknown throughout; this is
  scoped ownership acceptance, not strict updater readiness.
- Shared provider pipes now retain and join stdout/stderr/stdin workers after
  child cleanup and channel disconnection. OpenCode similarly retains HTTP,
  startup and SSE workers, including cancellation and TLS teardown. Five shared
  transport fixtures and nine OpenCode ownership fixtures passed; the combined
  core run passed 447 unit tests, all integration targets and strict Clippy;
  three isolated child entrypoints are invoked by their parent fixtures.
- Actual existing-account one-turn Codex, Claude and Grok adapter smoke checks
  returned the exact requested reply without tool approvals. These are scoped
  transport checks, not complete provider or account parity. New isolated Cursor
  default-login reuse passed 16 profile/auth tests. A follow-up preserves only
  validated active-team routing for the same stored-login identity; 22 focused
  tests and the isolated Cursor provider integration passed. Actual Cursor
  inference initially failed after session creation. Boolean-only protocol
  diagnostics traced the failure to opaque variant IDs versus the inherited
  base model ID. The client now negotiates the CLI’s parameterized model picker
  while keeping exact advertised-model checks. The protocol fixture and actual
  existing-account Cursor turn passed (12.94 seconds, exact assistant marker,
  no tools, empty workspace, Rust worker returned). OpenCode also passed the
  current-core one-turn marker check in 4.65 seconds. Antigravity’s existing
  runtime metadata is present, but a valid Rust-owned acknowledgement/account
  binding is unconfirmed; no acknowledgement, login or provider run was invented.
- The combined authentication/provider batch passed 456 core unit tests plus all
  integration targets (three isolated unit entrypoints remain parent-invoked),
  strict core Clippy and 302 desktop unit tests plus five integration targets.
  Native Settings, exactly-one New Conversation, GPUI and WK Select All
  routing, exact draft preservation and normal app-menu Quit subsequently passed
  in an isolated full-app fixture. Cut/Copy/Paste were not executed against the
  user clipboard; Hide/Show and Undo/Redo remain outside this acceptance slice.
  Twenty mechanical desktop lint fixes then passed the full 302-unit desktop
  suite and all five integration targets (19, 10, 14, 11 and 8 tests). A fresh
  strict desktop run still fails remaining diagnostics; no suppression was added.
- Native helper verification exposed a real codesign CLI argument bug: inline
  requirements need the leading '=' selector. All three production sites are
  corrected, and actual signed positive/exact-role/negative-role checks passed.
  Both synthetic helper app bundles were then notarized, stapled and passed the
  actual core verifier, including production-mode archive extraction.
- The V3 native helper reached a verified proposal but failed its Ready deadline
  after approval. Its journal is Cancelled, no consent/install occurred, processes
  exited and bundle hashes stayed unchanged. The failed attempt is retained.
  The 105 MB debug parent took 2.638/2.604 seconds per software SHA-256 pass;
  dependency-only optimization took 0.212/0.175 seconds with identical hashes.
  Four post-approval fingerprints make that a measured timeout diagnosis. A fresh
  optimized V4 fixture retained the same five-second deadline and trust checks.
  Native approval reached Ready in 2.401 seconds; the actual Armed journal was
  independently read before native Cancel. Matching Disarmed arrived in 0.169
  seconds, the journal became Cancelled and the exact helper process was absent.
  Original bundle hashes/modes were unchanged. No Quiescent, CleanQuit, consent,
  installation, rollback or relaunch occurred; those acceptance gates stay open.

- Full-app native Quit passed on immutable 814e3c0 with fresh idle and active
  synthetic-Claude fixtures. Actual production CmdQ interrupted the active fake
  provider, waited for worker/control return and explicit Store close, and
  preserved the exact 65-byte Unicode/newline draft. The draft was saved and
  loaded through the real API/UI; an unsaved-edit race is not claimed. Failed
  fixture setup/input attempts were retained and excluded from these passes.
- New ordinary-thread project/global defaults passed six tests. Codex usage
  capture retains source-bound latest-request snapshots with atomic history and
  transcript persistence; snapshots are not additive turn totals or costs.
  Saved Usage Settings has bounded background reads, filters and paging;
  its scoped native presentation acceptance passed at 4ae5db4.
- Composer quote/reference editing, escaped provider envelopes, exact saved
  context, historical handoff and queue/schedule isolation passed eight scoped
  tests, including an isolated fake-provider boundary. Native Quote/cards passed;
  context-only Send passed the bounded-layout native retest. Codex-only text
  steering passed one actual fake-server acknowledgement on the same source turn,
  saved transcript, exact retained draft and duplicate-submit prevention.
- d4733f4 passed all five Rust CI jobs. On 814e3c0, four jobs passed and Linux
  core failed the existing GitHub output-limit fixture. A finite shell-builtin
  producer and explicit failure diagnostics replace its external infinite
  producer; both subsequent exact checkpoints passed Linux core CI.
- A parallel Mac core run stalled in SQLite's Unix VFS global mutex. The bundled
  SQLite 3.51.1 has a matching upstream deadlock fixed in 3.51.2. The smallest
  supported dependency upgrade is rusqlite 0.39 / SQLite 3.51.3; only those two
  locked packages changed. With that fix, the normal parallel run passed all 429
  unit tests and all core integration targets. The final desktop run passed 289
  unit tests and all four integration targets. CI parallel coverage is retained;
  both subsequent exact checkpoints also passed remote CI.

- The real Mac native Quit fixture passed: three unsaved CmdQ requests were
  vetoed; the synthetic draft was persisted and verified before the one-use quit
  permit; a final CmdQ exited the fixture gracefully. This is guard acceptance,
  separate from the complete application's shutdown acceptance.
- Developer ID signed CLI fixtures exercised actual dynamic running-code trust:
  four cases and 36 checks passed, including wrong roles, ad-hoc code, wrong team,
  and PID/start mismatches. Updater entry, installation and rollback remain open;
  the desktop helper launcher remains unavailable.
- Explicit SQLite close tests passed, including a real busy-close failure that
  retains the same connection. Historical media's write-ahead ownership and
  fault-injection suite passed all 28 tests; unknown outcomes remain retained.
- The combined feature desktop check passed. The desktop suite passed 314 tests,
  including staged shutdown, actual worker joins/TLS teardown, and terminal UI
  transport closure. The full feature core suite also passed (391 unit tests,
  one existing ignored fixture, plus the integration targets).
  The final parent-mount delta passed 280 desktop unit tests, and strict feature
  core Clippy passed after removing a redundant media-ingestion closure.
- The native terminal IME handoff and same-pane accent fixtures passed; browser
  Deny/Allow-once/fill/shielding, profile isolation, Find and quiet terminal resize
  have scoped native evidence. Metadata chooser interaction and broader browser,
  transcript and terminal acceptance remain open.

The latest local batch passed 470 parallel core unit tests, all core integration
targets, strict core Clippy, 319 desktop unit tests and four desktop integration
targets (19, 10, 14 and 11). The eight unchanged WebView release tests now run in
the actual vendored package feature context; their locked invocation passed and
both Mac/Linux CI jobs retain that coverage. No test or lint suppression was added.

Standalone `/plan`, `/build`, `/default` and `/model` are now handled locally
before normal Send/queue admission. Native `/plan`, `/build` and `/model` passed
with exact mode/draft ACKs, no history/session/provider runtime attempt and normal
Quit persistence. Attachments/context keep slash text literal; failures retain the
draft. The terminal readiness notice is cleared only by successful binding.

Native terminal Edit validation exposed AppKit re-enabling a disabled native Copy
selector. Restricted contexts now remove native edit selectors and use an
unregistered disabled action. The actual fake-PTY test passed all four disabled
Edit actions, restoration of native composer Select All, exact draft preservation
and normal Quit with actual child exit. Strong native browser release is still
Unknown and the helper remains unavailable in the ordinary application.

Ordinary default-account Codex effort now requires a private latest-ready catalog
proof bound to the explicit model, advertised choice and executable metadata.
Refresh/revocation, invalid selection and failure cases are tested, including the
actual fake-provider wire boundary. Controls preserve saved effort, offer only
current scoped choices and require explicit Apply; an explicit effort-only clear
can repair stale proof without changing other fields. Native effort/model-control acceptance now passed in the scoped fixtures above.
Codex speed and Swift's Astra default override are implemented and tested;
executable metadata binding is not cryptographic running-code trust.

The parent normal-quit mount freezes new work, retains recovery controls, drains owned workers
off the UI thread, stops the control transport and explicitly closes the Store
before requesting native exit. It does not grant updater consent or establish
crash/force-quit acceptance. Strict desktop Clippy still has existing backlog and
unmounted transport dead-code failures; no strict desktop success is claimed.
The cbc7eef and f521be7 checkpoints below are historical. The latest verified
remote checkpoint is recorded at the top of this document; newer batches remain
pending until their exact pushed SHA has passing results. Native
menu/terminal fixtures and real provider smoke checks are scoped evidence, not
full OS GUI parity, installation/rollback or data cutover acceptance.

## Earlier parallel checkpoint (2026-11-05)

The earlier estimate of approximately 30% was a historical checkpoint, not a
current measured percentage. Windows/Linux feature parity and existing-macOS
UI/UX matching remain open acceptance milestones.

All seven first-round worker slices and their delivered follow-ups are integrated.
The broad feature groups above remain open until their complete behavior passes.

| Owner | Verified evidence | Current work / remaining acceptance |
| --- | --- | --- |
| Terminal | Native Mac scroll/selection/alternate-screen checks; Windows ConPTY/control and GPUI compilation pass | Thread-cached tabs/splits, mode-aware input and native IME callbacks mounted; 18 focused tests pass; native IME/shell/Windows GUI acceptance pending |
| Browser | Private WebKit fill passed 11 native fixture groups; upload/private-channel synthetic coverage passes; Windows no-reparse upload reader passed six owned SDK tests on a fresh runner and is enabled | WebView-level upload fixtures await green desktop jobs; OneDrive/cloud-placeholder and other reparse-point files are refused on Windows; broader browser parity and real-account acceptance remain |
| Organization | Native Codex/Claude picker import, stale SHA refusal and read-only protection passed; bot edit/draft persistence passed | Saved-bot new conversation/focus, empty native state, retained editor draft and frozen instructions passed native fixtures; real provider acceptance pending |
| Credentials | Native synthetic WAV insertion preserved Unicode selection and did not send; microphone converter/lifecycle fixtures pass | Gated microphone controls mounted; six fake workflow tests and feature-on converter/lifecycle fixtures pass; real vault/passkey/model/mic acceptance absent |
| Workspace | Native exact whitespace/Unicode transcript copying and composer/terminal isolation passed; fake-gh metadata and URL copy passed | Durable write service and native confirmation transport mounted; 131 combined desktop tests pass; fake-process service validation and native write confirmation acceptance remain separate |
| Host | Serialized notification runtime fake tests pass; native adapters compile | Settings bridge mounted; default-off foreground native-clear issue corrected with regression fixtures; native delivery/remote/iCloud remain |
| Packaging | 22 archive tests per supported host and real Mac ZIP/DMG payload readback passed | Concrete HTTPS/ZIP staging service passes 17 Mac fixtures and strict core Clippy; signatures, install, rollback and release readiness remain open |
| Coordinator | Pushed checkpoint 6830a05 passed all five Rust CI jobs and archive validation; later desktop batch passes 148 tests, updater 17, terminal rendering/PTY 16 and legacy image module 8; Linux final core snapshot passes 369 outer-harness tests | Full UI/UX parity remains open; command palette/terminal mounts and native action acceptance still need a pushed checkpoint; full UI/UX parity remains open |

The latest five native acceptance groups used isolated fixture data and fake
provider/gh/Whisper processes. Import sources stayed unchanged, imported execution
was refused, bot edits survived restart, and WAV insertion left transcript item
counts unchanged. Copy checks preserved selected spaces and Unicode exactly and
preserved real source newlines without adding block separators. The evidence is
in `NATIVE_ACCEPTANCE.md` and `acceptance-report.json` under the retained local
`coincide-native-ui3-1i2rd94e` fixture directory. The synthetic app was stopped;
existing Swift and ordinary Rust preview instances were preserved. These results
do not establish full transcript virtualization, real inference or live GitHub
write acceptance.

Candidate6 (`ccb2fe0`, binary SHA256
`28df2a05ddc8990647c2e3a72a4be04339569417f26d36b501265f6b401ad94d`)
then passed three additional scoped native groups: creating an empty saved-bot
conversation and focusing its composer without sending; preserving unsaved editor
text and the frozen instructions after later edits; passive notification and
gated microphone Settings presentation. Notification Enable/Allow/Refresh were
not invoked. Microphone controls were visually disabled and nonactionable in the
accessibility readback; the driver's enabled-state predicate was unavailable, so
that predicate is not claimed as passing. The source acceptance gate remains false.
No native capture, TCC request, notification delivery or real provider call ran.
The synthetic app stopped and existing Swift/Rust instances stayed alive.
Evidence: retained local `reports/native-candidate-6-acceptance.md`.

The new GitHub service records durable mutation intent before dispatch and retains
non-consuming results/history across restarts and heads. COMMENT binds a commit
but explicitly discloses GitHub's current-head race; approval/request-changes are
unavailable. Merge uses synchronous REST with an exact SHA condition and fresh
preflight, avoiding CLI queue/auto-merge behavior. Unknown/uncertain results lock
the PR and cannot be retried or cleared by this implementation; history lookup is
not a reconciliation/unlock facility. The private ledger path comes from the
trusted Rust data directory, never request JSON. Initialization requires a distinct
native first-setup action; missing/corrupt prior storage never triggers recreation.
All write validation so far uses fake processes, not real GitHub operations.


Windows Core CI at f9e0ca0 passed the real ConPTY and private-pipe integration
targets, then failed a long-path Git worktree test. The fix distinguishes long
destination support from Git for Windows' unsupported long working directory. At 1e5387e, the full Windows core job passed (219 reported
test successes, zero failures) including the four Git integration cases, plus the
real PTY/control targets. Native Windows GPUI compilation also passed in that run.
The diagnostic job preserves the original full-suite failure while exposing PTY/control targets independently.

The private macOS credential bridge uses named isolated-world WebKit argument
objects, document/origin/deadline binding and a final native permit check. Revocation
prevents dispatch; already-dispatched renderer work cannot be retracted. Eleven
native WebKit fixture groups passed; supported Mac builds now advertise the
native approval workflow. Visual approval and integrated console-suppression
acceptance remain pending. These tests used no real vault,
provider account, model inference or microphone. Native transcript copy acceptance now covers whitespace-only and partial Unicode
selection plus complete-message copy and focus isolation. Cross-message and
offscreen selection acceptance remain open.

Checkpoint 1e5387e passed all five Rust CI jobs: core on Mac/Linux/Windows,
macOS GPUI build and native Windows GPUI check (run 42023874869). Windows
reported 219 test successes with no failures/ignored/filtered, including real
ConPTY, control pipe and the four Git integration tests. This is compile/test
coverage; no Windows desktop GUI launch or distribution acceptance is implied.

The next combined Linux source snapshot (base fd65284 plus bot persistence)
passed 312 reported test successes and strict core clippy. Bot-local name/persona
edits preserve the imported envelope and unknown fields, use a full-document
baseline and compare again in one Store transaction. No linked/global instruction
files are writable through these endpoints. That earlier snapshot did not activate bots. The later integrated Engine validates
locally authorized immutable bot snapshots before every fresh/resumed provider turn;
synthetic process fixtures cover activation, with real-provider acceptance pending.

## Verified so far

2026-11-05 checkpoint: approximately 30% of the macOS replacement is verified.
This remains a planning estimate; the broad acceptance groups above stay unchecked
until their complete behavior is accepted. Mac is the first release target; Linux
currently supplies additional build/test capacity and portability feedback.

The first Mac preview compiled and rendered imported data. Its isolated database
captured 71 threads / 569 source files (220,682,918 bytes); no source files were
written. This is a per-file capture while the legacy app remains active, not a
transactionally consistent snapshot of an entire running application. A final
quiesced capture and verification are required at cutover.

The Linux host compiles the GPUI desktop and runs the portable test suite and strict
clippy checks. The suite covers transactional schema migration, literal Unicode
search, retained unknown fields, real PTY I/O, Codex/Claude/ACP fixture subprocesses,
multi-turn engine integration, process-group cancellation, and timezone/DST/cron
calculations. Real provider accounts have not been exercised yet.

The Mac preview's native WebKit browser passed manual API/CLI checks against a local
fixture: navigation, reading, text entry, clicking, password-input refusal, hidden
page access, and cross-thread tab isolation. Visual inspection caught and corrected
a toolbar overlap; the address field follows navigation. API controls also changed
the selected provider and persisted drafts. Subsequent native accessibility actions
verified Allow once, selecting a question option and Submit answers against a local
provider fixture, with the completed result read back through the API. Request action
footers remain visible while long details scroll. Buttons and inputs appear in the
accessibility tree after initialization; full keyboard/accessibility acceptance is
still outstanding.

The previous portable batch passed 97 tests with strict core clippy, including actual
headless CLI/server restart persistence, real PTYs, schedule execution through fake
providers, draft preservation during scheduled sends, safe image normalization and
provider image delivery. Mac GPUI compilation passes. Native image thumbnails and
Send were checked against a synthetic provider. Native schedule approval and Run now
completed while preserving an unsent text/image draft. Visual acceptance exposed a
clipped schedule action row; the schedule view now uses the full panel, preserving
the hidden composer state. No real provider account has been accepted yet.
Checkpoint `a294263` passed all applicable GitHub checks. The following feature
batch passed 116 portable tests, strict core clippy and Linux desktop compilation;
one additional Grok completion regression passed separately on both hosts (117
unique tests validated). Mac focused image/Grok/download tests and GPUI compilation
passed. Native fixture checks verified a hidden WebKit download with exact bytes
and private permissions, styled terminal cells, and terminal creation/selection/close.
Checkpoint `cdbeb48` passed every applicable GitHub check. The next parallel batch
passes 142 portable tests, strict core clippy and both Mac/Linux desktop builds.
Native WebKit checks verified nested frames, editing/select/click, sensitive-field
refusal, scrolling, cross-origin refusal and stale ancestor handles. Native settings
Light/Paper changes persisted and survived restart. Native queue pause/resume and
settled-turn forks passed. macOS CI exposed reverse-DNS blocking in the synthetic
OpenCode HTTP fixture; checkpoint `49d6ba0` removes that lookup and passes the full
Rust GitHub workflow.

The next navigation/browser batch passes 147 portable tests, strict core clippy and
Mac/Linux desktop builds. Native checks verified isolated console capture/clear,
selector/text/frame waits and tab-close cancellation, selected-element reads and
pagination. Native projectless filtering/collapse, rename, snooze/unsnooze,
archive confirmation/restore and edit-message branching passed. Stable thread/item
accessibility IDs replace recycled transcript action IDs. Checkpoint `85cbae1` passed every applicable GitHub check, including Swift CI.

The following Cursor/terminal batch passes 167 portable tests, strict core clippy
and Mac/Linux desktop builds. Mac-focused Cursor and terminal fixtures pass.
Native Cursor selection persisted; terminal Select All/Copy/paste excluded concealed
text and a new tab cleared the selection. Checkpoint `0cae281` passed every applicable
GitHub check after correcting Windows path-prefix validation. No real Cursor account
or provider network call was used.

The current scheduling/composer/Antigravity batch passes 194 portable core tests,
strict Linux core clippy and a macOS desktop build. Antigravity synthetic tests
cover isolated runtime/profile copies, explicit account configuration, approvals,
questions, account-specific sessions and file callbacks. A review fix preserves
existing file permissions during atomic writes and creates new files privately;
focused Mac/Linux regressions cover it. No real account authentication was tested.
Native acceptance verified creating a selected-days schedule in Asia/Kolkata and
saving it as pending approval without execution. All seven recurrence kinds have
editor regression coverage. Image paste/drop and full-message copy are implemented
but native acceptance remains pending. Antigravity desktop setup/sign-in controls,
API-key accounts and Windows runtime support remain pending. This batch still needs
its own GitHub CI; the overall verified parity estimate remains approximately 30%.

CI now uses sparse Rust checkouts and compiler-aware cache fallbacks across lockfile
changes. Rust-only files are excluded from Swift's change classifier; changes to that
classifier itself still run Swift CI. Existing test/lint/platform coverage is retained.
Baseline Rust runs 41991737611 / 41993318402 took 293 / 73 seconds overall.
For checkpoint a294263, successful GPUI jobs took 29 seconds twice, compared with
62 seconds for the earlier warm GPUI job. One intervening attempt failed downloading
a GitHub action because codeload.github.com DNS failed; its failed job was rerun.
Core timings varied and coverage increased, so these observations do not establish
an overall pipeline speedup percentage. Continue independent work while CI runs.

Implemented foundations are deliberately narrower than full feature groups:

- Shared CLI/API supports project CRUD, settings-document patches, thread actions,
  Codex/Claude/Grok/OpenCode/Cursor selection, pending approvals/questions, and explicit responses.
- Browser has a separate persistent profile and thread-scoped tabs. Cross-origin frame actions,
  uploads, passwords, passkeys, dialogs and native-key actions
  still need implementation. Existing Swift browser profiles are not migrated.
  Native screenshots (viewport, or fullPage up to 20,000 CSS pixels with
  truncated, at most 1600 pixels wide) render the selected tab's own WebView
  on macOS, Windows and Linux; password, credential, one-time-code and card
  fields are hidden and redacted. The panel must be shown; Linux refuses full
  pages beyond its native surface budget. A fresh-runner fixture checks pixels
  on all three; only main-document fields (with open shadow roots) are masked.
  Native downloads have bounded,
  thread-scoped session history and verified destinations in a fresh folder under
  ~/Downloads/Coincide. Every host owns exact native objects (WKDownload, WebView2
  download operations, WebKitGTK downloads) with per-object receipts, including
  document-origin blob downloads; closing a tab cancels its transfers and waits for
  the native outcome. Progress/explicit cancel/resume and persistent history remain. Same-origin
  nested frames have expiring handles; read/click/input/type/scroll reject stale
  ancestors. Native srcdoc navigation works while public navigation stays HTTP(S).
  Console captures bounded primitive-only diagnostics with per-tab clearing. Native
  nonblocking waits support selectors/text/same-origin frames with bounded timeouts;
  closing a tab cancels its waits. Reads report truncation and invalid pages.
- Terminal has real PTYs, native create/select/close tabs and a styled desktop grid. API clients can request
  paged RGB/style/cursor snapshots (at most ten rows); plain polling stays lightweight.
  The desktop assembles coherent revision-matched pages, capped at 40 visible rows.
  Visible-page selection/copy supports drag, Shift-click, keyboard extension and
  Select All; output/tab/page changes invalidate selection. Copy preserves wide and
  combining characters and soft wraps, masks concealed text, and checks revisions.
  Native Select All/Copy/paste and new-tab clearing passed. Scrollback selection,
  drag autoscroll, splits and shell integration remain.
  Candidate child processes cannot inherit the running Swift conversation's bindings.
- Claude and generic ACP protocol adapters have fixture coverage. ACP is not exposed
  as a named provider until its launch/account/mode integration is implemented.
- Scheduling has validated persisted models, recurrence calculations, CRUD APIs,
  durable claims, native approval cards and restart recovery. Approved schedules
  execute while the Rust engine is running, defer busy threads once, and record
  completion/failure/interruption without resubmitting a durable claim. Scheduled
  sends preserve unsent text and image drafts. Imported Swift approvals cannot
  authorize Rust execution; imported thread execution still requires a fork.
  Native creation currently exposes once/interval; richer recurrence editing and
  complete legacy scheduling UI parity remain.
- Grouped project navigation includes an explicit projectless filter, collapse,
  rename, snooze/unsnooze and archive confirmation/restore. Snooze dates are cached
  transactionally in schema 3; filtering avoids decoding entire transcripts.
  Collapse/filter preferences remain session-local; multi-select and undo remain.
  Project selection and existing-folder registration are in the preview. Bounded
  background Git status/diff, file listing and text-file reads are available through
  API/CLI; Git mutations, worktree/checkpoint UI and provider context injection remain.
- Images import asynchronously through API/CLI or a native file picker. PNG/JPEG/
  GIF/WebP originals are copied privately; a static normalized image is capped at
  2000 pixels per edge and 3,750,000 bytes. Draft removal preserves stored files.
  UUID/path/symlink and content checks precede provider delivery and thumbnails.
  Claude/Codex and generic ACP image transport have fixture coverage; HEIC/TIFF,
  PDFs, image editing, clipboard/paste/drop and broader media parity remain.
- Six legacy providers have a filesystem-only discovery catalog. Discovery does not
  verify authentication, versions, models or runtime support; Codex/Claude/Grok/OpenCode/Cursor are
  connected in the preview. Grok authentication, resume, explicit models, images,
  questions/approvals, plan capture and cancellation have synthetic fixture coverage;
  real accounts, usage/effort and background-task UI remain unverified. OpenCode
  owns an authenticated loopback HTTP/SSE server, verifies its PID, strictly resumes
  sessions, streams, asks approvals/questions, sends images and cleans up on Stop.
  Reconnection/backfill, pooling, dynamic models/accounts and plan controls remain. Successful native sessions record transcript progress;
  subsequent provider handoffs include missed messages/images within bounded limits.
- Cursor uses a private per-thread profile and in-memory environment authentication.
  Model settings and checkpointed native sessions are copied without modifying the
  original profile; live WAL/journal sources are refused. Synthetic fixtures cover
  resume, exact model confirmation, approvals/questions, cancellation, provider
  errors and Engine routing. Keychain/file login reuse, Windows private-session
  resume and richer Cursor extension presentation remain unsupported.
- Text follow-ups persist in a bounded queue and execute in order after successful
  turns. Stop/failure/save failure pause the queue; restarts require explicit Resume.
  Uncertain dispatches become interrupted, never automatically replayed. Provider
  selection changes block queued delivery. Native queue controls preserve drafts
  until enqueue succeeds. Queued images, steering and interrupt-and-send remain.
- Forking can select a settled turn; editing a user message creates a separate
  branch with its draft/images restored. IDs are regenerated, runtime references
  cleared, and original history preserved. This does not rewind files or providers.
- Native settings wire system/light/dark appearance, 19 legacy theme choices,
  conversation font/size/alignment/reasoning and Return behavior. Unknown settings
  remain preserved. Full settings, localization and accessibility parity remain.
- Transcripts use a virtualized list with validated image previews, but selectable
  text and full media behavior remain unfinished.

## Data boundaries

- Original file bytes remain in `original_files`; working threads are separate JSON
  documents in SQLite. Unknown fields are retained when supported fields change.
- Imported provider sessions cannot execute in this preview. Forking creates a
  separate native session, so the preview cannot attach to the live Swift session.
- The import captures root JSON, threads, attachments, imported session sources,
  checkpoints and task records. It does not yet migrate browser cookies/keychain,
  runtime processes/sockets, all provider account files or remote device state.
- A snapshot is not proof of restored functionality: UI features need their own
  parity checks even where their original bytes have been preserved.
- The iOS companion remains SwiftUI; this desktop rewrite does not remove it.

## Development

Use a session-specific `CARGO_TARGET_DIR` outside the repository. Mac builds run on
Mac; portable validation and Linux compilation run over SSH on the ASUS Omarchy
host in `~/coincide-work/rust-gpui-checkout`, reusing the build cache in
`~/coincide-work/rust-gpui-rewrite/target`. No user data is copied to Linux.

```sh
cargo build -p coincide-desktop
cargo test -p coincide-core
cargo run -p coincide-core --bin coincide-store -- import SOURCE NEW_DATABASE
cargo run -p coincide-core --bin coincide-rs -- help
```

For a running preview, `coincide-rs browser THREAD_ID '{"action":"read"}'` runs a
bounded browser command and collects its asynchronous result. `provider THREAD_ID
claude`, `pending THREAD_ID`, and `answer THREAD_ID REQUEST_ID ANSWERS_JSON` use
the same dispatcher as the GUI. Imported threads must be forked before execution;
forks explicitly start in approval/build mode while unsupported modes remain gated.

The CLI talks to the running Rust app's owner-only Unix socket. `coincide-rs api`
accepts one JSON request (`id`, `method`, `params`) on stdin. `capabilities` reports
only implemented commands. `serve` starts the same engine without a GUI. Windows
named-pipe transport, legacy CLI compatibility and broader APIs remain pending.

Headless acceptance uses `coincide-rs serve` with a private
`COINCIDE_RUST_DATA_DIR`; no GUI is required for core tests. Native browser requests
fail explicitly in that mode. `attach THREAD ABSOLUTE_IMAGE_PATH`,
`detach THREAD ATTACHMENT_ID`, and `providers` expose the corresponding API flows.
Use `terminal.read` with `styled:true`, `rowOffset`, and `rowLimit` (1–10) for styled
pages; compare revisions when assembling multiple pages from a changing terminal.

Windows Git path limitation: worktree reservations may create destinations longer
than 260 UTF-16 code units from a shorter source checkout, with `core.longpaths`
enabled for Git. Git for Windows still uses a `MAX_PATH` current-directory buffer;
the Rust launcher therefore explicitly rejects project working directories of
260 or more UTF-16 code units after canonicalization. Such a reserved worktree can
be listed from its source checkout, but opening it as a Git workspace requires a
shorter project path. Device namespaces and path components whose meaning changes
when a verbatim prefix is removed remain rejected. The regression verifies real
long-destination metadata, branch/commit identity and unchanged source files/index;
Windows CI must pass before this fix is considered runtime-verified.

## Latest integration follow-up (2026-11-05)

The snapshot-only command palette is mounted with typed, revision-checked actions
for loaded conversations/projects, Settings, schedules and explicit projectless
creation. Ten model tests pass; native focus/keyboard acceptance is pending.
The terminal workspace now uses cached per-thread entities, tabs/splits, actual
pane focus guards and parser-mode-aware input/IME callbacks. Eighteen focused
fixtures pass; the previous root renderer was removed. Full shell and native IME
acceptance remain separate.

Approved-root historical image inspection/validation/materialization passes eight
synthetic fixture groups and strict core Clippy. It does not yet have the native
root-approval workflow, opaque plan registry, transactional local overlay or
renderer integration. Captured-BLOB restoration and Markdown/audio/video discovery
remain deferred; source files and thread JSON are untouched.

Candidate7 exposed an unreachable GitHub detail action below the viewport. No
fake mutation was sent. Detail actions are now pinned above a bounded scrolling
metadata surface; the correction needs a new immutable native candidate and
confirmation-flow acceptance. Read/ledger initialization passed, but those do
not establish COMMENT or merge UI acceptance.

## Continuing partial-feature closure

The coordinator now keeps explicit active ownership in [PARALLEL.md](PARALLEL.md),
including follow-through through integration, tests, native acceptance and CI.
Workers are reassigned after completing their owned flow; status requests do not
pause implementation.

Strict composer selection/capability validation and searchable Settings are
mounted. Fourteen focused core contract/API tests and 154 combined desktop tests
passed; unsupported stored options are displayed and rejected rather than silently
dropped, and immutable bot choices cannot be edited. Runtime-backed catalog work
is separate and uses explicit refresh only.

The historical-media service's eight initial opener/CAS/receipt groups and strict
core Clippy passed. It uses an existing-only DB connection and a Rust-local overlay;
SQLite may still coordinate WAL sidecars/read marks, so no zero-sidecar-write claim
is made. Native restoration UI and durable recovery ownership remain pending.

Candidate9's synthetic GitHub COMMENT flow passed native cancel, exact summary/body
review, one dispatch per explicit confirmation, success/history persistence,
uncertain outcome locking and restart without resubmission. Palette opening,
Settings routing, Escape restoring composer focus and explicit projectless creation
also passed in a task-only app bundle. Native terminal tests verified independent
pane input, application-cursor framing, keyboard copy/bracketed paste, and a real
macOS dead-key preedit with zero premature PTY bytes followed by one UTF-8 commit.
A split resize feedback loop was found and fixed by retaining the last coherent
frame during resize; a new candidate is required to accept that correction.

## Integrated follow-through batch (2026-11-05)

The prior native acceptance remains valid for its recorded candidates. Full
feature parity is still approximately one-third verified; source delivery alone
never checks a broad row. Current paired source integrates transcript Find and
stable row reveal, browser profiles/password revocation and inspection shielding,
explicit bounded model discovery, inline review threads and historical-media UI.
The combined desktop suite passed 196 tests (171 unit, 10 private-browser integration, nine credential integration and six inline-review integration); native acceptance for these newest flows remains open.

Verified focused Mac checks: historical-media service 10/10, shell parser 8/8,
terminal rendering 20/20, terminal selection 8/8, and GitHub threads Engine routing
4/4. Zsh launch fixture passed; Bash synthetic cwd fixture failed and is assigned
to its owner. Model catalog initially passed 7/8, exposing quadratic partial-frame
scanning; the production fix and an additional work-bound regression are integrated
and passed all nine catalog tests on rerun. Strict core Clippy then found two shell-style issues, assigned to the terminal owner. Newer mounts still require their own combined rerun.

CI at 5a8a806 passed desktop compilation and packaging but stopped all core jobs
at formatting. The two initializer layouts are formatted in the next batch. Last
all-five-Rust-jobs-green remains 4c43fe4. New Linux review-thread validation passed
six fake-process groups plus strict core Clippy on the exact recorded parent453
plus feature overlay, not the newest entire parent.

Candidate10 built from 5a8a806 with the terminal resize fix. Native resize retest
remains unverified: the synthetic app window did not become key, so the existing
visibility guard correctly suppressed the workspace. Foreground retries stopped,
synthetic app quit, and original Swift/Rust apps were preserved. Workflow setup,
transport operations and persisted state checks now prioritize CLI/API/headless
fixtures; physical focus/IME/selection/layout still need brief native checks.

Two additional isolated workers own cross-platform/headless integration and
durable media recovery. Recovery work must preserve every copied identity and
uncertain outcome, verify durable ownership before acknowledging receipts, and
never delete media automatically. Work not yet persisted remains unprotected.

## Follow-through validation update (2026-11-05)

Rust CI run 42045348996 passed all five jobs at exact commit
`276ec83522a0b47dc2e2270ab52abf23338993b3`: core Mac/Linux/Windows, macOS GPUI
build with synthetic feature fixtures, and Windows GPUI check. This checkpoint
precedes the new CLI commits. The subsequent CLI batch passed six focused Mac
fixtures and strict core Clippy at `9a570dd`; its cross-platform rerun is pending.
The exact-ID resolver's full-library response dependency is being replaced with
a bounded scalar lookup; existing green checks do not establish that fix.

Desktop tests at `276ec83` passed 233 tests: 208 unit, 10 private-browser,
nine credential and six inline-review integration tests. Actual historical-media
service completions passed four service-to-durable-recovery tests, preserving
the Store's uppercase thread IDs and requiring exact receipt-token matching.
Computer Use collection-time authority fencing passed nine core tests. These
are synthetic checks, with no live provider, vault or permission effects.

Native candidate13 verified folded-tool and hidden-reasoning Find reveal after
the exact-row anchor fix. Advancing to the far-away match crashed in GPUI with
a duplicate accessibility node ID; that remains a concrete open defect. Native
candidate12 verified the compact composer. Remaining Find, terminal resize and
selection acceptance are not inferred from headless tests. The isolated browser
approval harness compiled; its native control sequence is pending.

Computer Use's bounded mount is delivered for parent registration and testing.
The signed updater helper is under implementation; real shutdown-owner hooks
remain open. Current GPUI offers no supported OS/Dock quit veto. In-flight or
unpersisted media work remains exposed to OS quit/crash; palette/window guards
and the termination observer do not close that gap. Full replacement acceptance,
real-account validation, data cutover and Swift removal remain open.

The subsequent parent batch passes 242 desktop tests (217 unit plus the existing
10/9/6 integrations), including the mounted default-off Computer Use bridge.
Synchronous selection changes revoke prior grants, including A→B→A between UI
polls; two focused tests pass. The stopped-handle error-precedence defect found
by CI at `49dcb71` is corrected with deterministic coverage; eight runtime tests
pass. The bounded scalar resolver passes four core and seven CLI fixtures plus
strict Clippy. ASUS Linux tested exact `bd2296c`: 497 outer tests passed, zero
failed, with nine existing child entry markers ignored; ten visible child
scenario executions are not additional unique tests. Strict Clippy also passed.

The explicitly opt-in updater helper passes 22 Mac and 24 Linux fixtures,
feature-on strict Clippy and explicit helper-bin compilation. No native helper
entry, signing, target replacement or app quit ran. Real launcher/owner wiring
is still pending. Review identified a remaining running-process identity check
to add alongside existing static bundle verification before native acceptance.
All helper checks are now included in core CI without enabling the feature by
default or adding it to packaging inventories.

The dynamic running-code trust adapter now compiles and links on Mac; 26 helper
fixtures, feature-on strict Clippy and the explicit bin check pass. These fixtures
inject independent disk/running identities; no real identity API was invoked.
The pinned GPUI accessibility rollback fix passes three focused headless tests,
including nested transaction rollback and retry, and all 242 desktop tests.
Its standalone test prerequisites and licenses are pinned with the patch.

The earlier headless-only restriction was lifted explicitly for the overnight
completion run. Needed native UI testing is now authorized in isolated fixture
apps. No ASUS/SSH; built-in subagents only. Preserve original apps/data and keep
one Computer Use owner. Historical native evidence remains separate from new
acceptance. The Swift app is running; the former ordinary Rust PID was already
absent during a read-only check, and was not stopped or relaunched by this batch.

Pending draft persistence now precedes window removal and API-requested quit.
Any remaining draft blocks those paths, including a previous uncertain save;
only an explicit Retry save action re-enables that write. Two focused headless
workflow fixtures pass, covering exact text preservation, busy versus uncertain
failures, no automatic replay and multiple pending threads. This does not add
an OS/Dock quit veto or establish full updater quiescence.

The next updater transport remains unavailable by default. Its trusted core
reuse is limited to deriving the actual preview launcher context, preparing and
reverifying a private helper copy, validating the spawned helper's running
identity and reusing bounded anonymous-pipe IO. Native preparation and launch
belong only in its worker thread; current validation uses fakes.

Rust CI run 42053620690 passed all five jobs at exact commit
`3196ed28dff3317c38977c50862d0cdd53dbffff`, including Mac/Linux/Windows core,
Windows desktop compilation, three GPUI regressions and 244 desktop tests.
The helper suites passed 26 Mac, 29 Linux and six Windows fixtures at that
checkpoint. The earlier run at `4960947` was superseded before Mac core finished.

The opt-in desktop helper transport now has 16 passing headless fixtures; the
expanded core helper has 29 passing Mac fixtures, including three parent-pipe
tests, and strict feature-on core Clippy passes. The transport validates
ReadyAck/Armed ordering, hides validated late progress during cancellation,
requires a wire disarm acknowledgement after Select, and permanently fences
ambiguous clean consent. Feature/module registration remains default-off and
the mounted launcher remains unavailable. No helper process, dynamic identity
API, native interaction or installation was exercised by these fixtures.
Desktop-wide strict Clippy was attempted and is not passing: existing unused
and style warnings remain, and the intentionally unmounted transport is unused
in the application target. No lint was disabled or runtime mount added to hide
those failures. Core feature strict Clippy is a separate passing check.

Attachment completion publication now retains a result when the bounded
workspace mailbox is full; only the worker waits for delivery. Three headless
Engine fixtures pass for success, error and expired requests. Each fixture
observes an actual full-channel rejection before allowing Engine polling, then
requires delivered completion, released ownership and exactly-once attachment
persistence where applicable. This fixes lost completion under backpressure;
provider-thread and external-owner shutdown accounting remain separate work.

Provider Rust-worker ownership now survives semantic turn completion and Session
drop. The trusted Rust observer distinguishes running, returned, panicked and
unclassified workers without joining; Engine retains cumulative terminal
diagnostics independently of its active runs. Three gated headless Engine tests
pass, including Finished-before-exit, sticky panic and successive turns on one
thread. Returned means only that the Rust thread returned: successful child
cleanup, central admission freeze and whole-app quiescence are not established.

Linux CI at `f81a89c` exposed a shell fixture readiness race: shell metadata
arrived before Readline rendered the prompt, allowing early input to be echoed
twice. The fixture now waits for a fresh end-of-PS1 receipt before each write.
A private FIFO gate deterministically exercises the old readiness window; exact
transcript, profile order, cwd and exit assertions remain unchanged. The focused
Mac Bash 3.2 and zsh tests both pass (the existing child entry marker stays
ignored). Production terminal code is unchanged; Linux verification awaits CI.

The next CI run at `e7b3a66` passed Linux's default core suite, verifying the
shell fixture fix. Its helper-feature suite exposed a separate portability
defect: Linux anonymous pipes retain a link count of one. Validation now checks
actual Linux pipefs identity, preserves FIFO/owner checks, and rejects named
FIFOs even after unlink. All 31 Mac helper fixtures pass; Linux's expanded suite
awaits the next exact-commit CI run.

Overnight owner foundations pass six admission-freeze tests, four control-worker
tests and five provider-worker tests, plus strict feature-on core Clippy. An
initial control regression correctly exposed that `JoinHandle::is_finished`
can precede TLS cleanup on Mac; background join acknowledgements now gate both
control and provider exit status. No join or wait runs in Engine/status/UI-lock
paths. The desktop draft adapter selects the narrow trusted flush under one
try-lock after admissions freeze. All 260 desktop tests pass with notification,
microphone, Computer Use and helper features enabled, using synthetic adapters.
These are prerequisites for actual owner wiring, not full quiescence acceptance.


## Overnight verified checkpoint (2026-11-05, 16:53 UTC)

Rust Actions run 42066509538 passed all five jobs at exact
`eeb88c3a1a5c4f3965b60c508d0639d0775892e9`, including the Linux pipe fix and
Windows explicit test import. Subsequent owner work is a newer checkpoint, not
covered by that green run. Local catalog tests pass 13, GitHub read tests 32,
generic background-worker tests five, terminal join tests two, and GitHub write
tests 12. Feature-on strict core Clippy passes after these owner foundations.
The expanded feature-on core suite passed in log145 after correcting a dictation
fixture that could time out before its synthetic child started; the 200 ms
runtime timeout and descendant/audio cleanup assertions remain unchanged.

Idle-host, catalog, provider, terminal, background and GitHub read/write ownership
now distinguish semantic results from actual joined worker exit. Terminal child
wait failure retains ownership; a descendant holding the PTY remains pending.
Dispatched GitHub writes finish without cancellation or retry. Historical-media
service and recovery IO have explicit drains while retaining receipts until
durable ownership and acknowledgments. Native Computer Use now waits through
backend Drop and TLS cleanup for its shutdown acknowledgment. These owners are
not yet a mounted whole-app shutdown proof; the helper remains unavailable.

Native browser candidate131 passed genuine Deny/Allow once, synthetic filling
with no automatic submit, public read/console/tab inspection shielding and
navigation/thread/cancel revocation. Its Close Tab harness omitted a required
tab ID; production validation correctly rejected it. A fresh harness-only fix
is built for the remaining close/profile checks. Native terminal132 verified
stable split resize and actual input routing, then exposed a dead-key composition
carrying between panes; that concrete native defect is assigned for correction.
Find far-row verification remains active. No release or user-data cutover occurred.

## Whole-app smoke checkpoint (2026-11-07, after #325–#327)

The parity batch (#325) and its build/launch fixes (#326, #327) are on `main`.
The macOS binary (`cargo build -p coincide-desktop --bin coincide-rust` with
`native-microphone,native-notifications,native-computer-use`) now builds and
starts; the window, menu bar and these surfaces rendered and responded:

- Settings: General (appearance, font size, reply font, message side, themes,
  terminal placement), Keyboard (rebindable shortcuts with defaults and
  terminal notes), Browser (search engine, profiles, import, bookmarks),
  Computer Use (permission state and grant controls), Archive, Usage, Models.
- Main window: sidebar (bots, pinned, projects, search, schedules), transcript,
  composer with model/effort/speed/access controls.
- Terminal drawer: live shell, tabs, history/page/live controls.
- Scheduled tasks: grouped by bot, recurrence, approval state and
  "Approve in Rust".
- Browser preview: tabs, address bar, Agent Control, bookmarks and saved login.
- Pull Requests panel: Diff, Local Git, GitHub pull requests and inline review
  tabs, repository entry and first-run action-ledger state.
- Bot conversation: bot title/avatar, model and schedule context.

This is a functional smoke pass, not side-by-side acceptance. No checkbox above
is closed by it; each group still needs its documented acceptance run.

## Acceptance pass 1 (2026-11-07, after #328)

Functional acceptance run against the built macOS app, driven through native
accessibility. Passed:

- **Browser:** opened the preview, navigated to `https://example.com` in the
  native webview; the tab title and address updated and the page rendered.
- **Terminal:** opened the drawer, got a live shell prompt, tabs and
  history/page/live controls; a bot thread without a project correctly asks
  for a working directory before creating a pane.
- **Git / PR panel:** Local Git shows root, HEAD, branch, changed paths,
  working/staged diff, staged checkpoints, worktrees and the commit/push/PR
  action bar. Pull Requests shows Diff, Local Git, GitHub PR and inline review
  tabs with repository entry.
- **Schedules:** grouped by bot with recurrence, "Needs approval" and
  "Approve in Rust".
- **Settings:** General, Keyboard (recording mode entered), Browser, Computer
  Use, Archive, Usage, Models panes render and navigate.
- **Bots:** bot conversation opens with bot title, avatar, model and schedule
  context.
- **Usage:** pane renders under Settings.

Not verifiable in this pass: keyboard rebinding key capture (the accessibility
harness cannot deliver keystrokes to the unfocused Settings window), real
passkey/password-manager sign-in, OS notification delivery, and any workflow
that mutates live schedules or GitHub state. These remain open acceptance items.

## Acceptance pass 2 (2026-11-07, after #329)

- **Keyboard rebinding passed:** with the Settings window focused, New Thread
  recorded `⌃⇧F9`, showed `Default: ⌘N`, reported "Keyboard shortcut saved",
  and Reset to Default restored `⌘N`. This closes the pass-1 gap.
- **Diff passed:** the Diff tab lists Uncommitted Changes, the changed file and
  its hunk (`Subproject commit …`, +1 −0).
- **Defect found:** after opening the Diff tab, the composer area reports
  "Unable to load conversations: App is busy processing another request" and
  keeps reporting it; New Bot does not open while it persists. The engine
  appears to stay locked after the diff/git refresh. This needs a fix before
  the UI/Git group can be accepted.

Still open: real passkey/password-manager sign-in, OS notifications, and any
workflow that mutates live schedules or GitHub state.

## Parity batch: composer and settings (2026-11-07, after #335)

- Composer: mic is an icon between attach and send (#330); the extra `@`
  project-file button is gone (#331); placeholder is Swift's "Ask anything.
  @ files, / commands" (#333).
- Stale "Unable to load conversations: App is busy…" now clears on the next
  successful load (#332).
- General settings gained Number format, Pointing hand over clickable items,
  GPU rendering and Translucent terminal in Swift's order (#334).
- Voice settings use labeled switches for Dictation, Send when I stop and
  Keyboard shortcut, with Swift's captions (#335).
- Models, Browser and Archive panes match Swift's controls and placeholders
  on source comparison (filter, favorites, custom models; search engine,
  profiles, bookmarks, history; archived-thread filter and grouped rows).

Remaining parity work is the sidebar grouping and the inspector panels, then
the ten partial feature areas and the cutover.

## Acceptance status after the native-CI repair (2026-11-08)

Green and verified by the Rust workflow on `main`:

- Core suites on macOS, Ubuntu and Windows (desktop 811/811, all core suites).
- macOS native fixtures: passkeys (Bitwarden sign-in), screenshots, uploads,
  tab shortcuts.
- Linux and Windows: tab-shortcut and passkey fixtures.
- Linux native UI script: composer, settings routes, palette, drafts, restart.

Resolved in section A:

- Browser fixed viewport on Linux/Windows: the browser pane mounted the same
  webview entity twice — once inside the fixed-viewport wrapper and again
  filling the page area — so the second prepaint sized the native view to the
  panel. The page now mounts once; the Linux and Windows fixtures report
  `NativeViewport400x300`.
- Exact-view browser tab keys on Linux: hiding a sibling focused the container
  it was about to unmap, which later stole focus from the view shown in its
  place. Hiding no longer re-focuses that container, and the fixture now
  reports the selected view's X input focus before every chord.

Still open in section A:

- Real passkey/password-manager sign-in outside the synthetic fixture, OS
  notification delivery, and any workflow that mutates live schedules or
  GitHub state.

Section B areas are code-complete and unit-tested (notifications, remote,
dictation, updater: 15 tests pass); what remains there is real-service
acceptance, not implementation.

## Real GitHub read acceptance (2026-11-08)

Against `apoorvdarshan/coincide` with the user's existing `gh` credentials:

- `github.pr.availability` resolved the thread's folder and bound the repository.
- `github.pr.list` returned the open pull requests for the repository.
- `github.pr.read` for PR #340 returned the full detail with the exact expected
  head (`6fd9518b…`), state MERGED and its draft flag.
- `github.repo.merge-methods` returned `merge`, `squash` and `rebase`.

This verifies the GitHub PR workspace's read path, exact-head binding and merge
method discovery. Writes (reviews, merges) were not exercised because they
change live GitHub state.

## Real schedule lifecycle acceptance (2026-11-08)

Against a throwaway data directory through the native control API:

- `schedules.create` stored a daily schedule in `awaitingRustApproval` with the
  thread and project targets bound.
- `schedules.list` returned it; `schedules.pause` and `schedules.resume`
  toggled it; `schedules.delete` removed it and the list was empty.
- Approval stays native-UI only (the Settings › Scheduled "Approve in Rust"
  button), as designed; the control API has no approval method.

This verifies the schedule lifecycle apart from execution and the native
approval click, which the UI acceptance already covered.

## Real bot lifecycle acceptance (2026-11-08)

Against a throwaway data directory through the native control API:

- `bots.list` returned the starter lineup and its baseline.
- `bots.save` created a bot (after retrying past the starter-bot baseline
  change), and `bots.read` returned it.
- `bots.patch` renamed it against the read baseline, and `bots.list` showed the
  renamed bot alongside the starter.

This verifies local bot creation, baseline-checked edits and listing. Starting a
bot conversation still requires a configured provider, which this store does not
have.

## Real CLI-session import acceptance (2026-11-08)

Against a throwaway data directory through the native control API, with a
synthetic Codex rollout file:

- `cli.sessions.preview` reported provider `codex`, one message and
  `continuesSession: true` with a SHA-256 of the source.
- `cli.sessions.import` created a thread from that exact SHA and returned its
  source key under `ImportedSessions/codex/…`.
- Re-running `cli.sessions.import` with the same SHA returned `existing: true`
  and the same thread id, so the import is idempotent.
- The source file was byte-identical afterwards.

This verifies preview, transactional import, idempotent re-import and
non-destructive source handling outside the unit suite.

## Real usage-limit acceptance (2026-11-08)

Through the native control API on this Mac, with the installed provider CLIs:

- `usage.codexLimits.refresh` returned a request id, and
  `usage.codexLimits.status` reached `ready` with a snapshot whose provenance is
  `codex_app_server_account_rate_limits`: plan `pro`, one weekly window
  (10080 minutes), and `hasCredits: false` with balance `0`.
- `usage.claudeLimits.refresh` accepted the read, and the installed Claude Code
  `2.1.311` answered `no_reported_limits`, which is the reader's documented
  result for a CLI without `get_usage`; it is not a malformed-response failure.

This verifies a live provider limits read and the older-CLI fallback. It does
not prove that either provider shows the same values in the Swift app.
