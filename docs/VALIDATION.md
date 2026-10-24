# Validation record

## 2026-10-24 — Local provider integrations and CI restored

The user re-enabled automated validation for this change. Native Settings now
includes separate Skills, Commands, MCP, Plugins, Hooks, Configuration and Agent
sessions pages. Local-owner CLI commands expose the same discovery, library,
configuration and session operations; `/app:*` commands navigate the app without
sending model prompts. Public conversation export supports Markdown and JSON.

The complete Swift test target build passed. All 94 focused Swift tests passed,
including the Claude resume-consumer cases that previously crashed in hosted CI,
typed configuration/draft safety, integration import boundaries, provider
sessions, Codex 0.164 history/mode contracts and export. Python CI configuration/fixture
checks passed all 77 tests. The native desktop runner compiled with
`script/test_macos_ui.sh --build-for-testing`; no desktop UI suite ran locally.
The desktop suite now covers 31 current workflows across four hosted shards.
`UITests/macOS/COVERAGE.md` maps retired UI scenarios to retained behavior suites
and their current replacements; no test skipping or retry-to-green was added.

The packaged native app and strict bundle signature verification passed before
the final review fixes. Live read-only checks on the built-in Retina display
verified the Skills, Configuration and Agent sessions pages, integration metadata
discovery, and four Codex daemon sessions. No model prompt, native session stop,
resume/history mutation, user configuration write, or real integration import
was performed. Nine conversations and the selected conversation were retained.
Exact-commit hosted CI outcomes are recorded separately after completion;
this entry does not claim full CLI/TUI feature parity.

## 2026-10-24 — Sidebar sorting and maximized launch

Projects and chats have independent, persisted choices for Newest, Recently
active, Priority (pinned first), Name, and Custom. Custom order exposes Move up
and Move down in item context menus. Project pins are stored separately from
chat pins. The local CLI supports the same choices and custom moves.

The native build completed in 26.75 seconds and strict bundle signature
verification passed (`/tmp/coincide-sort-cli-build.log`). On the built-in Retina
display, the new sort controls measured 26 by 26 points and the chat menu exposed
all five choices directly. Moving a chat down through its native context menu
changed both its project list and Recents. Its custom position survived switching
to Name and back, and a full app restart. A CLI move restored the original order;
the original sort choices, selected chat, eight-character unsent draft, one
project, and nine conversations were retained. No provider turn was submitted.

Launch fills the display's usable area instead of restoring the earlier
1285 by 774 window. Live launches measured 1470 by 840–842 points as macOS Dock
geometry settled, with the complete window on the built-in display. The menu bar
and Dock remain available; this is a maximized normal window, not a full-screen
Space. Captures use `/tmp/coincide-sort-` and `/tmp/coincide-sorting-` prefixes.

Only one project exists in this workspace, so multi-project ordering and pin
precedence were reviewed and compiled but not exercised against live user data.
Automated tests and hosted CI remain deferred by user direction.

## 2026-10-24 — Correct oversized hover and menu targets

- Fixed the model selector's flexible 270pt frame expanding even short labels.
  It now uses its intrinsic label width, retaining the cap for long model names.
  Native accessibility measurements changed from 282pt to 130.5pt for
  "Codex default". The shared highlighted background fits the label with the
  picker open, with the sidebar hidden and shown, at 1295pt and 900pt widths.
- Audited hover styles in the composer, chat header, sidebar, model picker,
  message actions, command palette and Settings. Kept full-width list rows;
  bounded the workspace label, corrected the attachment menu's 30pt target,
  and moved Add project's 32pt target outside its native menu label. Disabled
  composer menus no longer receive enabled hover styling.
- Checked native control bounds and rendered highlighted states. Background
  computer use cannot generate real pointer hover in this AppKit window, so
  this does not claim a foreground pointer sweep. No provider prompt or
  automated test was run. The user's existing unsent draft was preserved.
- Final incremental build passed in 11.96 seconds; development packaging and
  strict code-signature verification passed. The app stayed on the built-in
  display. CI remains deferred by user direction.

## 2026-10-24 — Native UI polish and composer alignment

- Replaced the separately padded SwiftUI composer placeholder with a small
  AppKit overlay drawn using the existing editor's font, text-container origin
  and line padding. The existing text view, selection, input methods and undo
  handling remain in place. Compared an unsent draft with the placeholder and
  visually checked the empty editor's insertion point; cleared the draft.
- Refined sidebar row spacing, selected states, tooltips and search clearing;
  unified chat control hit areas and hover feedback; adjusted flat light/dark
  surfaces and message bubbles. Model search matches agent names and hides
  unrelated empty sections. Settings rows now adapt to available width without
  replacing the mounted controls.
- Inspected the home screen, populated chat, model picker, sidebar search, and
  all eight embedded Settings pages using native app controls and the local CLI.
  Checked light/dark appearances and window widths of 1438, 1050 and 900 points.
  Restored System appearance, the original empty conversation and cleared search
  fields. All window checks stayed on the built-in Retina display; no provider
  message was submitted and the existing nine chats were preserved.
- Final incremental build passed in 11.74 seconds; development packaging and
  `codesign --verify --deep --strict` passed. Automated tests, provider execution
  checks and CI remain deferred by user direction; this visual pass is not
  exhaustive validation of every conversation or provider state.

## 2026-10-24 — Native chat-first UI and workspace UI removal

- Installed the official ChatGPT desktop app (26.1021.22027, build 21747,
  `com.openai.codex`) as the requested visual reference. Verified the download
  checksum and installed code signature. Inspected Codex/ChatGPT Home, the model
  menu and General settings. Task download/extraction copies were removed;
  `/Applications/ChatGPT.app` remains installed.
- Rebuilt the main window with SwiftUI/AppKit: 48pt rail, 248pt sidebar, uniform
  13pt project/chat rows, 32pt row height, neutral selected/hover states, a
  centered 640pt empty-chat composer and eight compact Settings pages.
  Project and Recent rows now use separate stable identities; the visual check
  caught and corrected blank duplicated rows. Existing chats remain intact.
- Deleted inspector/Git, terminal drawer, clone, project actions/settings,
  scripts, settlement and scheduling UI files. Removed the corresponding menus,
  palette/shortcut routes, remote window scene and source-control/terminal
  Settings pages. Kept storage helpers needed by existing saved data in Stores.
  This removes the app surfaces, not every historical backend/schema type.
- Removed workspace/run-checkpoint banners and changes-sheet actions from the
  ordinary chat UI. Provider approvals, tool output, attachments and queued
  messages remain. Workspace file links now use the existing native external
  editor service instead of opening the removed inspector; that route compiled
  but was not exercised against a user file during this pass.
- Final incremental build passed in 11.92 seconds. Development packaging,
  launch and `codesign --verify --deep --strict` passed. Live CLI reported one
  project, nine conversations, and no running turns. CLI navigation/screenshots
  confirmed populated and empty chat, expanded/collapsed sidebar, General
  settings and the unified model popover. Catalog reads returned seven Codex
  and thirteen Claude choices without errors; no model prompt was sent.
- Automated tests and CI remain deferred by explicit user direction. Historical
  tests for removed UI/types and commands need reconciliation before the full
  suite resumes. This pass does not establish provider execution, OAuth,
  import/handoff regression coverage or pixel-for-pixel reference parity.

## 2026-10-24 — Local Codex/Claude scope and CLI control

- Provider selection, Settings, context-transfer choices, app-tool provider input,
  conversation creation and production session creation now support Codex and
  Claude only. Other-agent launch dispatch and ACP configuration UI were removed.
  Historical schema and protocol implementation files are not fully purged.
- Projects and Recents are separate sidebar sections. Project filtering and
  keyboard traversal use the same visible conversations. The provider/model
  selector is in the composer and the chat header shows its conversation title.
- Added an authenticated local-owner CLI for status, projects, conversations,
  selection, cached/refreshed models, empty conversation creation and native
  window rendering. It is separate from provider-scoped app MCP authorization.
- Final incremental build passed in 10.90 seconds. Signed development packaging
  and launch verification passed. Live CLI status, projects and providers returned
  the running app state; the provider list contained exactly Codex and Claude.
  Cached model inspection returned an empty catalog without claiming model access.
  Native content-view PNG capture succeeded; it does not capture every composited
  system material or the window titlebar. No cua-driver was used for this check.
- Automated tests and CI are intentionally deferred at the user's request for
  this development pass. No provider prompt or authentication probe was sent.
  Removed-provider and previous sidebar tests still need reconciliation with the
  new product scope before resuming the full suite. The existing imported-Codex
  app-tool connection failure and incomplete history import remain unresolved.


## 2026-10-23 — Reviewed context transfers and merge-back

- Native and remote reviews pin latest-stable, recorded-run and exact current
  after-run checkpoint sources. Creation commits the original intent receipt
  without input. Verified Codex/Claude native forks, portable context, saved
  provider-session deltas and actual-parent merge-back share a durable delivery
  audit. Provider handoff keeps the same app conversation.
- Portable selection keeps intact public historical items in chronological
  order, within conservative byte/envelope limits. Literal authored text and
  attachments stay separate. Private reasoning, approvals, native internals and
  attachment bytes are excluded. Scoped context readers expose only immutable
  archives captured by the exact active input; remote context-only MCP cannot
  expose general orchestration writes.
- Remote display leases retain native proof on the host, validate full target
  and immutable cursor/content identity, and bound messages/documents separately
  from accepted work. Unknown delivery blocks replay; exact fresh-context
  recovery preserves its audit and current private draft.

- The final focused run passes all 64 declarations: 54 Core/protocol/provider
  declarations in 23.961 seconds and ten UI/store declarations in 0.441 seconds,
  after a 108.24-second build. Actual native-helper Codex/Claude cases confirm
  zero input at creation, one exact native fork, and one later explicit input
  in the reserved native session, preserving the original source and draft.
  Lost outer replies resolve only the original receipt; oversized archives use
  exact bounded pages and final content hashes.
- Controlled checks cover queued overlapping context with cancellation versus
  positive delivery, late pending merges invalidating a handoff review, preserved
  pending child context during handoff, uncertain delivery across restart, and
  old recovery receipts leaving newer runtimes untouched. Source/checkpoint
  identities, full target bindings, stale cursors and immutable content replies
  are checked separately from transport success.
- Integration exposed an inline native-proof stack expansion in workspace
  validation. Copy-on-write delivery storage preserves independent snapshot
  values and the flat persisted format while bounding its inline footprint.
  Claude inherited heads retain verified transfer lineage alongside existing
  history-operation lineage. Both native fork routes recreate the consuming
  runtime with the exact reserved native ID; scoped readiness requires the
  host-selected tool, with wrong-scope catalogs refusing input.
- All 74 Python cases pass in 2.543 seconds. The ABI guard checks 1080 objects
  (769 Core and 312 app module coverage entries), with zero weak async default
  records. Native GUI runner compilation and private offline launcher checks
  pass without launching a GUI app. The previous pushed head `8c9cc81` also
  completed [its entire hosted run](https://github.com/apoorvdarshan/coincide/actions/runs/39931186524),
  including the main test/package job and all four native GUI shards.

- The complete serial suite exits zero: 2072 of 2085 declarations pass, with
  thirteen optional installed/live checks skipped and pinned Pi package
  acceptance enabled. Core covers 1736 declarations in 509.772 seconds; UI/store
  319 in 78.166 seconds; terminal seventeen in 10.282 seconds; Markdown thirteen
  in 0.139 seconds. Build time is 0.69 seconds. No production source changes
  follow this run.
- Build-only packaging and strict deep signature verification pass. Compiled
  and packaged app UUID `D88C4153-80D4-353F-BB65-88CA632DD61D` and helper UUID
  `3ACBA706-FE95-3B3E-94D2-610D56722F89` match exactly.

Installed provider/account, real SSH and current-batch native GUI runtime
acceptance remain separate from private offline peer and offscreen validation.
No installed app was changed and no native GUI XCTest was executed locally.

## 2026-10-23 — Reviewed remote conversation history

- Native host/client/UI now expose exact recorded-run fork/rewind with separate
  keep/restore-files review. Full native proof and sealed file manifests stay on
  the host; bounded immutable review/operation/recall leases carry paged display
  values and exact content chunks. Accepted intents and native recovery use only
  the original remote command receipt identity.
- Actual-helper offline acceptance passes all seven declarations/sixteen cases:
  Codex/Claude forks and rewinds, keep/restore files, lost outer reply and native
  results, native-head/configuration/root/digest/discard changes, provider-applied
  file-failed recovery, and a workspace larger than the legacy 16 MiB transport.
  Changed native heads can accept the intent receipt, then fail the guarded
  native effect before any provider mutation; tests check the saved failed
  operation and zero mutation requests rather than treating intent acceptance as
  proof that external work succeeded.
- Eight Core declarations/fourteen cases cover exact original-UUID receipts,
  stale authority, bounded UTF-8 prefix/content/cursors, native OpenCode v2
  maintenance claims, late-review close, accepted scratch preservation and
  rootless recovery. A private SQLite writer gate verifies both duplicate
  acceptance references while the real commit is blocked, refuses concurrent
  discard and joins close without deleting accepted uncertain evidence.
- Positive remote Pi worker verification passes both normal response and held
  response/cancel cases in 0.419 seconds after a 14.19-second build. The response
  commits its exact receipt before held native I/O finishes; separate cancellation
  drains that worker without replaying a question, candidate mutation or prompt.
  The private fixture registers Foundation's canonical workspace spelling while
  preserving Pi's realpath cwd; no production path guard was weakened.
- Client and private-draft checks cover exact full-target lease ownership,
  immutable page/content replies and cursor queries, malformed bounded metadata,
  SHA/byte assembly, old-helper refusal, sanitized live failures, benign read
  cancellation and atomic recall merge markers. Draft compare-and-swap preserves
  UTF-8 bytes, including canonically equal but differently encoded Unicode.
- All ten new UI/store declarations pass, including actual Root lost-receipt
  recovery with concurrent local typing and a new imported attachment, restart
  deduplication and intentional later deletion, caller cancellation with owned
  synchronization, fast-fork navigation, exact maintenance claims, rootless/
  bound lease reads and disposal, reconnect rebinding, Pi controls, retained-page
  duplicates and light/dark offscreen layouts. Existing checkpoint/PR reconnect
  regressions also verify new host anchors without losing private drafts.
- The previous pushed head `5c85ef4` completed its hosted full run with exactly
  two issues: an ACP v2 Stop timing failure and checkpoint-close error taxonomy.
  Every native PR declaration passed there, including checkout local/worktree/
  reuse in 29.781 seconds. The close service now reports unavailable after close
  while preserving foreign-target refusal. A deterministic quiet ACP startup
  reproduces the Stop bug without the early native-running event: an owned
  runtime close failed suspended setup before prompt dispatch. The narrow fix
  classifies that pre-dispatch close as cancellation and preserves dispatched
  uncertainty and unexpected transport failures. Both Stop modes and all 26
  focused ACP declarations pass. No deadline, retry or no-prompt assertion was
  relaxed.
- The final complete serial suite exits zero: 2015 of 2028 declarations pass,
  with thirteen optional installed/live checks skipped and pinned Pi package
  acceptance enabled. Core covers 1689 declarations in 489.005 seconds; UI/store
  309 in 76.698 seconds; terminal seventeen in 10.306 seconds; Markdown thirteen
  in 0.136 seconds. Build time is 0.62 seconds. No production source changes
  follow that run.
- Independent checks pass: all 74 Python cases in 2.716 seconds, and the async
  default-context guard over 1052 objects (741 Core, 303 app), with zero weak
  async default records. Build-only packaging and strict deep signature checks
  pass; compiled/packaged app UUID `44ED5EC2-7D5B-325A-B564-85C5856846E3` and
  helper UUID `44386421-AAE3-3C2D-8AC4-BB8B649B16D2` match exactly. Native GUI runner
  build-for-testing and offline Codex/GitHub/Claude launcher envelopes pass without
  opening a GUI app. A new hosted full/UI run is still required.
- Final fixture inventory finds no current owned history/client/draft roots or
  active helper/provider/Git processes. All 64 recorded diagnostic PIDs exited
  with no open files. Three new history, twelve PR and seven checkpoint
  diagnostic folders remain preserved; none was deleted.

This establishes the reviewed remote recorded-run workflow with offline native
peers. It does not establish real SSH, account authentication or installed live
provider acceptance, latest-stable/checkpoint fork sources, portable transfers,
merge-back, persistent hosts or complete T3 parity. No installed app was changed
and no native GUI XCTest was executed locally.

## 2026-10-23 — Bounded remote state and paged native browsing

- The final complete serial suite passes 1975 of 1988 declarations, with
  thirteen optional installed/live checks skipped and pinned Pi package
  acceptance enabled. Core covers 1661 declarations in 456.603 seconds; Store/
  view 297 in 75.817 seconds; terminal seventeen in 10.327 seconds; Markdown
  thirteen in 0.132 seconds. The process exits zero. No production source
  changes follow this full run.
- Final focused verification passes all 36 declarations: thirteen Store/view
  declarations in 3.084 seconds and 23 Core/client/native/previous-PR declarations
  in 49.419 seconds, after a 20.40-second build. This adds 29 projection
  declarations (63 expanded cases) and rechecks all seven existing native PR
  declarations. All providers, homes, Git repositories and transports are private
  offline fixtures; no installed-provider turn, account login or SSH runs.
- Two actual-helper projection declarations verify a structurally valid SQLite
  workspace larger than the legacy 16 MiB frame cap, all 607 message identities
  and exact content, a single giant escaped Unicode/NUL body, attachment/draft
  documents, complete SHA/byte offsets, current sequence hints while old pages
  remain pinned, and reconnect with sole original-command receipt ownership.
  A fully validated unconfirmed native history operation retains its complete
  private proof and host action holds while projected responses omit that proof.
  LRU/release/stale-host behavior and zero provider launches/PID cleanup pass.
- Nine client declarations cover 43 expanded cases: wrong environment/host/view,
  scope/sequence/fingerprint, bounded and complete metadata, duplicate/empty/
  overlapping/gapped pages, changed totals, looping/foreign cursors, immutable
  duplicate page/content replies, exact content bytes and final SHA, inherited
  run provenance, old-helper zero-RPC refusal, racing sequence hints, sanitized
  typed failures, busy read capacity without retiring the owned helper, and
  disconnect without automatic command/input replay.
- Five Core declarations verify encoded page bounds, idempotent cursors/content,
  exact rows and giant text, raw-host query/reference/offset/release refusal,
  immutable old views after updates, view eviction and restart identity, imported
  clone summaries, and historical-workspace diff denial. A run with 200 prior
  failed observations keeps baseline/current post-run in its bounded preview;
  the referenced document preserves every previous attempt in order.
- Thirteen native Store/view declarations verify projected transport without a
  fabricated native snapshot, pinned old browsing/current controls, local drafts
  across uncertain submit, 30 streaming hints with exact Stop/approval ownership,
  catalog-only sequence floors, deleted selections with usable global actions,
  stale diff publication, oversized host-draft copy/replacement with no pending
  submit, and a 1.44 MiB Unicode content stream with an exact final hash and
  UTF-8-safe rolling window. Controlled T-before-S and stale-continuation gates
  verify catalog publication ownership and exact unused lease disposal. Light/
  dark 480x560 and 640x680 offscreen layouts create no window or implicit actions.
- The previous checkpoint head's hosted run `39916636967` completed all 1959
  declarations in 1195.199 seconds with exactly three PR checkout deadline
  failures. Its new diagnostics prove each was still dispatching/running at the
  unchanged twelve-second bound, with one live helper, one effect attempt, no
  effect/operation error, and hundreds of metadata Git invocations. The private
  wrapper launched Python for every metadata command. A fixture-only shell
  router now directly executes the same native Git/argv for allowlisted metadata
  with transport disabled; controlled fetch, held mutations and forbidden
  push/clone/ls-remote still use the original Python rules. Exact production
  prefixes include --no-lazy-fetch and --no-replace-objects. Missing/malformed
  fixture-state, spaces/apostrophes, protocol, mapping, hold and refusal smokes
  pass; all children join. Two local actual-prefix 30-call samples improve from
  .7576/.7584 to .2933/.2995 seconds. The three native checkout cases improve
  from 43.422 to 16.482 seconds. No product timeout, test deadline, retry or
  assertion was relaxed. A new hosted result is still required.
- Build-only packaging and strict deep signature verification pass. Compiled and
  packaged app UUID `52C1C5E7-86AF-3ED6-93ED-25AECDAE7A5A` match; helper UUID is
  `89282BF4-97EC-378D-98C8-571FBDC4856E`. The ABI guard checks 1027 objects,
  including 725 Core and 297 app objects, and finds zero weak async default
  contexts. All 74 Python checks pass in 2.762 seconds. Native GUI runner
  compilation and offline launch envelopes pass without opening a GUI app or
  changing the installed app.

This establishes bounded remote display transport and paged native browsing,
with explicit documented cache/document/window limits. It does not establish
remote provider-history mutations/recovery, durable journal catch-up, real
SSH/provider acceptance, persistent hosts, or complete T3 parity.

## 2026-10-23 — Remote run checkpoint controls

- The complete serial run executes 1959 declarations: 1945 pass, thirteen
  optional installed/live checks skip, and one existing Pi permission-fixture
  declaration fails (two issues from its mode case). Core completes 1645
  declarations in 498.406 seconds; Store/view 284 in 72.435 seconds; terminal
  seventeen in 10.349 seconds; Markdown thirteen in 0.134 seconds. The full
  process exits one; it is not recorded as a clean full-suite pass.
- A controlled Node probe proves the permission-fixture cause: the private
  runner's inherited umask `077` turns its requested `0644` test file into `0600`,
  which the product correctly accepts as private. The fixture now chmods its
  exclusively created sidecar to the exact requested mode and asserts `0644`
  before retaining the original refusal checks. Product permission rules and
  timers are unchanged. No production source changes follow the full run.
- After the fixture correction and bounded PR diagnostics, all eighteen
  affected Pi input-bridge/native PR declarations pass under umask `077` in
  100.786 seconds (eleven Pi declarations and seven native PR declarations).
  This rechecks every caller of the changed permission fixture and all native
  PR fixture paths. The three checkout modes pass in 43.422 seconds. This is
  focused follow-up evidence, not a rewritten outcome for the failed full run.
- The focused serial run passes all 26 new declarations (54 expanded cases):
  sixteen Core/client/native declarations and ten Store/view/parent declarations.
  No installed provider, model turn, SSH connection, external Git transport,
  account mutation or sign-in is used.
- Actual native-helper fixtures prove durable baseline capture before the private
  provider starts, post-run capture, preserved real staging/HEAD and source files,
  exact-observation bounded diffs and reconnect inventory. Reviewed restoration
  uses an isolated checkout imported through the actual remote worktree flow;
  a dropped accepted reply is recovered by its sole original UUID/SQLite receipt
  without repeating restoration or provider input. Failed post-run capture holds
  FIFO input until the exact explicit retry/continue action. Stale attempts,
  discarded reviews, configuration changes and physical root replacement fail.
- Five Core declarations cover nine cases: original receipt ownership and native
  inspect-only restoration recovery, stale configuration/policy/digest/discard
  admission, missing-folder metadata acknowledgment, unused review disposal and
  close joining a late native review. An acceptance fence spans durable commit
  so a disappearing review cannot dispose its sealed manifest during admission.
- Six client declarations cover 28 cases: exact scope/path bytes, malformed
  inventories and diffs, validly redigested but foreign native review ownership,
  unsafe manifest paths, discard binding, old-helper zero-RPC refusal, sanitized
  errors and unknown-result receipt recovery without replay. A separate codec
  regression preserves the exact legacy create-command payload bytes when the
  newly optional checkpoint policy is omitted.
- Nine Store/view declarations verify metadata-only selection, historical paths,
  exact receipt/attempt diffs, explicit review/apply, protected uncertain outcomes,
  cold rootless acknowledgment, owned selection/disconnect/late-review cleanup,
  cancelled pane publication and ID-scoped cleanup that preserves newer reviews.
  Pure history/restore/recovery content fits light/dark 480x560 and 640x680 bounds
  offscreen with no NSWindow, RPC or apply. Actual sheet lifecycle loading stays
  separate. Two parent cases recheck new retained edits after real draft fsync
  before retry/continue can reach the wire and preserve the newer local draft.
- The initial native fixtures exposed two fixture errors: Python and Swift used
  different lexical aliases for the same private path, and a linked worktree was
  registered as the project root, where native restoration correctly refuses.
  Corrected private ownership lookup and the real worktree-import flow pass
  without relaxing product path checks or restoration isolation. Seven failed
  fixture roots remain preserved; all sixteen recorded processes exited and no
  open files remain. The twelve earlier PR diagnostic roots are unchanged.
- Native app/helper packaging and strict deep signature verification pass. The
  packaged/compiled app UUID is `42FE9D8A-5263-3218-A191-CBDC833F096F`; helper UUID
  `D3F51321-7BD8-36F8-8111-C5C3F79B1572` matches too. The native math resource bundle
  is present. The ABI guard inspects 1015 objects (713 Core, 292 app) and finds
  zero weak async default contexts. All 74 Python checks pass in 2.623 seconds.
  Native GUI runner compilation and offline CLI launch envelopes pass without
  launching a GUI app. The installed app is untouched.

The prior PR commit's hosted run `39912537789` completes all 1933 declarations in
1206.192 seconds with three checkout-case deadline failures (local/worktree/reuse);
packaging and native GUI shards therefore skip. The same three cases pass in
this local full run in 42.202 seconds. That does not establish the hosted cause.
The fixture keeps its exact 12-second bound, fails promptly on a known terminal
outcome, and now emits bounded phase/effect/PID/allowlisted-command diagnostics
without configurations, paths, raw frames or stderr. A new hosted run is needed
to distinguish a running operation from a refused/uncertain checkout. No retry,
longer deadline, coverage reduction or claimed CI fix is introduced.

These checks establish the existing native run-checkpoint workflow over the
owned remote protocol. Remote provider history, bounded/paged remote projections,
portable history/merge-back, broad provider setup and real two-Mac/provider
acceptance remain unfinished; full T3 parity is not claimed.

## 2026-10-23 — Remote GitHub pull request workflows

- The final complete serial suite passes 1920 of 1933 declarations, with thirteen
  optional installed/live checks skipped and pinned Pi package acceptance enabled.
  Core covers 1629 declarations in 475.555 seconds; native view/store 274 in
  72.565 seconds; terminal seventeen in 10.371 seconds; Markdown thirteen in
  0.127 seconds. The final process exits zero. No production source changes
  follow this full run.
- Seven native-helper declarations with thirteen cases verify bound context,
  list/detail/resolve and discard; one external create under the original SQLite
  command receipt/outbox despite a lost reply; uncertain external creation
  inspection and explicit acknowledgment; local/worktree/off-head reuse into
  exactly one blank conversation; stale digest/config/root/owner refusal; held
  file-job exclusion; and cancel/inspect/ack without fetch replay. All gh, Git
  transports and homes are private fixtures; no real account, installed provider,
  external GitHub mutation or SSH connection runs.
- Eight malformed-client declarations with 27 cases verify exact target/root/path
  bytes, repository/type/URL/ref validation, authored Unicode title/body bytes,
  host review identity/digest, captured reasoning/model and target configuration,
  disabled setup execution, discard binding, old-helper zero-RPC refusal and
  sanitized authentication failures. Two capacity cases prove a typed busy
  command/receipt rejection preserves the owned helper, snapshot and pending
  UUID without permitting automatic replay.
- Six Core declarations with ten cases verify sole original-command receipt
  ownership, exact host-cache admission, stale/discard/foreign review refusal,
  foreign repository read refusal, cancellation drain, missing-folder metadata
  acknowledgment and cancellation, and fake-driver PTY exclusion through the
  awaited close. Inspections and cancellation waits stay outside both command
  lanes; PR receipt waits use bounded owned response tasks too.
- Ten Store/view declarations cover retained private PR drafts and per-scope
  persistence failures, byte-exact compare-and-swap, no reads on selection,
  bound-root preservation, stale configuration/draft refusal, consumed successful
  reviews, cold recovery, rejected late edits, and read-only reused worktrees.
  Offscreen AppKit rendering fits light/dark 480x560 and 640x680 presentations
  without creating a window or invoking native actions. Two parent Store cases
  preserve a newer PR draft across a dropped begin/restart and recheck dirty
  editors after a held real draft fsync before any wire command.
- A first full run exposed an exit-log race in the existing private Codex peer:
  EOF set its recorded flag before writing, and SIGTERM could abort that write.
  A controlled extracted-function signal probe reproduced a zero-row clean exit.
  The fixture now masks SIGTERM across check/write/flag publication. Two Python
  regressions cover EOF/TERM orderings with exact child joins; all 74 supporting
  Python checks pass in 2.643 seconds. Product shutdown and existing assertions
  and deadlines were preserved.
- Build-only packaging, deep strict signatures and native math-resource rendering
  pass. App/helper Mach-O UUIDs match compiled products. Signed discovery exposes
  all five remote capabilities without opening SQLite or GitHub configuration,
  exits on EOF and rejects relative GitHub launch paths before creating data.
  The installed app is not replaced or launched. The ABI guard covers 1017
  objects (706 Core, 288 app), with zero weak async default contexts. Native GUI
  runner compilation and offline launch-envelope checks pass without local GUI
  execution.
- The preceding attachment commit b6c972f is fully green in hosted run
  39907450582: Core/package, all four native GUI shards, all 27 workflows and the
  aggregate gate pass. This includes the previously stalled Claude context
  workflow; one successful run does not establish its earlier sporadic cause.
  These hosted results predate the PR changes and do not replace their CI gate.
- Final read-only inventory finds no live exact fixture PIDs or open files.
  Twelve historical diagnostic directories from the first failed Core/UI/native
  runs remain preserved, including the two synthetic Git repositories. Passing
  final-run fixtures drain and remove their own files.

Remote history/checkpoint controls, setup/removal, real two-Mac acceptance and
broader PR review/comment/merge/stack capabilities remain open. This batch does
not establish full T3 feature parity or release signing/notarization.

## 2026-10-23 — Remote attachment transfer and retained drafts

- The final complete serial suite passes 1887 of 1900 declarations, with thirteen
  optional installed/live checks skipped and pinned Pi package acceptance enabled.
  Core covers 1608 declarations in 378.595 seconds; native view/store 262 in
  72.457 seconds; terminal seventeen in 10.319 seconds; Markdown thirteen in
  0.134 seconds. No production source changes follow this full run.
- Five actual native-helper/SQLite integration cases and six client declarations
  with 29 expanded cases verify bounded chunks, exact duplicate/collision
  handling, restart, lost finalization/submit replies, original receipt recovery,
  wrong-scope refusal, claimed cancellation, verified download and attachment-only
  queue readiness behind a real held worktree. Private provider executables and
  Git repositories require no installed provider, authentication or network.
- Four Core cases cover native immutable imports/range reads, image conversion,
  exact host draft and uploaded-reference admission, one command transaction and
  one ledger finalization, same-ID receipt reuse, new-ID claimed-reference
  rejection, stale/cancelled/foreign refusal and rollback. Storage migrates to
  version 42; all previous migration cases remain and future 43 is refused.
- Ten native Store/persistence cases cover picker-independent file/image paste,
  private copies across selection/restart, explicit unknown-upload status checks,
  cancellation against delayed finalization, captured submissions and later
  imports, exact manifest compare-and-swap, corrupt/escaping names, scoped fresh
  download IDs, changed-byte rejection and same-client refresh. Observation
  tracking verifies upload/import flags update at both asynchronous boundaries.
  Two parent Store cases verify attachment-only lost-submit recovery preserves
  newer imports and stale host references cannot reach the wire.
- Build-only packaging, deep strict signatures and native math-resource rendering
  pass. App/helper Mach-O UUIDs match their compiled products. Signed helper
  discovery advertises Files/Git, terminal, worktree and attachment capabilities,
  creates no SQLite workspace and exits on EOF. The installed app is not replaced
  or launched. The ABI guard checks 1001 objects (690 Core, 277 app) with zero weak
  async default contexts. All 72 supporting Python checks pass in 2.535 seconds.
- The native GUI runner compiles and its offline launch-envelope checks pass
  without GUI execution. Final cleanup finds zero owned attachment fixture roots
  or processes. Staged changes pass a redacted secret scan.
- Hosted acceptance remains separate. The preceding terminal head's run
  39902574409 reached its 35-minute job cap; its buffered final log line does not
  establish the stalled operation. All six isolated OAuth rotation-failure cases
  pass locally in 0.005 seconds, so no speculative OAuth or timeout change was
  made. The previous worktree head's run 39904821308 completed its 1873-test
  suite with one Pi history late-reservation case failing its private eventual
  boundary, so packaging and GUI execution were skipped. The current full local
  suite passes that unchanged case; its hosted failure remains unresolved. The
  earlier observed SwiftUI layout/teardown stall is also unresolved.

Real two-Mac transfer/authentication, hosted attachment interaction, automatic
reference-aware cleanup, remote PR/history controls and the remaining environment
capabilities remain open. These checks do not establish full T3 feature parity.

## 2026-10-23 — Remote worktree preparation and recovery

- The final complete serial suite passes 1860 of 1873 declarations, with thirteen
  optional installed/live checks skipped and pinned Pi package acceptance enabled.
  Core covers 1593 declarations in 407.787 seconds; native view/store 250 in
  71.724 seconds; terminal seventeen in 10.238 seconds; Markdown thirteen in
  0.142 seconds. This includes the final seventeen malformed-client cases and
  the two parent Store race regressions. No production source changes follow.
- Build-only app packaging, deep strict signature verification and native math
  resource rendering pass. Packaged app/helper Mach-O UUIDs match the compiled
  products. Signed helper discovery advertises worktrees, Files/Git and terminals,
  creates no SQLite workspace and exits on EOF. The installed app is not replaced
  or launched. The ABI guard checks 986 objects (675 Core, 268 app) with zero weak
  async default contexts. All 72 supporting Python checks pass.
- The native GUI runner compiles successfully without launching the app. Its
  offline CLI envelope/selected-chain/argument checks also pass. Actual hosted
  worktree interaction is still a separate acceptance gap.
- Actual native helper, codec and private SQLite/Git fixtures verify new/existing
  branch worktrees, registered reuse with dirty source preservation, queued
  readiness, cancel/inspect/retry and explicit reuse after a failed destination,
  exact receipt recovery after a dropped reply without replay, replaced source
  rejection, and mutation admission at source and reused destinations. All Git
  origins and deliberately held hooks remain inside private fixtures. No terminal
  login shell, installed provider, network or real SSH connection is used.
- Core checks verify original-command/native-attempt ownership, stale configuration
  and attempt refusal, inspect-only recovery without queue execution, capability
  fallback, physical source identity from admission through planning and retry,
  and live-terminal exclusion until the owned driver drains. Native requests
  without the new optional source identity still decode for existing journals.
- Native Store checks cover captured catalog/configuration/attempts, missing
  destination recovery, exact Unicode path identities, explicit submodule policy,
  reconnect fencing and exact dispatch. Two parent Store regressions verify no
  wire command for a stale configuration or edits introduced while the real
  private draft-store lock holds persistence; all draft bytes remain intact.
- The malformed catalog peer dynamically chooses the opposite Unicode
  normalization of the encoded target, so its UTF-8 refusal assertion cannot
  accidentally test an unchanged Foundation-normalized path. It also verifies
  identity/ref/path/commit validation and old-helper capability refusal before
  any write command is transmitted.
- Hosted UI remains a separate gate. The older Files/Git run 39900202085
  reproduces the already-fixed remote-form accessibility assertion. Its Claude
  context-inspection workflow completes the functional checks but then stalls
  during diagnostic teardown. The attached spindump shows sustained SwiftUI
  transaction/lazy-stack layout activity on the app main thread; the initiating
  mutation is not established. No timeout or assertion was weakened for this
  unresolved issue, and this batch does not claim to fix it. The same older run
  also exposes one stale exact quit-warning string; that assertion now matches
  the existing product text about commit drafts and saved remote records. Its
  title, message, button and workflow checks remain intact.

Remote setup-script execution, removal, real two-Mac/provider authentication and
hosted worktree interaction remain unverified or unimplemented. These local
checks do not establish complete T3 Code parity.

## 2026-10-23 — Remote PTYs and terminal panel

- The complete serial suite passes 1838 of 1851 declarations, with thirteen
  optional installed/live checks skipped and pinned Pi package acceptance enabled.
  Core covers 1579 declarations in 371.967 seconds; native view/store 242 in
  74.037 seconds; terminal seventeen in 10.278 seconds; Markdown thirteen in
  0.144 seconds. No source changes follow this full run.
- Build-only packaging, deep strict signatures and native math resources pass.
  Packaged app and environment-helper Mach-O UUIDs match their compiled products.
  Signed helper discovery advertises Files/Git and terminal support, opens no
  SQLite database, exits on EOF and leaves no fixture. The ABI guard inspects
  975 Mach-O objects (664 Core, 262 app) with zero weak async default contexts.
  The installed app is neither replaced nor launched; the development bundle is
  `dist/Coincide.app`.
- Final focused verification passes all 23 declarations: nine Core (including
  fourteen expanded malformed-peer cases), six actual native PTY/service checks,
  and eight offscreen native renderer/store checks. Core takes 2.165 seconds,
  terminal 8.779 seconds and view/store 0.273 seconds after a 10.66-second build.
- The host injects a headless SwiftTerm `LocalProcess` driver. Private non-login
  Python programs verify exact binary/Unicode output and input, workspace and
  environment, geometry changes, final exit bytes, foreground escalation and
  exact owned-process drain. The production service plus private SQLite verifies
  duplicate input executes once, live-terminal file mutation exclusion, lease
  release after close, and cold identity lookup without relaunch.
- A bounded inherited-writer fixture verifies finite drain, explicit incomplete
  output while a residual session member remains, and eventual fixture PID exit.
  Darwin can revoke the slave and return EIO immediately; this is not evidence of
  an observed drain timeout. Session-member enumeration is observation only.
  No arbitrary reparented descendant cleanup is claimed.
- Core checks cover the 512 KiB output ring and visible gaps, exact incarnations,
  seventy ordered writes with bounded rolling receipt metadata, refusal to replay
  expired/uncertain inputs, no raw-keystroke persistence, and overflow during an
  existing close. The ring test caught and fixed nonzero `Data.startIndex` after
  prefix removal. A malformed stdio peer checks wrong incarnations and gaps,
  lost/malformed input acknowledgments, read-only receipt recovery across
  reconnect, and uncertain opens that are never retried.
- Offscreen checks cover explicit opens, retained tabs, ordered binary input,
  close without deadlocking on blocked input, confirmation and queued-input
  refusal, stale connection replies, multi-page inert gap replay and old-view
  callbacks arriving after a renderer replacement. Replay uses sanitized text;
  clipboard automation, links and bells are disabled. A display-only renderer
  never starts a local process. Actual remote panel interaction remains hosted
  GUI acceptance work.
- The actual native helper advertises terminal capability and responds to
  unknown-reference/read-only requests without opening a shell; unsupported
  methods are refused. The native GUI runner compiles without launching an app,
  and all 72 supporting Python checks pass. Prior hosted run 39897554190 passed
  Core/package and 26 of 27 GUI workflows; its only failure read a validation
  StaticText label while the captured accessibility tree exposed its text as
  value. The test now accepts that native value with label fallback, preserving
  both validation assertions and the workflow count. Its hosted rerun is pending.

This is local protocol, driver and service acceptance. No real SSH connection,
provider authentication, login-shell startup, persistent host, cross-platform
host or complete T3 Code parity is established by these checks.

## 2026-10-23 — Remote Files and Git inspector

- The full serial run passes 1815 of 1828 declarations, with thirteen optional
  installed/live checks skipped. Pinned Pi package acceptance is enabled. Core
  covers 1570 declarations in 368.438 seconds; native view/store covers 234 in
  72.807 seconds, terminal eleven in 1.417 seconds and Markdown thirteen in
  0.140 seconds. No source changes follow this full run.
- Build-only packaging, deep strict bundle/helper signatures and native math
  resource rendering pass. Packaged app/helper Mach-O UUIDs match the compiled
  products. The signed packaged environment helper advertises the Files/Git
  capability and exits gracefully on EOF without opening SQLite or a provider;
  its private fixture is removed after exit. The installed app is neither
  replaced nor launched. The development bundle is `dist/Coincide.app`.
- Final focused integration passes all 35 declarations: 27 Core in 3.580 seconds
  and eight native view/store declarations in 0.012 seconds. The incremental
  build takes 19.50 seconds. These checks include the production native helper,
  JSON-RPC client/codec, private SQLite, real files and local Git repositories.
- Native acceptance verifies directory/path/content search, file creation,
  revision-checked saves, conflicts, symlink/path/Git-metadata refusal and physical
  root replacement. Git checks stage, diff, commit, exact content/head readback,
  durable result lookup and refusal to replay completed operations. A held Git
  hook proves provider admission stays refused while the mutation owns the
  workspace, and Cancel/Close join the exact owned Git process. Fixture-owned
  hooks are separately released/joined; arbitrary descendants are not claimed
  drained. No network fetch/pull/push, model call or real SSH host is exercised.
- Client regressions use a private stdio peer through the production codec.
  Malformed result types, wrong document paths/bytes, missing revisions and
  malformed read replies retire the transport while retaining exact private
  pending requests. Nil receipt lookup across reconnect never permits replay.
  Private intent checks preserve corrupt/unsafe records and distinguish exact
  Unicode bytes instead of Swift's canonically equivalent String equality.
- Native view/store checks retain dirty buffers across files, conversations,
  model changes, inspector hiding and disconnects; preserve newer text across
  saves, reloads and commit receipts; and expose older retained workspaces without
  granting them file/Git access. Saving reacquires an opaque revision only when
  the remote base is unchanged. Old-worktree receipt recovery cannot update the
  current worktree's editor or commit draft. These are offscreen checks, not
  rendered remote-inspector acceptance.
- Independent review finds response-shape validation outside the client's
  transport-retirement path; it now retires malformed responses and checks the
  exact successful mutation result. The stricter guard then catches Git exposing
  `/private/var` while a bound workspace uses `/var`. The host verifies the same
  physical root before exporting the exact bound path. The client never resolves
  remote paths on this Mac. All three initially failing native Git cases pass
  after this host-only fix; their exact processes drain and three resolved
  synthetic failure fixtures are removed after bounded evidence capture.
- All 72 Python harness/configuration checks pass in 2.590 seconds. The 27-case
  native GUI runner compiles with the remote inspector menu now enabled; no local
  GUI execution occurs. The async-default ABI guard checks 962 Mach-O objects,
  including 652 Core and 257 app objects, with zero weak records.
- Earlier commit `c1873ef` now has complete hosted success in run
  [39894730771](https://github.com/apoorvdarshan/coincide/actions/runs/39894730771):
  Core/package, all four GUI shards and the aggregate gate pass, covering its
  26 native workflows exactly once without skips. This does not establish
  hosted acceptance for the new remote inspector or a real two-Mac SSH setup.

## 2026-10-23 — Native SSH environment host and remote workspace window

- The complete serial run passes 1793 of 1806 declarations, with thirteen
  optional installed/live declarations skipped. Pinned Pi package acceptance is
  enabled. Core covers 1556 declarations in 361.373 seconds; native view/store
  covers 226 in 70.452 seconds, terminal eleven in 1.422 seconds and Markdown
  thirteen in 0.133 seconds. After the final app-only focused-menu and disconnect
  diagnostic changes, an incremental compile and focused rerun pass all 39
  matching declarations: 34 Core in 3.346 seconds and five native view/store in
  0.746 seconds. The entire suite is not repeated after those app-only changes.
- Build-only packaging, deep strict bundle/helper signature verification and
  native math resource rendering pass. Both app/helper Mach-O UUIDs match their
  final compiled products. The signed packaged helper passes descriptor/version
  readback and graceful EOF exit without opening SQLite or a provider. Its
  private fixture is removed after exit. The installed app is not replaced or
  launched; the development bundle is `dist/Coincide.app`. The ABI guard checks
  940 objects, including 630 Core and 242 app objects, with zero weak records.
- The first integration checkpoint passes 36 focused declarations: 32 Core,
  SSH, private-storage and native-host cases in 3.339 seconds, and four native
  view/store cases in 0.589 seconds. The native helper uses the production
  JSON-RPC client, SQLite journal and Engine with a generated private Codex peer.
  This verifies streaming Unicode, exact approval payloads, stale-run Stop
  refusal, one native interrupt, dropped committed replies, durable receipt
  recovery, identity/protocol/sequence refusal and reconnect without input replay.
  No installed provider account or actual SSH network connection is used.
- Initial integration failures identify a fixture-only `/var` versus
  `/private/var` spelling mismatch for the same physical directory, plus a client
  defect that disconnected after a known receipt-collision response. The
  fixture now compares the confined physical path, and the client retains a
  valid connection for typed refusals while continuing to reject unknown/malformed
  responses. All three real native-host integration declarations then pass.
- Store checks cover persisted uncertain requests across app-store recreation,
  receipt lookup without a second command, preserved newer Unicode drafts,
  cancellation of a reconnect waiting on old-process close, per-environment
  sequence floors, drained draft writes and failed-save text retained through
  cancelled Quit. These are offscreen view/store checks.
- The hosted native GUI source grows from 26 to 27 workflows. Its new remote
  window/form case verifies menu/shortcut opening, invalid configuration before
  SSH, remote command-menu scope, cancellation/reopening and unchanged local workspace. The runner compiles
  locally with `--build-for-testing`; all 72 Python harness/configuration checks
  pass with exact shard coverage `[7, 7, 7, 6]`. No local GUI test is executed.
- Independent review catches global shortcuts targeting the local conversation
  while the remote window is frontmost. Focused scene values now route New
  Thread, Add Project, Stop and Resume Queue to the remote store/sheets and
  disable its unavailable local inspector. The final GUI runner compiles again;
  rendered shortcut ownership remains a hosted acceptance check.
- The previous `c1873ef` hosted Core/package job passes; its 26 GUI workflows are
  still separate pending evidence for that earlier implementation. Actual
  two-Mac SSH/provider and new rendered remote-window acceptance remain required.

## 2026-10-23 — OpenCode steering, Claude commands and terminal restoration

- The complete serial local run covers 1784 declarations: 1539 Core in 383.972
  seconds, 221 native view/store in 68.887 seconds, eleven terminal in 1.398
  seconds and thirteen Markdown in 0.134 seconds. Thirteen opt-in installed
  declarations are skipped; pinned Pi package acceptance is enabled. There are
  1769 passes and two failing declarations (four failing expanded cases): an old
  script test reuses a suspended window without restoration, and an old Claude
  steering peer emits orphan deltas/tool blocks without native message starts.
  Both fixtures are corrected without product changes or weaker assertions.
  The final focused rerun passes five native view/store, nine terminal and three
  Claude steering declarations (including all three foreground-agent cases).
  The whole suite is not repeated after these fixture-only corrections.
- Build-only packaging, deep strict signature verification and native math
  resource rendering pass. Packaged/compiled Mach-O UUIDs match. The ABI guard
  checks 921 objects, including 614 Core and 237 app objects, with zero weak
  records. Final native GUI compilation and all 72 Python harness checks pass.
  The installed app is not replaced or launched; the development bundle is
  `dist/Coincide.app`.
- OpenCode v1 active steering passes 68 focused declarations (110 expanded
  cases), including 11 new steering declarations (19 expanded cases). Native
  user-message identity, original-run ownership, pending-request admission,
  stale idle reads, cancellation, uncertain delivery, FIFO and SQLite/history
  evidence are covered. These are controlled protocol/Engine checks, not an
  installed OpenCode 1 model run.
- Claude stream/final reconciliation now retains native content-block indices
  across per-block assistant envelopes. Root/child ownership, equal text in
  distinct blocks, explicit replay, tool/reasoning blocks, repeated inputs and
  journal/restart paths pass focused checks. This fixes the duplicate-row source
  defect observed in the earlier installed question turn; old persisted rows
  remain unchanged, and a fresh installed model turn has not verified this fix.
- Claude's native initialize/commands_changed inventory and composer slash
  commands pass six Core and two native view/store declarations. Refresh uses a
  metadata-only actor without resuming the conversation or consuming selected
  history. Exact literal invocation, aliases, replacement, malformed metadata and
  runtime scope are covered. Installed Claude 2.1.308 is version-verified; an
  initialize-only catalog probe was not launched because the normal runtime
  enables SessionStart hooks. No installed catalog acceptance is claimed.
  Claude filesystem skills and multi-mention skill dispatch remain unfinished.
- Terminal checks cover real PTY output, inert cold restoration, independent
  window claims, selection/order, removed tabs and workspaces, Unicode bounds,
  corrupt/symlink files, native scrollback search and same-window reuse. A real
  database-lock regression verifies failed workspace loading cannot claim or
  erase another runtime's terminal archive. The last focused run passes four
  native view/store and five terminal declarations. Restored output is plain text;
  no live process reattachment or command replay is implemented.
- The hosted project-script workflow now checks normal Quit/relaunch, restored
  output and search beyond visible rows, unchanged draft/configuration/HEAD and
  exact invocation receipts with no command replay. The runner compiles locally
  with `--build-for-testing`; no local GUI test is executed.
- Earlier hosted evidence is kept separate: `b716e29` completes 25 GUI methods
  with 21 passes and four failures addressed by `4d1840d`. `7a8ed1b` completes
  26 methods with 21 passes and those four failures plus a Claude question focus
  failure. Its screenshot shows the custom-answer field clipped below the
  question viewport, where the test's click instead focuses the composer.
  The test now reveals each control inside that exact viewport and verifies
  keyboard focus before typing, while retaining its exact answer receipts.
  The `4d1840d` GUI run subsequently finishes with 25 of 26 methods passing:
  all four earlier product failures pass, and only that old Claude question
  focus case fails. It is not an overall GUI pass. The question helper fix is
  included in `c1873ef`; that implementation's fresh hosted run is separate.

## 2026-10-23 — Final local checkpoint after hosted failure fixes

- Implementation `4d1840d08699b2ac4867bd6e15d9106662c3de7c` passes the complete
  local serial suite: 1743 actual passes out of 1755 declarations, with twelve
  optional live declarations skipped. Core reports 1520 declarations in 358.738
  seconds, native view/store 216 in 67.416 seconds, terminal six in 1.393 seconds
  and Markdown thirteen in 0.132 seconds. Pinned Pi package acceptance is enabled.
  This includes the native OpenCode default/readiness fixes, window command
  placement and Claude consumer-inspection submission hold.
- Build-only packaging, deep strict signature verification, native math resource
  rendering and the async-default ABI guard pass again (912 objects, zero weak
  records). Packaged and compiled app Mach-O UUIDs match. The installed app is
  not replaced or launched; the development bundle is `dist/Coincide.app`.
- The preceding `b716e29` batch passes the hosted full suite with 1736 actual
  passes from 1750 declarations, fourteen optional/dependency checks skipped,
  in 911.864 seconds. Both isolated Codex probes pass; the hosted ABI guard
  checks 806 objects with zero weak records, and packaging/signature/resources
  pass. Its UI jobs and the later fixes' [exact implementation run](https://github.com/apoorvdarshan/coincide/actions/runs/39889928420)
  are separate pending acceptance. Local unit and runtime evidence does not
  establish a passing hosted GUI result.
- At 02:52 UTC, that exact `4d1840d` implementation's hosted test/package job
  and configuration checks also pass. Its four native GUI shards remain queued
  behind earlier runs, so hosted window/control acceptance is still pending.
- One restricted installed-Claude 2.1.308 turn observes a native multi-select
  question, accepts both labels plus an unguessable custom answer and notes, and
  completes with the draft and sentinel intact. The initial verifier fails its
  exact formatting assertion because the model appends a period to the notes.
  The completed private fixture then passes a separate offline check using the
  revised shared validator: exact first answer line, the complete unguessable
  notes literal, exactly one succeeded response effect with exact selections and
  notes, journal rebuild/validation and SQLite reopen without starting a provider.
  That retained-evidence check passes in 0.042 seconds. No second model call is
  made, and the fresh live invocation is not rerun with the revised assertion.
  The permanent opt-in test restricts tools to AskUserQuestion and disables hooks,
  skills and MCP for its invocation; existing authentication is unchanged.
  Run it explicitly with `COINCIDE_LIVE_CLAUDE_QUESTION=1 swift test --no-parallel --filter installedClaudeQuestionAcceptsNativeSelectionsNotesAndPreservesPrivateWorkspace`.
  The same turn exposes two identical assistant rows for one native API message
  under stream/final block suffixes `1` and `0`. This was unresolved at that
  checkpoint; the source fix and its evidence are recorded above. It does not
  establish a second native answer effect.

## 2026-10-23 — Parallel implementation milestone

- The complete serial local suite passes 1738 of 1750 declarations, with twelve
  optional live declarations skipped: 1515 Core declarations in 350.534 seconds,
  216 native view/store in 65.869 seconds, six terminal in 1.384 seconds and
  thirteen Markdown in 0.137 seconds. The pinned Pi package acceptance is enabled.
  This run includes typed Claude questions, OpenCode app-MCP integration and
  notification transition/revalidation coverage. The subsequent OpenCode path
  normalization and alias cases are verified separately below.
- Five final OpenCode app-MCP declarations pass in 2.180 seconds, including both
  generations through real owned-process/HTTP/SSE/Engine paths and explicit
  symlinked workspace aliases, FIFO, Stop, durable writes, namespace collisions,
  registration failures, credential redaction and metadata-only isolation.
  The native child remains a deterministic peer.
- The combined installed-provider acceptance completes both model turns and
  durability checks for Codex 0.163.0 and Claude 2.1.308. Installed OpenCode 2.1.3
  exposes a genuine directory-scope mismatch: owned transport and actor now use
  the same resolved path. Native readback also materializes an omitted model
  variant as the literal `default`; the adapter now sends that sentinel while
  preserving captured choices and strict readback. Thirteen focused declarations
  pass in 4.298 seconds, including implicit/default and explicit-variant controls.
  A later retry reaches native execution; reading only its generated native
  history identifies `provider.auth` failures with HTTP 403. The configured
  provider rejects access, so further model calls stop without silently changing
  models or credentials. Live OpenCode tool execution remains unaccepted.
  Generated failures are retained without printing arbitrary error payloads.
- Native v2 can return model-inventory HTTP 503 after its identity is ready.
  A ten-second read-only readiness loop retries only that explicit temporary
  failure. Eleven final focused declarations pass in 12.978 seconds, including
  fail-fast authentication/schema/scope errors, cancellation/close and persistent
  unavailability ending after 10.194 seconds. No submitted prompt is retried.
- The focused integration run passes 27 Core declarations and three native
  view/store declarations. Claude question coverage exercises the real Engine
  command path and native stdio response, exact request ownership, single/multiple
  choices, custom answers, notes, cancellation and stale/reused requests. Its
  protocol child is synthetic; no installed model question or rendered hosted
  question-form interaction is claimed.
- Notification checks cover history/import baselines, Stop, archive, rewind,
  approval/input/failure/completion transitions, repeated projections and stale
  queued events after resolution, replacement, rename, new work or removal.
  Native settings, background delivery, sound coalescing, Dock counts and click
  navigation are wired, but packaged OS permission/banner/sound/click acceptance
  remains unverified. Notifications default to Off; synthetic test bundles cannot
  request permission, play sounds or alter the product's Dock badge.
- All 72 Python harness checks pass, along with actionlint and shell syntax.
  Native UI execution now partitions all 26 workflows across four isolated hosts,
  serially within each desktop. Selection manifests and actual xcresult identities
  must cover every test exactly once, with no skips, retries or missing shards.
  Existing checks remain enabled. Hosted timing and acceptance are still required;
  local harness verification does not establish an observed speed improvement.
- The additional hosted Claude question workflow compiles with
  `--build-for-testing` without launching a GUI. Its isolated protocol peer
  verifies single/multi/custom answers, notes and cancellation. The GUI workflow
  requires exact native answer receipts, completed durable runs, restart without
  replay and unchanged workspace bytes. Hosted click acceptance remains pending.
- Build-only app packaging, deep strict signature verification and native math
  resource rendering pass. The async-default ABI guard checks 912 objects,
  including 604 Core and 235 app objects, with zero weak records. The installed
  application is not replaced or relaunched by these checks.
- The older unsharded [909c1df hosted UI run](https://github.com/apoorvdarshan/coincide/actions/runs/39883323528)
  reaches its 45-minute job limit after 16 passing and four failing workflows;
  five workflows remain unverified. Retained accessibility trees identify a
  missing File → New Window item, two restart assertions preceding publication
  of an already-restored selection, and an enabled composer during Claude's
  selected-context inspection hold. The menu now uses one replacement command
  group; restart checks wait for exactly one actually selected native row; the
  composer and submit preflight enforce the hold while leaving inspection
  available. Four focused native declarations pass in 0.103 seconds and the
  revised GUI runner compiles without launching an app. Fresh hosted acceptance
  is still required; the timeout is not a passing UI result.

## 2026-10-23 — Installed OpenCode 2 MCP registration contract

- An isolated probe of installed OpenCode **2.1.3** passes the native runtime
  sequence: location-scoped `GET /api/mcp`, a collision-free
  `PUT /api/experimental/mcp/coincide` returning 204, a matching `connected`
  status, and `DELETE` returning 204 followed by absence from the catalogue.
  The loopback MCP peer receives initialize, initialized and tools/list exactly
  once. There are no session, prompt, model or tool-call requests. The owned
  parent and both pipe readers join after stdin closes.
- All XDG locations and the workspace are private scratch. A macOS sandbox
  denies reads/writes in the user's home, security services and external
  networking, while allowing loopback communication. Seven generated files have
  no exact app-MCP header or token matches; the probe's size-bounded scan excludes
  a 9660064-byte extracted Bun runtime library. This is native registration
  evidence only: Coincide's OpenCode adapters still need app-MCP integration,
  inbound redaction, lifecycle tests and model-driven acceptance. OpenCode 1's
  different endpoints remain a separate integration.

## 2026-10-23 — Native Codex MCP approval and installed model acceptance

- The first installed app-tool acceptance check passed on Claude **2.1.308** but
  exposed a real Codex **0.163.0** failure: reading worked, while renaming required
  `mcpServer/elicitation/request`, which Coincide had rejected as unsupported.
  Coincide now routes Codex's empty `mcp_tool_call` form through the native
  Approve Once / Decline presentation. It checks exact thread, turn and pending
  request ownership, and sends no saved-permission metadata. Nonempty forms, URL
  consent, user verification and remembered permissions remain unsupported.
- Eleven focused Core declarations pass in 4.193 seconds, including parameterized
  command/MCP approval and decline flows through the real Engine, HTTP listener,
  native JSON-RPC pipes and SQLite. Additional cases reject foreign thread/turn,
  missing turn, unsupported form/mode/kind, changed requests and repeated answers.
  Existing FIFO, Stop, late-event fencing, credential checks and restart coverage
  remain in the production-factory acceptance test. These peers are synthetic.
- With the fix, the opt-in installed acceptance passes both provider cases in
  35.748 seconds. Each uses its existing CLI login and two actual model turns:
  read and rename a generated app thread, followed by a same-runtime read of its
  resulting title. Assertions require the native tool events and exact model
  answers, preserve an unsent draft and unchanged sentinel file, scan the durable
  journal for registration/header markers, and verify journal rebuild and SQLite
  reopen. Only the exact generated app-tool requests are approved. The successful
  app fixture is removed; native CLI test conversations remain in provider history.
  This does not verify rendered approval interaction, managed-account sign-in,
  other tools or full provider parity. The check is off by default; its command
  and boundaries are documented in [MCP.md](MCP.md).
- The complete serial suite passes 1711 of 1723 declarations, with twelve optional
  live declarations skipped: 1491 Core declarations in 347.647 seconds, 213 native
  view/store in 66.518 seconds, six terminal in 1.356 seconds and thirteen Markdown
  in 0.140 seconds. The pinned Pi package acceptance remains enabled in this run.
  Build-only packaging, deep strict signature verification and native-resource
  loading pass. The async-default ABI guard checks 899 objects, including 591 Core
  and 228 app objects, with zero weak records. Hosted UI verification is separate.
- The preceding app-tool/window/history batch at `909c1df` passes the complete
  hosted 1719-declaration Swift suite in 828.986 seconds in
  [run 39883323528](https://github.com/apoorvdarshan/coincide/actions/runs/39883323528).
  Both isolated Codex runtime inspections, the async-default ABI guard (794
  objects, zero weak records), packaging, signature and resource checks pass.
  This run does not reproduce the previous Pi history stack crash. Native UI
  execution and the later `9bc5f7d` approval commit's hosted result are pending.

## 2026-10-23 — Codex/Claude app tools, window recovery and history stack lifetimes

- On resuming the paused work, the retained full serial run reports 1719 test
  declarations: 1708 passes and eleven optional installed-provider skips. Core
  finishes in 366.728 seconds, native view/store in 70.274 seconds, terminal in
  1.376 seconds and Markdown in 0.163 seconds. A fresh focused run against the
  recovered working tree passes all 96 declarations (86 Core and ten native
  view/store), including MCP registration, credential redaction, permission
  leases, window coordination and Pi history. All 67 Python harness checks pass.
  The 25-case hosted UI runner compiles locally without launching the GUI;
  build-only packaging, deep strict signature verification and native-resource
  loading pass. The async-default ABI guard checks 897 objects with zero weak
  records. These local results do not resolve the hosted failures below.
- Native Codex and captured normal Claude sessions now receive the private app
  MCP connection through stdin, with native registration/status acknowledgement
  required before input. Codex preserves other servers through a dotted override;
  Claude refuses owned-name collisions or dynamic servers its control call could
  replace. Failed registration closes the attempt without a prompt fallback.
  Owned Codex configuration remains lazy and forwards to each credential epoch.
- Twenty new focused declarations pass: seventeen Core declarations in 5.812
  seconds and three native coordinator/store declarations. Parameterized cases
  cover registration barriers and failures, exact private HTTP calls through the
  real Engine/SQLite facade, allow/decline, captured FIFO input, Stop, same-runtime
  reuse, durable rebuild/reopen and no replay. The protocol children are synthetic;
  these cases do not establish authenticated model-driven invocation.
- Common inbound redaction covers exact headers and bare tokens in responses,
  remote errors, notifications, native requests, callbacks and JSON keys. Outgoing
  registration retains its header; unconfigured transports retain prior behavior.
  Inspection has bounded depth/node work with no raw-subtree fallback. A real
  Engine test preserves queued permissions, reuses an unchanged lease, then drains
  and revokes it before a successor with changed captured permissions. The old
  credential receives HTTP 401. Owned-Codex tests also join a blocked handoff and
  prove exactly one child close, resource release and access-ticket release.
- Separate installed CLI probes confirm actual Claude **2.1.308**, Codex
  **0.163.0**, and managed Codex **0.156.1** registration/catalog behavior. The
  managed arm64 archive is the pinned 127394863-byte official artifact, verified
  against SHA-256 `fea42f9625091f011e38f059da974d52e57ba31831648bb1c7f0b1a385fde547`
  before extraction/execution. Native initialize, status and registration succeed;
  the managed status omits `httpOrigin`, which the compatibility check permits.
  These probes send no user input, `turn/start`, tool calls or account sign-in.
  Private homes, denied external networking/security services and joined owned
  processes isolate the checks. Exact header/bare-token scans find no persistence
  in either private namespace; the installed pair scan covers 69 files and
  2907230 bytes with no oversized-file skips. Existing history/steering profile
  restrictions remain unchanged.
- Main-window startup/loading now works independently of a `ContentView`, with
  a stable SwiftUI scene ID, weak native window registration, a deferred Commands
  `OpenWindowAction`, New Window and Dock reopen. Offscreen checks cover pending
  presentation, coalescing, relay replacement and queued project opens without
  creating a provider. A twenty-fifth hosted case closes the last main window,
  reopens through each native entry point and checks the same process, saved
  workspace and draft. Existing 24 cases remain; CI requires all 25 to pass with
  zero skips. Hosted execution of these changes remains unverified.
- Prior [run 39875604721](https://github.com/apoorvdarshan/coincide/actions/runs/39875604721)
  at `0d51e0df` passes build/test/package but reproduces nine passes and fifteen
  failures across 24 hosted UI cases, in 1934.860 seconds. AX artifacts confirm
  the same nine windowless processes and six Claude/Pi harness defects as the
  earlier run. The current Claude pending-banner query accepts the exact AX
  label **or value**, retaining the original text and deadline. The window recovery
  implementation is not evidence that the initial windowless cause is resolved.
- [Run 39879831113](https://github.com/apoorvdarshan/coincide/actions/runs/39879831113)
  at `806fa53` fails Core with a native SIGBUS at a stack guard. Its sanitized
  fault stack directly enters Pi candidate/source/files history validation and
  retained checkpoint-path validation. Candidate reduction now bypasses the broad
  Pi mutation frame; full native-source validation returns before files validation
  begins, and app-MCP guard copies live outside the common command router. Static
  extraction checks preserve all validation bodies, their order and errors.
  Local Xcode 27.1 object inspection shows about 10.6 KiB less overlapping fixed
  reserve and fewer metadata-sized buffers on that descent; instruction counts
  are not byte totals or proof of hosted Xcode 26.6 success. Hosted crash recovery
  remains to be verified without larger stacks, retries or disabled tests.

Full T3 parity, the remaining providers' app-tool registration, broader setup/auth
and hosted GUI acceptance remain unfinished. See [MCP.md](MCP.md) and
[PROVIDER_PARITY.md](PROVIDER_PARITY.md) for the boundaries.

## 2026-10-23 — native app MCP, scoped Engine actions and Pi tools

- Full serial `NSUnbufferedIO=YES swift test --no-parallel`, with the two
  isolated pinned-Pi checks explicitly enabled, exits zero. The runners report
  1699 test declarations: 1688 pass and eleven optional installed-provider
  checks skip. Core reports 1470 declarations across eight suites in 334.449
  seconds; native view/store 210 in 67.395 seconds, terminal six in 1.342 seconds
  and Markdown thirteen in 0.143 seconds. The optional skips do not establish
  authenticated installed-provider acceptance.
- All forty focused MCP declarations pass in 2.419 seconds. After a final
  local-variable naming refinement in argument validation, the same forty pass
  again in 2.138 seconds. Coverage includes real loopback HTTP, both pinned MCP
  versions, hostile framing/origins, capability isolation, exact request IDs,
  explicit cancellation, response loss without replay, concurrent revocation
  and shutdown joining an already-removed cancellation-resistant callback.
- Real SQLite Engine checks cover literal independent input, preserved composer
  text/attachments and explicit titles, captured FIFO settings, in-place queue
  edits/reordering, durable retry IDs and parent-creation audit. Held metadata
  cannot apply old model choices after a target runtime/home change. Exact Stop
  guards refuse a successor run/runtime; pending-question guards refuse a reused
  ID, changed question, changed runtime or an already-responding request. A
  permission request cannot be answered through the question-only tool.
- The intact pinned Pi 0.80.5 package runs through the production factory,
  native RPC extension, real authenticated loopback MCP server, Engine and
  SQLite. A synthetic in-process model reads its actual thread without an
  approval, requests a rename that waits for supervised approval, observes the
  native result, then reads the renamed thread on a second explicit turn using
  the same provider runtime. Native tool rows retain exact run ownership and
  history proof; journal rebuild/reopen retains the title and performs no replay.
  The test verifies one owned native PID and its exit after shutdown. It passes
  in 1.100 seconds in the full suite and 1.106 seconds in the final focused run.
  The separate intact-package skill/template/steering test passes in 1.312
  seconds in the full suite, retaining its independent digest-only journal proof.
- These two package checks use private homes and a synthetic local model, with
  OS policy denying external networking; the MCP check permits loopback only.
  They use no saved account or paid model and make no authenticated-model claim.
  Six generated-JavaScript HTTP peer variants additionally cover JSON/SSE,
  wrong IDs, tool errors, redirects and exact explicit cancellation.
- Storage 41 retains nonsecret parent-creation identities and independent queue
  title intent; command receipt fingerprints bind scoped authority. Migration checks accept prior supported storage versions
  and refuse storage 42 without downgrading it. Runtime bearer credentials are
  non-Codable, passed through a private 0600 sidecar, and absent from the native
  launch environment, extension source, journal and diagnostics.
- The final 67 Python harness/configuration checks pass in 2.342 seconds.
  Build-only packaging, deep strict signature verification and the packaged
  native-resource CLI all pass, without opening or installing the desktop app.
  The async-default ABI guard checks 889 objects (226 app and 583 Core), with
  three local default records and zero weak records. The staged patch passes
  the redacted secret scan. These checks do not establish notarized distribution
  or hosted interactive GUI acceptance.
- Hosted run `39871242182` at `b69e59d` passes its build/core/package job but
  fails native UI: nine of 24 scenarios pass and fifteen fail. Artifact AX/logs
  establish the three Claude cases used an over-128-character XCTest identifier
  query and the three Pi cases searched alerts instead of actual nested sheets
  or attempted ordinary Quit with history sheets still open. Targeted harness
  corrections preserve exact labels, assertions, deadlines, durable unknown-state
  evidence and normal Quit/relaunch. They have not yet passed hosted GUI testing.
  Nine other failures show a new process with menus and no native window; their
  cause remains unproven. No GUI pass or completion is inferred from local tests.

The implemented surface and remaining services/providers are listed in
[MCP.md](MCP.md). App MCP is enabled in the native product; library callers opt in
explicitly. Ordinary synthetic GUI transport fixtures remain isolated from it.
Full T3 parity, other-provider MCP registration and installed/authenticated
provider acceptance remain unfinished.

## 2026-10-23 — native Pi/OpenCode commands, skills and expanded-input ownership

- Full `NSUnbufferedIO=YES swift test --no-parallel` exits zero with 1659
  declarations: 1647 pass and twelve optional checks skip. Core's 1430
  declarations across eight suites finish in 333.761 seconds; native view/store
  210 in 67.770 seconds, terminal six in 1.389 seconds and Markdown thirteen in
  0.138 seconds. Eleven skips are installed-provider checks; the twelfth is the
  opt-in full Pi package test, independently exercised below.
- After the last narrow Pi hook admission refinement, all fifteen affected
  bridge, crash-recovery, compaction and intact-package declarations pass in
  3.418 seconds. This includes seven selected-skill refusal cases, exact handled
  refusal for foreign/replayed/invalid input and all later inputs on the invalid
  bridge. The actual pinned-package case passes again in 1.564 seconds. Unrelated
  production code and native UI remain as checked by the full run above.
- Focused command, metadata, Engine, bridge and composer checks pass 48
  declarations: 43 Core declarations in 2.777 seconds and five native view/store
  declarations in 1.966 seconds. Parameterized cases cover partial catalogs,
  conflicts, disabled invocations, exact native IDs, captured settings,
  cancellation, stale ownership, callback-before-terminal and
  terminal-before-callback ordering, uncertain delivery, FIFO and restart.
  Sixteen offscreen command/composer layouts cover narrow/wide, light/dark and
  both text directions; these do not establish hosted interactive acceptance.
- Real loopback HTTP/SSE tests pass both successful v2 callback orderings and
  the ambiguous/lost-root cases. They exercise the default production factory,
  actor, Engine and SQLite with actual native root IDs, unchanged authored
  text, held FIFO and no ordinary-prompt fallback. The callback must finish
  before terminal completion; bounded post-callback message/inbox inspection
  refuses multiple roots. This is local ownership proof, not external-writer CAS.
- Pi input reservations are committed before publication/write. The app-owned
  extension binds the authored digest to its actual native user object; terminal
  reads independently verify nonce, marker adjacency, actual expanded input,
  complete baseline and ordered owners. Selected skill read/UTF-8/size failures
  and ambiguous names invalidate admission instead of proving literal fallback.
  Unknown variables remain literal. Native templates and leading `/skill:`
  expansion remain in Pi's own pipeline. Normal `/compact` now uses its actual
  RPC, optional instructions and completed/quiet observation without a fake turn.
- The opt-in intact-package Engine/Session check passes in 1.581 seconds using
  Pi 0.80.5, four locally implemented synthetic model streams, private homes,
  explicit fixture resources and an OS network denial. It proves repeated and
  multiple inline skills, active steering while the first stream is held,
  actual native template and leading-skill expansion, nonce-bound actual native
  user mappings, digest-only journal records, SQLite rebuild and restart without
  replay. No real account, credential or model-service request is exercised.
  The test is enabled only by `COINCIDE_NATIVE_PI_PACKAGE_ROOT` and
  `COINCIDE_NATIVE_PI_NODE`; it does not install a runtime or use the user's
  provider data. Its initial harness-only failure enforced the project's exact
  registered workspace spelling; the fixture now captures that same spelling.
- Reusable `script/verify_pi_native_history.py` independently verifies all 821
  original files against the exact official 0.80.5 archive and 128 installed
  dependency versions against its published runtime lock. Dependencies were
  prepared in private scratch without installation scripts; the original
  package manifest/payload remain unchanged. Actual network-denied RPC passes
  historical fork, first-user cut and CLI `--fork`, with unchanged source,
  exact retained entries and zero-exit owned drain. This check sends no prompt
  and has no credentials. The first-user result contains four model/thinking
  metadata entries but no persisted candidate file: production still refuses
  that unsupported nonempty-unpersisted reset rather than calling it empty.
- Four crash-inspection cases independently reprove expanded native inputs from
  the exact anchored file after loss before terminal journal persistence; wrong
  nonces, later replacement and foreign users remain unavailable. Storage 40
  preserves bridge ownership; migrations retain older versions and refuse 41.
- The new Node bridge helper originally stalled in Foundation `waitUntilExit`
  after its child exited, confirmed by a process sample. It now uses the existing
  bounded asynchronous `ProcessChannel`, owns cancellation/drain, and passes all
  retirement, unsafe-file, replay and selected-skill-failure cases without longer
  deadlines. Production process handling was not changed by this test fix.
- All 67 Python harness checks pass in 4.003 seconds. The compiled async-default
  guard passes on 873 Mach-O objects (app 226, Core 567), with three local default
  records and zero weak records. The final app packages with `--build-only`,
  passes deep strict signature verification and renders bundled math through
  `--verify-resources`. These checks neither open an app window nor install a
  system app.
- Full provider parity, authenticated acceptance, MCP, session import, usage and
  hosted interactive command/skill acceptance remain unfinished. Current native
  UI CI results remain separate from the offline and isolated-package evidence.

## 2026-10-23 — durable Pi fork, rewind and explicit fresh context

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits zero with
  1611 declarations: 1600 pass and eleven optional installed-provider checks
  skip. Core's 1387 declarations across eight suites finish in 325.892 seconds;
  all 205 native view/store declarations pass in 65.411 seconds, terminal six
  in 1.364 seconds and Markdown thirteen in 0.128 seconds. No issue is reported.
- Focused Pi provider, history, journal, Engine and native Store/view checks pass
  54 declarations: 51 Core declarations in 6.668 seconds and three native
  view/store declarations in 0.351 seconds. They exercise the production Pi
  actor against a private synthetic stdio peer, durable candidate admission,
  lifecycle-dialog ownership, lost acknowledgments, restart without replay,
  source preservation, inherited lineage, fresh-context consumers and recovery.
  These checks do not invoke an installed Pi package, authentication or a model.
- A subsequent production-Engine filter passes four declarations/six cases in
  16.213 seconds. Real Git worktrees exercise conversation-only rewind, combined
  file restoration with once-only latest-draft recall, standalone files-only
  restoration, and stale-file-review refusal before provider mutation. The
  selected receipt is the previous completed run's post-run checkpoint, rather
  than the selected run's later baseline. Native session bytes, shared checkout,
  HEAD, branches, immutable run origins and SQLite replay remain checked.
  Warm runtime cases also verify conclusive veto retains its exact process and
  reader, while successful rewind drains it before the next explicit input.
  Initial failures in this new fixture correctly enforced isolation and exact
  checkpoint-path admission; it now uses real Engine worktree preparation and
  Git's canonical path spelling. No production guard or deadline was weakened.
- Storage 39 retains typed Pi history operations, candidate ownership, lifecycle
  controls, immutable adoption proof and explicit fresh-context intent. Schema
  assertions now expect 39, retain older-version migration cases and refuse 40.
  The first full attempt reached the end without a crash, with nineteen issues
  confined to stale schema-38 assertions; its native view/store, terminal and
  Markdown targets passed. The final canonical run above verifies the fixes.
- The original-source fork generator produces a separate 98,326-byte,
  thirteen-case fixture with SHA-256
  `4429c00ca0154c9839138649a4f0db54207cfe7281962f131d7a82dde6af9239`.
  Ten native transform outputs, two native rejections and one policy refusal
  cover retained branches, exclusive user cuts and unwritten results. Its
  restricted original-source execution reports no forbidden operations and
  closes all 53 opened descriptors. The previous eleven-case graph fixture is
  byte-identical. This is source-transform evidence, not full vendor RPC or
  installed-package execution.
- The app packages with `--build-only`, passes deep strict signature verification
  and renders its bundled math resources through the verification CLI. The
  compiled async-default guard passes on 858 Mach-O objects (app 221, Core 554),
  with three local records and zero weak records. The native
  UI runner also builds and signs without launching a window; its immutable
  launcher verifier exercises the new private Pi namespace, version, state,
  entries and refusal envelopes. All 67 Python harness tests pass, with the five
  affected Pi-peer tests rerun after bounded input handling. Three additive Pi
  GUI scenarios bring the hosted gate to 24 with zero allowed skips. Actual
  hosted execution of those scenarios remains pending; no local GUI or system
  app installation is used for these checks.
- Hosted [run 39863932911](https://github.com/apoorvdarshan/coincide/actions/runs/39863932911)
  at `5c71a5c92006b02f3569119dd46408f246747380` passes its Swift build/test,
  async-default guard, packaging, signature and resource-loading steps. Its
  separate 21-scenario native GUI job finishes with eighteen passes and three
  Claude-history failures at two stale operation-ID lookups. The harness repair
  in `b69e59d9d835dea196a7f291e2eb026ec0040db5` uses Codable `review.id`;
  the computed operation `id` is not a serialized key. That repair's hosted
  [run 39871242182](https://github.com/apoorvdarshan/coincide/actions/runs/39871242182)
  passes its production build/test, async guard, packaging, signature and
  resource checks. Its separate 24-scenario native GUI result is pending.
- Pi 0.80.5 installed-package/RPC acceptance remains unverified. In particular,
  nonempty cuts that have not produced a native session file, including a
  model/thinking-only first-user reset, remain unavailable rather than being
  relabeled empty. Session browsing/import, broader native extension behavior,
  provider parity and full GUI acceptance remain unfinished. See
  [PI_HISTORY.md](PI_HISTORY.md) and [PROVIDER_PARITY.md](PROVIDER_PARITY.md).

## 2026-10-23 — captured Pi runtime and durable native entry evidence

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits zero with
  1579 declarations: 1568 pass and eleven optional installed-provider checks
  skip. Core's 1358 declarations across eight suites finish in 305.858 seconds;
  all 202 native view/store declarations pass in 65.268 seconds, terminal six
  in 1.354 seconds and Markdown thirteen in 0.130 seconds. These results include
  immutable Pi capture storage, both reducer boundaries and phased steering validation.
- The separate opt-in installed Claude history check passes in 20.384 seconds:
  four actual model turns exercise production Engine fork/deferred-rewind context,
  unchanged native source, selected-chain proof and SQLite restart. The native
  app also packages successfully with `--build-only`, passes strict signature
  verification and renders its bundled math resources through the verification
  CLI. No app window or system installation is used for these checks.
- The final focused serial run passes all 74 declarations: sixteen native
  view/store checks in 4.058 seconds and 58 Core checks in 5.447 seconds. These include the
  real stdio peer through the production factory, independent SQLite admission
  observations, exact prepared steering reservations, Stop/incarnation fencing,
  forged and stale proof containment, held responses/terminal reads, legacy
  configuration preservation, FIFO/restart, native Store capture ordering and
  five existing Claude history Engine declarations, including all three rewind shapes.
  This is offline coverage, not installed Pi authentication or model acceptance.
- Storage 38 retains the selected launcher/workspace/storage namespace and the
  prospective baseline/input audit. Entry evidence precedes completion; invalid
  or rewritten windows stay unavailable. Pi fork/rollback, session browsing and
  native history recovery controls remain unfinished. See [the contract](PI_HISTORY.md).
- The original-source generator reproduces the 87,371-byte golden fixture
  exactly (SHA-256 `7760a7c6d72e11176331d996dad119ca40b950ddbfcd03e3611374a99d55aa2b`).
  Eleven histories cover 41 live branch/reset observations and thirteen exclusive
  user cuts. Restricted original source execution records zero forbidden
  operations; all 44 read descriptors close. Existing output, changed source
  hashes, source symlinks and non-private output are refused. Swift consumes the
  committed fixture without Node or an installed provider. This is a graph,
  context classification and reload comparison, not full native mutation proof.
- New synchronous journal scenarios exposed 544 KiB worker-stack guard faults
  in steering validation and general command admission/submission. Validation
  now uses small ownership projections and separate noninlined phases; admission
  and submission release unrelated broad-switch temporaries. Independent review
  confirms the extracted submission body and timestamp/writeback tail are
  unchanged, along with validation order, error text and snapshot semantics.
  The first full attempt also exposes a guard fault in existing Claude history
  ledger validation. Pi captures now retain immutable payload storage with the
  same flat Codable keys and content equality/hash; a standalone native layout
  observation measures capture values at eight bytes rather than 168, and
  provider configurations at 1000 rather than 1160. Pure semantic checks verify
  independent decoding, hashing, namespace intent and workspace rebinding.
  The unchanged focused scenarios pass without increasing stack limits,
  deadlines or retries. The compiled async-default guard passes on 846 objects
  (app 218, Core 542), with three local records and zero weak records.
- Hosted [run 39857290147](https://github.com/apoorvdarshan/coincide/actions/runs/39857290147)
  at `968e2af` reaches all 1550 declarations without the previous native crash,
  but fails with thirteen issues in checkout Store tests: their legacy Claude
  source depended on a host-installed CLI during runtime capture. The shared
  fixture now injects a private synthetic runtime; all nine checkout declarations
  pass in the focused run with every assertion/deadline retained. That failed
  run skipped native GUI execution. The new 21-scenario hosted GUI gate remains
  unverified; its local build-only evidence is recorded below.

## 2026-10-23 — hosted native Claude history scenarios

- `bash script/test_macos_ui.sh --build-for-testing` compiles and signs the
  native runner and immutable launcher successfully. Its embedded launcher
  verifier passes Codex/GitHub/Claude envelopes, selected native parent chains,
  private profile bindings and descriptor/argument rejection. No GUI or installed
  provider is launched. The six Python CI-configuration tests also pass.
- Three additive native scenarios exercise source-preserving fork and deferred
  selection/restart without sending, one selected-context consumer followed by
  an ordinary queued successor, and read-only consumed/unwritten inspection
  without replay. Independent source review confirms all eighteen previous test
  bodies remain unchanged. The hosted result gate requires all 21 with zero
  skips; actual hosted accessibility/sandbox execution remains unverified.

## 2026-10-23 — byte-bounded events, Pi history reads and client command storage

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits zero with
  1550 declarations: 1539 pass and eleven optional installed-provider checks
  skip. All 1333 Core declarations across eight suites finish in 304.285 seconds;
  all 198 native view/store declarations pass in 65.175 seconds, terminal six
  in 1.352 seconds and Markdown thirteen in 0.131 seconds. The final compiled
  async-default guard passes on 838 Mach-O objects (app 218, Core 534), with
  three local records and zero weak records. These results include the indirect
  `WorkspaceCommand` representation below. The unchanged ACP v2 regression that
  crashed in hosted CI also passes separately with all three parameter cases in
  0.324 seconds. Hosted Swift 6.3.3 and interactive GUI acceptance remain pending.
- A separate opt-in installed Claude check passes in 13.426 seconds after the
  command-storage change. Its four generated turns exercise the actual CLI
  through Engine, native fork and deferred-rewind context recall, exact
  unchanged-source/selected-chain checks and SQLite restart. It uses a new
  private workspace and does not establish broader history compatibility or
  interactive GUI acceptance.
- A deterministic check at the real HTTP delegate-state boundary delivers 33
  independent eleven-byte callbacks before consumption. The original queue loses
  the last fragment: 352 of 363 bytes remain and `eventBufferOverflow` is reported.
  URLProtocol/TCP writes can coalesce and did not establish that callback count.
  Raw events now coalesce into at most 32 chunks of at most 16 KiB under the same
  512 KiB byte budget. The unchanged over-limit check still preserves exactly
  512 KiB before its fixed failure. The new tiny-callback case passes in 0.001
  seconds; it, the existing overflow case and unread-stream abandonment pass
  together in 0.072 seconds. Cancellation, EOF and first-error ordering retain
  their owned request boundaries; no limit, fixture pacing or retry was increased.
- Known HTTP failures survive the SSE boundary as finite diagnostic categories;
  unknown errors remain sanitized. V1 logs only a fixed category and generated
  local run UUID. A controlled existing EOF regression produces exactly one
  matching unified-log line, while its generic connection-loss behavior remains.
  These diagnostics do not retroactively prove the cause of the earlier
  intermittent OpenCode connection loss.
- Ten new Pi declarations cover 24 cases: append inventory versus runtime/reload
  leaf, exact active ancestry, compaction/custom-message context, unchanged native
  entry windows and exclusive user boundaries, malformed/legacy/deep inputs and
  bounded anchored exact-file reads. An 18,000-entry chain passes in 0.785 seconds.
  File checks include FIFO/symlink/hardlink refusal and file/parent replacement.
  Raw records remain transient; a file reload does not prove a live branch pointer
  or local run ownership. Native fork/rollback controls, original-source oracle,
  installed Pi acceptance and complete provider parity remain unfinished.
- Hosted [run 39853472698](https://github.com/apoorvdarshan/coincide/actions/runs/39853472698)
  at `3c798cf` passes both isolated Codex checks (4.175 and 0.470 seconds), then
  crashes in the unchanged ACP v2 Engine test on Swift 6.3.3. Its sanitized native
  report identifies a guard-region fault at `___chkstk_darwin`, through an outlined
  `WorkspaceCommand` copy, `preventDelayedPromptSteering`, command admission and
  `makeGeneral`. The async-default guard separately reports zero weak records.
  `WorkspaceCommand` now uses the same indirect owned-payload storage as
  `EngineCommand`, avoiding its maximum-payload stack copy. Its case/payload JSON,
  equality and receipt fingerprints retain their contracts. `ThreadEdit`, stack
  sizes, assertions, deadlines and CI gates are unchanged. Fresh hosted verification
  is required; local Swift 6.4 results alone cannot establish the 6.3.3 outcome.

## 2026-10-23 — durable native Claude history and deferred context

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits 1 with
  1535 declarations: 1523 pass, eleven optional installed-provider checks skip,
  and one existing OpenCode v1 HTTP history declaration fails. All 1318 Core
  declarations across eight suites finish in 299.697 seconds; all 198 native
  view/store declarations pass in 64.638 seconds, terminal six in 1.376 seconds
  and Markdown thirteen in 0.127 seconds. This adds 45 declarations without
  dropping existing coverage. The async-default ABI guard passes on 835 Mach-O
  objects (app 218, Core 531), with three local records
  and zero weak records. Packaging and interactive GUI acceptance remain hosted
  gates; no system app install/relaunch occurs locally.
- The failed existing declaration is
  `openCodeV1HistoryHTTPRepeatedAdoptionsResolveImmutableRunsAndPublishCandidateBeforeFurtherWire`.
  Its second source input loses the event connection between fixture observations;
  the durable run is failed with `connectionLost`, rather than completed. The
  exact unchanged declaration passes separately in 1.624 seconds. The retained
  generated diagnostic does not contain the underlying HTTP/SSE failure category,
  so neither raw-buffer overflow nor delayed idle is established as its cause.
  No pacing, timeout, assertion, retry policy or production transport was changed
  to conceal this failure. The full suite remains unconfirmed until this failure
  is diagnosed and a fresh complete run passes; hosted acceptance is also pending.
- Claude Run History is connected to the native Swift transcript service, durable
  command/effect journal and native review/recovery UI. New user runs capture the
  physical runtime/configuration/profile and exact registered workspace spelling,
  prospective opening/steering UUIDs and outer root-assistant UUID observations.
  Legacy input references are not retroactively interpreted as assistant cursors.
- Fork publication saves its exact native-file reservation in SQLite before any
  external write. The native source remains unchanged; the verified child keeps
  its remapped inherited head. Restart inspection proves that exact reserved copy
  or an untouched destination, without replay, guessing or deletion. The real
  Engine filesystem tests reject every provider-factory construction during history.
- Rewind follows the pinned T3 inclusive root-assistant cursor. Acceptance saves
  a resume point without a provider prompt or native transcript truncation. First
  local reset preserves verified inherited fork context or reserves a fresh UUID.
  Only the next explicit consuming run receives the launch selection; queued
  successors capture none. Unstamped completion, interruption and failure retain
  the consumer until exact read-only inspection, with the queue paused. The
  optional native `resumeDropsTurn` flag remains disabled.
- Physical configuration-root/native-UUID ownership spans launcher and registered
  cwd aliases. Owned runtime, metadata and history readers are tracked and drained.
  Workspace changes capture physical paths before the pure command reduction;
  queued worktree preparation retains the launcher/home/profile. Captured Claude
  model discovery uses its bound thread rather than the ambient provider catalog.
  Separately reviewed Git-file restoration and once-only latest-draft recall keep
  their existing admission and recovery boundaries.
- Focused local execution passes 33 Core declarations in 1.174 seconds and seven
  native view/store declarations in 0.305 seconds. Coverage includes filesystem
  publication/recovery, both reset forms, repeated pending rewind, inherited
  lineage, exact consuming/queued runs, model metadata, malformed roots and scope
  aliases. These deterministic peers/offscreen views are not installed-provider
  acceptance or interactive GUI acceptance.
- Before the event-reducer split, the unchanged consuming-run regression crashes
  with SIGBUS. Its native report explicitly says `Thread stack size exceeded`;
  the stack traverses `makeGeneral`, `receive`, native history locking and
  `___chkstk_darwin`. Provider events now reduce in a separate non-inlined frame,
  and the same completion/queue regression passes. The full suite then exposes
  the same stack-size failure in the unchanged Codex reasoning/queue regression,
  at an outlined copy of the enlarged `EngineCommand`. That internal command
  envelope is now indirect, avoiding maximum-payload stack copies while preserving
  value semantics and Codable case/associated-value labels. Both formerly
  crashing paths pass unchanged: five declarations in 0.135 seconds. This is
  distinct from the earlier weak async-default ABI investigation; no stack-size
  or test-deadline workaround was added.
- Storage advances from 36 to 37 for captured runtime, prospective evidence,
  exact publication and deferred context state. Old nil captures remain legacy;
  tests reject future storage 38 without downgrade. The system-installed app and
  existing user workspace database were not opened or migrated by this work.
- Installed validation found and corrected two production boundaries. Setting
  `CLAUDE_CONFIG_DIR` explicitly for the physical default root made the existing
  signed-in CLI report no login; the same inherited environment without that
  override reported a signed-in Claude account. Runtime capture now preserves
  default-home versus explicit-config environment presence and raw spelling,
  includes that choice in identity/Codable/rebinding, and revalidates its physical
  root before launch. Eight focused declarations pass in 0.363 seconds, including
  synthetic default/explicit child environments and retargeted-root refusal.
- The first authenticated fork attempt was correctly rejected before reservation:
  closing the idle CLI appended 834 bytes in two metadata records, `last-prompt`
  and `cost-state`, after review. The reviewed bytes remained an exact prefix on
  the same inode. Review now drains that owned process before capturing its
  source revision; all strict source/hash checks remain. The installed test
  separately proves pre-drain conversation records are preserved and compares
  publication against the exact post-drain reviewed revision. The deterministic
  regression passes in 0.111 seconds: its owned idle actor holds close behind a
  gate, review cannot return before metadata is appended to the same inode, and
  the subsequent reserved fork preserves that post-drain source with exactly one
  provider construction/input and no model discovery.
- Read-only installed metadata reports Claude Code 2.1.304. Its help advertises
  `--session-id` and `--replay-user-messages`; the pinned SDK source is 0.3.276
  (declaring CLI 2.1.276). Metadata alone does not verify hidden resume flags or
  model/history behavior. The new opt-in `COINCIDE_LIVE_CLAUDE_HISTORY=1` check
  uses the production factory and four generated-marker turns in a private cwd;
  it passes in 12.705 seconds. Both source marker turns, fork recall of only the
  retained first marker, and explicit rewound recall of that same retained marker
  succeed. The check independently verifies native input/root IDs, exact remapped
  publication and source preservation, deferred context with no native truncation,
  one consuming launch selection, discarded-input exclusion on the selected native
  chain, no tool/approval/workspace writes and SQLite restart receipts. Its private
  generated evidence and native transcripts are retained outside the repository.
  This verifies that installed version/case, not other native formats, steering,
  interactive GUI acceptance or complete provider parity.

## 2026-10-23 — preceding hosted isolation failure evidence

- [Run 39843887487](https://github.com/apoorvdarshan/coincide/actions/runs/39843887487)
  at `b3bd556` completes the full 1490-declaration serial suite in 864.100 seconds:
  1480 pass and ten optional installed checks skip. The isolated managed
  inspection and compiled async-default verifier pass. The separate isolated
  direct-executable inspection throws `verificationFailed` after 5.093 seconds;
  that same declaration later passes in the full suite in 0.207 seconds. The
  workflow correctly fails its isolation gate and skips packaging/native UI.
- The sanitized diagnostic artifact reports zero crash candidates/reports after
  seven scans. This is no evidence of SIGBUS, Python startup, stdin EOF failure,
  or a particular subprocess phase. Bounded fixed failure diagnostics now report
  only phase/count/EOF classifications from already-owned synthetic audit rows.
  They omit paths, environment, raw errors and records; assertions, timeouts,
  retry behavior and the isolation gate remain unchanged. The current revision
  still requires its own hosted test/package/native-UI results.

## 2026-10-23 — native Claude transcript primitives and owned lifecycle

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits 0 with
  1490 declarations: 1480 pass and ten optional installed-provider checks skip.
  Core reports 1280 declarations across eight suites in 300.305 seconds; all 191
  native view/store declarations pass in 64.468 seconds, terminal six in 1.387
  seconds and Markdown 13 in 0.128 seconds. This adds 26 declarations without
  reducing existing coverage, assertions or deadlines. The ABI guard passes on
  820 Mach-O objects (app coverage 217, Core 516), with three local default
  records and zero weak default records.
- Claude's pure Swift reader and inclusive fork retain separate raw, selected
  chain and projected-message evidence. Both compaction forms, parallel tools,
  settled queued-input aliases, native metadata/replacements, omitted progress
  ancestry and the exact default reader's 5 MiB threshold have offline coverage.
  An 18,001-record shared-progress fixture preserves all siblings and validates
  the copy in 1.601 seconds after review identified repeated ancestor traversal.
  This is a bounded fixture observation, not an installed-runtime performance claim.
- Seven independent oracle cases were generated by the original pinned official
  SDK 0.3.276 in a private synthetic home with inherited credentials removed and
  subprocess/network APIs blocked. Exact reader projections and normalized native
  fork payload/order match Swift. The optional generator reproduces the committed
  fixture byte-for-byte with zero prohibited calls. It verifies unchanged sources
  and cleans its scratch directory. Neither SDK nor Node is a shipping dependency;
  no installed Claude process, authentication or model call occurred.
- Ten exact-file store declarations exercise twenty filesystem cases: physical
  config/cwd and SDK project keys, bounded anchored regular-file reads, source
  revision checks, prepare-before-publish reservation, exclusive 0600 publication,
  source preservation and fsynced target/parent, exact read-only restart inspection,
  symlink/FIFO/hardlink and directory replacement refusal, collisions/partial
  publication and semantic refusal despite an attacker-authored matching digest.
  The caller still needs to journal reservations in the Engine before publication.
- The Claude session now preserves one root identity across child/foreign events
  and repeated runs. Its initialization is coalesced, and close joins the exact
  initialization, owned process, writer, raw/RPC/event readers and steering work.
  The held-init regression first observes two initialize requests before the fix;
  both ordinary concurrent startup and concurrent close then pass with one. The
  focused Claude/steering run passes 35 declarations with one optional installed
  check skipped in 2.994 seconds. Legacy turn IDs and database storage stay unchanged.
- These are native history primitives, not enabled Claude Run History actions.
  Prospective runtime/input/root UUID evidence, durable fork/deferred rewind,
  captured FIFO selection consumption, review/recovery/combined-file integration
  and installed acceptance remain required. See [Claude history](CLAUDE_HISTORY.md).

## 2026-10-23 — hosted skill-picker viewport regression

- Hosted [run 39832918696](https://github.com/apoorvdarshan/coincide/actions/runs/39832918696)
  executes 18 native GUI tests: sixteen pass; both light/dark skills workflows fail
  waiting for `fresh-check` after Refresh. The final native screenshot/AX state
  shows an empty search and a 41-point viewport beneath 63-point skill rows, with
  the second row below the footer. This proves layout compression; the attached
  evidence does not independently prove that the refresh wire request succeeded.
- The picker now reserves a scaled, bounded viewport for up to three suggestions,
  capped at 210 points. Larger catalogs and wrapped rows remain scrollable. Four
  offscreen cases with three/thirty rows in both appearances assert the actual
  first three row frames fit beside a competing transcript at 600-point height,
  remain above the footer and stay inside the cap. They pass in 0.124 seconds;
  existing narrow/long/RTL layout and native editor-bridge checks also pass. The
  focused run totals three declarations in 1.952 seconds. Existing hosted
  assertions and deadlines are unchanged; fresh hosted GUI acceptance is pending.
- The preceding [5df5ec5 hosted test/package job](https://github.com/apoorvdarshan/coincide/actions/runs/39839967644)
  separately passes its direct inspection in 2.235 seconds, isolated managed
  inspection in 0.213 seconds and 1464-declaration suite in 649.381 seconds. Its
  ABI guard finds zero weak defaults among 716 Mach-O objects (app 132, Core 440;
  two local defaults). This is the second successful hosted mitigation observation;
  that revision's separate native GUI job remains pending. No interactive GUI
  tests or system-app install/relaunch ran locally for this change.

## 2026-10-23 — native OpenCode v1 clone and adoption history

- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` exits 0 with
  1464 declarations: 1454 pass and ten optional installed-provider checks skip.
  Core reports 1255 declarations across eight suites in 298.657 seconds; all 190
  native view/store declarations pass in 64.576 seconds, terminal six in 1.372
  seconds and Markdown 13 in 0.130 seconds. This adds 36 declarations to the
  prior suite without weakening existing deadlines or assertions. The compiled
  ABI guard passes on 815 Mach-O objects (app coverage 217, Core 511), with
  three local default records and zero weak default records. Native GUI
  acceptance remains a separate hosted job; complete T3 parity is unfinished.
- V1 history reads bounded native message/part inventories through opaque header
  cursors. The exact native lexical fork cut must agree with the chronological
  whole-run boundary. Copy proof compares complete normalized content, unique
  regenerated message/part IDs and assistant parent positions; native compaction
  references remain literal. Quiet snapshots include session metadata and owned
  descendant/status/permission/question observations, without claiming native CAS.
- Both actions use native fork. Rewind atomically adopts the verified new native
  ID within the original local conversation, preserving immutable prior run IDs,
  current settings and the latest draft. A candidate acknowledgement is durably
  saved before later native reads or clone-only policy writes. Subsequent cuts
  follow applied copy maps, checking exact user provenance while permitting native
  assistant tool-output pruning. Indexed lookup and bounded per-call memoization
  avoid repeated full inventory scans; no runtime speedup is claimed.
- Unknown fork acknowledgements are not guessed or replayed. Known rewind
  candidates can be adopted after read-only complete copy and policy verification.
  Explicit Keep Original verifies the unchanged native source and retains an
  orphan warning/candidate audit. Pending native source and candidate aliases are
  held; an unconfirmed fork can release its source while reserving its candidate.
  Native view/store checks exercise the separate confirmation, cancellation and
  latest-draft preservation. Storage 36 prevents old readers from reopening the
  new candidate and adoption semantics.
- Cross-cut review found that combined file restoration still required the
  pre-adoption native ID. The post-provider guard now permits only the verified
  adopted ID, preserving all other captured settings. A reviewed-only checkpoint
  resolver grants ownership to exact immutable input records, including mixed A/B
  origins after repeated adoption; the public legacy resolver stays strict. New
  reducer checks drive provider adoption, file dispatch/receipt and one-time
  latest-draft recall. Their negative cases independently reject old/foreign IDs
  and changed model/permission settings. This is separate from the existing real
  Git restoration checks, not a live combined-v1 acceptance claim.
- Adopted native candidates also stay reserved through incomplete file work or
  pending prompt recall, then release after completion/dismissal. Applied fork
  targets remain usable. Broader serial regression exposed an inadvertent wait
  on an already-held close during review; that run was stopped. Review again
  refuses pending cleanup immediately, while dispatched work still joins its
  owned closes before I/O. The unchanged archived-source regression passes in
  0.038 seconds; both new combined-file checks pass in the same focused run.
- Initial focused checks pass 39 Core declarations and two native view/store declarations.
  Real offline TCP/SSE peers exercise three A runs, A-to-B adoption, a B input,
  another fork and B-to-C rewind through retained original run references; exact
  dispatch/candidate persistence precedes native I/O. They verify copy ownership,
  wrong same-count/reused-part refusal, changed-tail refusal, lost acknowledgement,
  restart/read-only recovery, untouched Git files/index/HEAD and exact owned
  process/event-stream drain. These are synthetic peers, not installed OpenCode.
- Initial TCP execution exposed the fixture's strict parsing of an empty health
  query under system Python; parsing only nonempty queries restores the exact
  health route. A second test correction explicitly creates a new draft after
  the B input, which intentionally clears the preceding draft. Original deadlines,
  copy/ownership assertions and production transport behavior remain intact.
  A separate 10,001-record legacy Codex audit regression ensures the v1 evidence
  limit cannot reject unrelated history. Installed/hosted v1 history acceptance
  and complete T3 Code parity remain unfinished.

## 2026-10-23 — async default closure context isolation

- Hosted [run 39832918696 at 4fadc85](https://github.com/apoorvdarshan/coincide/actions/runs/39832918696)
  now passes its complete Swift test/package job. The raw completed job log
  confirms the fresh direct verifier in 2.070 seconds, the separate managed
  inspection in 0.304 seconds and the full 1428-declaration suite in 713.038
  seconds. The ABI guard inspects 708 hosted Mach-O objects (app coverage 131,
  Core 432), finding two local default records and zero weak default records.
  Strict app signature and native resource verification also pass. This is one
  successful hosted mitigation observation; the separate native GUI job and
  broader end-to-end parity remain pending.
- Hosted run `39830400064` at `7513330` passes the direct public verifier check
  in 4.386 seconds, while the isolated managed-install inspection and unchanged
  full suite both terminate with SIGBUS. Its sanitized stack still reaches
  `CodexInstallationVerifier.inspect`, `memset_s` and the task allocator. The
  displayed isolated-step conclusion remains masked by `continue-on-error`;
  the raw failure and final gate are authoritative. Native GUI checks skip.
- Swift's [default async closure issue](https://github.com/swiftlang/swift/issues/92017)
  documents incompatible library/client async context records and reports the
  same Swift 6.3.3 toolchain. Inspection of this project's existing Swift 6.4
  objects independently finds the default Codex Inspector's weak record declares
  48 bytes in Core and 32 bytes in a client. Their entries also differ, at 40 and
  31 instructions. Downloader/extractor/verifier defaults declare 64 versus 32
  bytes. The local linked product retains distinct matching copies; a bad pair
  has not been measured in the hosted binary, so this is evidence of the compiler
  trigger rather than proof of the exact corrupting hosted instruction.
- Thirteen public async closure defaults across six Core initializers and five
  app-internal defaults now use optional parameters with `nil` defaults. Identical
  fallback closures are constructed inside their defining initializer. Supplied
  callbacks, production operations, timing, ownership and cancellation remain
  covered by their existing behavior tests. Synchronous defaults and named
  function references remain separate. No runtime permission or persisted model
  changed as part of this mitigation.
- The focused direct/managed pair passes locally. A read-only scan of 551 rebuilt
  objects finds seventeen local/private async-default records, zero weak records
  and zero parse errors. A native-object CI guard now checks this actual compiled
  property with explicit Core/app coverage; source text and a passing narrow test
  do not substitute for that evidence. The full suite and both fresh diagnostic
  checks remain enforced; the completed hosted observation is recorded above.
- The production guard passes on 807 existing Mach-O objects, with defined app
  coverage in 216 objects, Core coverage in 503 and zero weak default records.
  Eleven synthetic parser/CLI checks cover 48/32-byte records, weak private
  external versus local definitions, malformed/missing coverage, both build
  layouts and bounded private-data-free diagnostics. Their first run exposed the
  test fixtures' `/var` versus `/private/var` aliases; canonical fixture roots
  preserve the unreadable-file and deduplication assertions on macOS. All 60
  Python harness checks now pass in 2.408 seconds.
- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` succeeds with
  1428 declarations: 1418 pass and ten optional installed-provider checks skip.
  Core reports 1221 declarations across eight suites in 291.564 seconds; all 188
  native view/store declarations pass in 64.073 seconds, terminal six in 1.365
  seconds and Markdown 13 in 0.133 seconds. No test deadlines or verification
  assertions were weakened. Hosted test/package confirmation is recorded above;
  native GUI acceptance and complete T3 Code parity remain unfinished.

## 2026-10-22 — native OpenCode v2 history and staged-revert recovery

- OpenCode v2 history uses ordered native messages and exact deterministic local
  opening/steering ownership. Reviewed cuts retain entire runs, including their
  steers and synthetic tail. Forks regenerate message IDs; confirmation compares
  the complete semantic prefix and the native ancestry, normalizing only the
  compaction keep-reference that the provider rewrites. Codex turn boundaries and
  their legacy serialized bytes remain separate.
- Rewind requires an initially clean, quiet native session, stages literal
  `files: false` and commits only that reviewed cut. Native read-back must prove
  the exact prefix. A possible write with a lost response remains held across
  restart; inspection does not replay the mutation or clear a stage implicitly.
  The lock covers other local conversations and captured inputs targeting the
  same native session. It does not exclude independent external writers.
- Review found and fixed two additional proof/ownership gaps: an archived then
  unarchived source must wait for its exact old session to finish closing, and
  every copied fork message ID must be disjoint from the entire source inventory.
  New regressions cover the retained close, successful operation after drain and
  wholly/partly reused IDs, including an ID from the removed source suffix.
- Explicit staged-revert cleanup has its own durable acceptance/dispatch/result
  record and current-process incarnation. It accepts only the exact reviewed
  history-only stage, waits for its owned empty execution and records the exact
  start event, terminal event and corresponding single idle message. A separate
  read-only reconciliation decides whether the original history or reviewed cut
  is present. Cleanup never invents a local turn, restores files, recalls a draft
  or automatically resumes a queue. Storage 35 protects this evidence.
- Hosted run `39824687279` at `09eb51d` fails in both the fresh isolated managed
  installation test and the unchanged full serial suite. The isolated step's
  displayed conclusion is masked by `continue-on-error`; the raw log and final
  gate correctly retain failure. Earlier test execution is therefore unnecessary
  for this reproduction. The sanitized report again shows a read-only SIGBUS at
  least 1 MiB from the stack pointer through `memset_s`, the Swift task allocator
  and `CodexInstallationVerifier.inspect`; the source cause remains unproven.
  A new direct public-verifier comparison removes the installation service and
  its default async closure. It runs separately before the existing isolation and
  unchanged full suite; all failure outcomes remain enforced. This experiment is
  not a hosted crash fix or a successful GUI acceptance claim.
- The focused serial run passes 110 Core declarations and both new native
  view/store declarations, without failures or skips. Real offline HTTP/SSE peers
  exercise the production factory and Engine, three runs with two steers, whole
  history cuts, persisted dispatch before writes, lost stage/commit/clear replies,
  restart/reconciliation, exact empty-execution receipts and session aliases.
  Tests verify Git files/index/HEAD and the latest draft/settings remain intact,
  and exact owned HTTP/SSE processes finish. Narrow/normal sheet layout covers
  both appearances and LTR/RTL; no actual GUI interaction or installed OpenCode
  history call is claimed by those tests.
- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` succeeds with
  1428 declarations: 1418 pass and ten optional installed-provider checks skip.
  Core reports 1221 declarations in eight suites in 290.466 seconds; all 188
  native view/store declarations pass in 64.326 seconds, terminal six in 1.383
  seconds and Markdown 13 in 0.128 seconds. All 49 Python harness checks pass.
  No deadline, assertion or complete-suite gate was weakened. The staged patch
  passes the secret scan. Hosted diagnostics and native GUI acceptance remain
  separate pending evidence; this batch does not establish complete T3 parity.

## 2026-10-22 — typed Pi and native Muse steering

- Steering now distinguishes a native turn from an adapter-owned run. Pi uses
  only the latter, with no fabricated native turn or history IDs. Storage 34
  protects that distinction; native receipt and operation serialization retain
  their legacy bytes when the new optional adapter reference is absent.
- Pi sends native atomic `prompt` steering with captured settings and the exact
  session file. Its correlated response proves admission only. Old idle probes
  are invalidated before handoff, outstanding admission holds settlement, and a
  missing possible-write response never becomes an acknowledgement or replay.
  Stop during unresolved admission retires the owned connection. A later native
  cycle can succeed after an earlier native abort without inheriting that abort;
  explicit user Stop remains separate. `/compact` uses its native command.
- Muse sends `turn/steer` with an exact native `expectedTurnId` and UUIDv7 command.
  Exact command/session/turn admission or a matching native steered user-message
  item proves acceptance. Late old rejection/cancellation cannot retire a healthy
  successor; original-run background items keep their ownership. Neither settings
  nor uncertain inputs are silently replaced or resent.
- Real offline stdio peers exercise each production adapter and Engine, retained
  future-turn FIFO/settings, authored rows, durable receipts, Stop and shutdown.
  Pi additionally verifies restart/rebuild without native turns or replay.
  The initial build found one existing Codex reasoning assertion passing the now
  optional native reference; it now explicitly requires that native reference.
  The focused serial run passes 194 Core declarations in three suites and all
  25 selected native view/store declarations, with no failures or skips.
- Two new hosted GUI workflows cover the actual Codex skill chooser in light and
  dark appearance: Unicode draft insertion, arrows/Return/Escape, explicit chooser
  search, refresh, no send/config mutation and restoration after graceful restart.
  The runner compiles locally; no interactive GUI test was run locally. All 49
  Python harness checks pass. Hosted acceptance now requires all eighteen GUI
  workflows without skips; actual execution of the new pair is still pending.
- Hosted run `39821311145` at `8121798` again fails in the Codex installation
  verifier through `memset_s` and the Swift task allocator; GUI checks skip. Its
  sanitized diagnostic classifies a read-only fault at least 1 MiB from the stack
  pointer, which does not establish an ordinary stack-guard failure. No source
  cause is proven. CI now runs the exact managed-install test in a fresh helper
  before the unchanged complete serial suite, with pipeline failure propagation,
  sanitized crash collection and a final gate preserving either failure. This is
  a controlled diagnostic experiment, not a claim that the hosted crash is fixed.
- Final canonical `NSUnbufferedIO=YES swift test --no-parallel` succeeds with
  1394 declarations: 1384 pass and ten optional installed-provider checks skip.
  Core reports 1189 declarations in eight suites in 284.713 seconds; all 186
  native view/store declarations pass in 64.054 seconds, terminal six in 1.367
  seconds and Markdown 13 in 0.131 seconds. No test deadline, assertion or full
  coverage gate was weakened. The staged patch passes the secret scan.
- Installed Pi/Muse acceptance and hosted GUI execution remain unverified;
  offline peers do not establish vendor access or complete T3 Code parity.

## 2026-10-22 — scoped Codex skills and native OpenCode v2 steering

- Codex `skills/list` reads use the exact workspace and captured runtime/account,
  with a separate metadata actor, bounded response/items/problems and physical
  directory ownership. Unsupported capability, an empty inventory and partial
  errors remain distinct. Neither discovery nor choosing a skill creates a
  provider thread, reads a skill file or sends a prompt.
- The native glass chooser supports search, `$` and optional `/skill:` triggers,
  keyboard selection and explicit refresh. It inserts the literal advertised
  mention into the latest UTF-16 selection. Cancellation-resistant readers stay
  retained through runtime/auth changes, removal and shutdown. A delayed healthy
  inventory survives the initiating view task's cancellation while typing.
  Focused checks found that Foundation's range conversion permits a split UTF-16
  surrogate; explicit scalar-boundary validation fixes insertion and native
  selection requests while retaining the original failing assertion.
- OpenCode v2 steering binds its deterministic inbox identity and exact payload
  to the captured native session/run. It preserves original-turn receipts and
  model/agent/permission settings, holds successful terminals across outstanding
  steering and the next execution, and cancels only exact pending inbox IDs on
  Stop. A lost unproven write remains uncertain and cannot be resent as a queue.
  V1 and provider history contracts are unchanged. A real offline TCP/SSE peer
  exercises the production factory, Engine steering, captured future FIFO,
  original execution ownership, Stop/process drain and durable replay.
- Hosted run `39817860781` at `f22f7aa` fails with signal 10 in
  `CodexInstallationVerifier.inspect`, through `memset_s` and the Swift task
  allocator. It reaches beyond the previous run-history crash site. Local Swift
  6.4 object inspection finds small verifier frames; this does not establish the
  hosted Swift 6.3.3 cause. GUI checks skip. The collector now derives only fixed
  fault-region and stack-distance enums from consistent bounded native evidence;
  raw addresses, registers, private VM text and fingerprints remain private or
  unchanged. Synthetic checks cover exact range ownership, adjacent/conflicting
  guards, malformed data, bucket boundaries and private-canary non-disclosure.
- All 46 Python harness checks pass. The selected Core run passes 48 declarations;
  after the actual surrogate fix, all seven new native view/store declarations
  pass. Offscreen geometry covers 320/680-point widths, both appearances and
  LTR/RTL. Its composer bitmaps are blank and the dark picker capture resolves
  foreground colors inconsistently with its assigned appearance, so those
  captures are not accepted as visual or contrast evidence for the running app.
- Final canonical `swift test --no-parallel` succeeds with 1367 declarations:
  1357 pass and ten optional installed-provider checks skip. Core reports 1162
  declarations in eight suites in 282.382 seconds; all 186 native view/store
  declarations pass in 63.829 seconds, terminal six in 1.393 seconds and Markdown
  13 in 0.129 seconds. No full-run failure, deadline change or test bypass is
  hidden by the earlier focused fixes. The staged patch passes the secret scan.
- Actual hosted skill-picker acceptance and installed OpenCode steering remain
  unverified. Neither local protocol peers nor offscreen native layout rendering
  establishes current vendor compatibility or full T3 Code parity.

## 2026-10-22 — native owned Codex account and runtime integration

- Production Settings now connects the explicit owned ChatGPT mode to the actual
  auth coordinator and vault. Existing CLI authentication remains the default.
  Construction and saving a mode perform no account read or browser/network
  authentication. Explicit refresh/sign-in/reconnect/select/logout own their
  work; terminal cancellation/failure retires the sign-in UI even if a saved
  vault binding differs from the selected runtime. Emails remain concealed.
- Storage 33 retains only opaque profile/generation bindings in headers, accepted
  inputs and the journal. Schema-32 migration/reopen/replay keeps old CLI captures
  and accepted queue/run records intact. An atomic provider change cannot leave
  an intermediate ambient CLI selection when an owned account change rejects it.
  An unsigned owned send is an ordinary rejection; other conversations stay live.
- Engine reservation fences new sends, metadata/history/default reads, steering
  and responses for the captured instance. It drains active/idle actors, neutral
  metadata operations, pending checkpoint/provider starts and already detached
  cleanup, including deleted or retargeted owners. Account mutation then takes a
  separate cross-process exclusive lease; native children retain shared leases
  until their actual process/readers finish. Ending auth never replays a queue.
- The first complete run exposed a cleanup wait cycle in the unchanged project
  removal regression: a stale legacy model read is deliberately released only
  after project cleanup returns. Strict operation draining now applies to owned
  Codex credential scopes; legacy removed-reader results retain their incarnation
  fence. The original removal regression and all owned auth drain cases pass
  together after this fix. No deadline or assertion was weakened.
- The production factory lazily acquires the vault credential and private native
  home, then launches the real stdio adapter with literal token-sharing overrides.
  Idle renewal preserves the native conversation and never retries an uncertain
  history mutation. Physical shared-home scoping lets one account use A/B/A homes
  without mixing private caches or weakening existing layout receipts.
- Synthetic verified OAuth -> vault -> production factory -> stdio -> Engine
  checks cover model discovery, exact child environment/arguments, vault-only
  account identity, unsupported quota, marker turns and persisted native resume.
  CLI auth/history sentinels stay unchanged; credential/JWT/identity bytes are
  absent from wire logs, snapshots, SQLite and WAL. These peers do not contact a
  vendor or establish real ChatGPT sign-in/model access.
- The original development signature had no profile or entitlements and failed
  the real Data Protection Keychain acceptance probe. A project-only macOS
  development profile now reuses the existing certificate and registered Mac;
  no new certificate/device, App Store app or release was created. Packaging
  validates exact bundle/prefix/team/certificate/expiry/Mac ownership, embeds the
  validated bytes and signs only the main app with its own app identifier and
  authorized team entitlement. No custom sharing, sandbox or unrelated profile
  entitlements are granted. The provisioned app passes actual synthetic-item
  create/read/update/delete and removes that item without reading saved accounts.
  See Apple's [Keychain implementation requirements](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
- Hosted run `39810214461` at `619b198` still fails with signal 10 in run-history
  processing; all GUI checks skip. Its stack contains recursive context-event
  receive frames. Context scopes now unwrap iteratively before copying the
  mutable thread. Six regression cases preserve exact FIFO/completion and ignore
  foreign nested scopes without partial mutation. This reduces retained frames;
  the metadata-lookup crash cause and hosted resolution remain unproven.
- The native 16-workflow runner compiles locally without GUI execution; its
  signed offline launcher's initialize/metadata/descriptor checks also pass.
  The packaged development app passes strict/deep signature verification,
  bundled math rendering and the real Keychain probe. A consistent private
  schema-32 backup precedes reopening. The actual workspace migrates to 33 with
  integrity `ok`, all four threads/25 messages, and exactly unchanged canonical
  payload SHA-256 `1f595b380cbaac36002f066679ee510fdd052c7009c660bce32e0c626538a22a`.
- The final canonical `swift test --no-parallel` completes successfully with
  1333 declarations: 1323 pass and ten optional installed-provider checks skip.
  Core reports 1135 declarations across eight suites in 280.230 seconds; all 179
  native view/store declarations pass in 62.152 seconds, terminal six in 1.381
  seconds, and Markdown 13 in 0.130 seconds. Both new legacy cancellation/shutdown
  regressions and all owned auth scope/drain cases pass. All 42 Python harness,
  signing and offline-peer checks pass. The staged patch passes the secret scan.
- Actual native light/dark Settings acceptance adds two workflows, preserving all
  fourteen existing workflows. The result gate now requires at least sixteen
  passes with zero skips/failures. Local native GUI execution remains disabled;
  hosted results are recorded separately.

## 2026-10-22 — bounded reducer validation and owned Codex auth Core

- Hosted run `39804247499` at `d6ffea5` fails with signal 10/SIGBUS during
  provider-result history-ledger validation. All 14 GUI acceptance cases skip.
  The sanitized stack reaches checkpoint fingerprint encoding through
  `WorkspaceJournal.validate` under `WorkspaceDecision.makeGeneral`. The earlier
  acceptance-only extraction does not cover this later event. Stack pressure is
  a hypothesis, not a proven cause or a claim that the hosted crash is resolved.
- General reduction now returns before grouping reconciliation and full ledger
  validation. History, file-history, checkpoint restore and compound project
  registration have bounded non-inlined dispatch helpers. Existing validation,
  fingerprints, effect order, legacy aliases and exact ignored-event behavior
  remain. Local object inspection confirms final validation retains 1488 fixed
  bytes plus 28 metadata-sized slots across its two reducer frames; no full
  validator call remains inside the general reducer's 51920-byte/338-slot frame.
  Tests retain exact held ledgers and reject corrupted fingerprints for draft,
  pin and registration commands.
- Native owned-auth Core components implement discovered endpoints, PKCE and
  one-use callbacks, in-memory generated RSA/P-256 identity verification, bounded
  loopback HTTP, opaque profile generations, saved reconnect registrations and
  renewable credentials. Keychain queries use Data Protection, device-only
  after-first-unlock access and an interaction-disabled authentication context.
  Security tests replace the API entirely; no real Keychain call occurs.
- Exact-instance `flock` ownership covers reads, token rotation and publication.
  An atomic add-only initial Keychain claim binds the private lock root, including
  competing actors with different roots. Durable empty uncertainty receipts
  prevent retrying an old token after lost rotation, failed publication or a
  replaced directory. Proven pre-POST failures permit later explicit access.
  Received verified rotations are committed despite late cancellation; inactive
  accounts do not become active because cancellation raced completion.
- Pending issued registrations survive initial code expiry without a trusted
  identity, credential, sharing grant or active binding. Explicit reconnect must
  verify the issued registration's identity. Declined sharing preserves a
  different active account. Logout retains registrations, other profiles, CLI
  auth and shared history; unconfirmed remote revocation is stated explicitly.
- The auth controller holds an injected workspace lease through explicit browser
  handoff, exact callback/network cleanup, credential publication and joined
  apply/invalidation. Offline peers exercise lease order, coalescing/cancel,
  deadline/shutdown, declined sharing, apply failure, expired registration,
  uncertain reconnect and late-cancel publication. There is no browser or vendor
  call. Tests also exercise the real loopback listener and an independent local
  process holding the rotation lock.
- Home layout follows the pinned T3 shared/discovered entry set, refuses private
  auth redirects, preserves real model caches, retains displaced native locks
  with ownership proof and recovers interrupted moves. Initial positive checks
  expose Foundation's `/private/var` to `/var` normalization. Darwin physical
  resolution plus literal lexical validation preserves the no-follow walk;
  alias and missing-child regressions cover the corrected path. The launch value
  uses all eleven pinned overrides as literal argv pairs, fixed Responses/model
  endpoints, scrubbed ambient aliases and the token only in the child environment.
- Final focused `swift test --no-parallel` passes 73 declarations in 3.169 seconds,
  including the exact hosted-crash history case and the unchanged full-ledger
  validation assertions. The complete canonical run passes 1282 declarations:
  1272 pass and ten optional installed-provider checks skip. Core reports 1097
  declarations in 278.110 seconds; all 166 native view/store declarations pass in
  58.373 seconds, terminal six in 1.347 seconds and Markdown 13 in 0.151 seconds.
  Hosted crash resolution and actual GUI acceptance still require the next CI run.
- These components are not yet exposed by production Settings or the provider
  factory. Engine admission/drain, captured account generations, lazy runtime
  launch, signed-app Keychain acceptance, native account UI, profile transfer and
  installed owned authentication/model execution remain unfinished. No user
  account, actual CLI credential or workspace database is changed by this batch.

## 2026-10-22 — captured Codex runtime and complete managed package

- Installed CLI behavior stays the default. Explicit managed/custom executable
  and optional absolute home choices are saved privately and captured in new
  conversations, active inputs, FIFO queues and history reviews. Storage 32
  preserves legacy captures. Catalogs and metadata ownership include the exact
  runtime/home binding; applying a future preference drains old account, catalog
  and CLI-default reads without retargeting accepted inputs.
- The pinned complete Codex 0.156.1 distribution uses bounded HTTPS download,
  SHA-256, native gzip/TAR/PAX extraction, complete package inventory and atomic
  activation. Private-home version/CLI checks are separate from authentication.
  Leases protect running processes, metadata, admitted native writers and custom
  aliases into an installed package. Existing reviewed 0.163 history, steering
  and inferred-default capability guards remain unchanged.
- The first focused run compiles and executes 36 declarations. It finds one
  fixture inventory mismatch; all expected file-byte and mode checks pass. The
  relative-path helper now validates canonical path-component prefixes instead
  of assuming directory URL character spelling. Exact full-set equality remains
  and then passes. Fresh reads attempted during a held runtime Apply are refused;
  cancellation-resistant old results cannot republish account/catalog state.
- A serial run of the already-built test products completes all 1025 Core
  declarations (273.873 seconds), 166 native view/store declarations, six
  terminal declarations and 13 Markdown declarations. The native store reports
  one failed declaration: refreshing an active conversation passes its active
  run to the metadata factory, allowing catalog cleanup to close the fixture's
  active stream. The metadata launch copy now clears active run/request/queue
  state while retaining the original owned runtime/home configuration. The
  existing queue/steer regression covers both legacy and custom home captures.
  The final focused canonical run passes all 38 declarations: 29 Core in
  1.719 seconds and nine native view/store in 3.938 seconds.
- The exact public 127394863-byte macOS arm64 archive was independently downloaded
  and SHA-256 verified. A standalone probe linked to the production Core library
  installs that previously verified archive through the real extractor,
  inventory, verifier and activation paths; native app-server initialization,
  in-use removal rejection, close/drain/lease release and owned removal pass.
  A fresh credential-free home uses file-only auth storage and disabled analytics.
  No account, model, thread, turn or authentication RPC is sent. This proves the
  real package execution path, not the native network download path.
- The separate opt-in production URLSession download is interrupted to rebuild
  after the native-store regression. Its file continues growing, but a bounded
  process/network sample finds about 14 KB/s and substantial out-of-order TCP
  traffic, with idle CPU/queues and no writer/hash backlog. That check is not
  reported as passed, nor is its network impairment attributed to source code.
- Twenty-four offscreen narrow/wide, light/dark and LTR/RTL runtime settings
  captures pass geometry checks. Representative captures are inspected. Dark
  vibrant text is black in the offscreen export; these images do not prove actual
  composited Liquid Glass contrast. A real development-window capture remains
  separate evidence.
- Packaging the already-built product, strict/deep signature verification and
  native math-resource rendering pass. A consistent private backup precedes
  storage 31-to-32; integrity is `ok`, with the same four conversations, 25
  messages and canonical workspace payload hash after reopening.
- Hosted run `39795980219` at `694068c` completes all 1172 declarations without a
  crash report but fails the FIFO projection equality assertion. Its idle check
  can precede a post-run checkpoint journal commit. Commit `3465bf6` retains full
  equality and existing FIFO/model/history assertions, adds a deterministic held
  post-checkpoint case, and waits for that exact final run's observation. Both
  cases pass locally. Hosted run `39801874334` is pending.
- Final canonical `swift test --no-parallel` verification passes all 1210
  declarations: 1200 pass and ten optional installed-provider checks skip. Core
  reports 1025 declarations in 270.844 seconds; all 166 native view/store
  declarations (59.133 seconds), six terminal declarations (1.383 seconds) and
  13 Markdown declarations (0.128 seconds) pass. The normal packaging build then
  completes in 0.60 seconds; strict/deep signing and native math-resource checks
  pass again. Managed OAuth/accounts, broader provider controls and full T3
  parity remain unfinished.

## 2026-10-22 — managed Antigravity runtime and history acceptance stack

- Explicit native install/verify/update/cancel/remove actions keep account setup
  separate. Downloads stream into owned private staging, enforce the pinned size
  and SHA-256, and validate a bounded two-member ZIP before activation. Runtime
  leases pin old immutable versions across updates and guard removal, including
  custom aliases. Ownership-record replacement prevents publication. Storage 31
  captures managed versus external selection; legacy captures remain external.
- The first focused check passes 35 Core declarations plus four native view/store
  declarations; the optional real-artifact check skips. Both arguments of the
  existing history recall acceptance regression pass. The complete canonical
  `swift test --no-parallel` run passes 1170 declarations: 1161 pass and nine
  optional checks skip. Core reports 993 declarations (274.484 seconds), native
  view/store 158 (54.255 seconds), terminal six (1.357 seconds), and Markdown
  13 (0.142 seconds). After the small view/profile-root corrections, all 158
  native view/store declarations pass again (55.204 seconds).
- Hosted run `39790525202` at `cebae216` crashes with signal 10 in history
  acceptance while encoding a checkpoint fingerprint. Sanitized frames show one
  reducer invocation. Compiled local arm64 evidence finds 54,224 fixed bytes and
  383 metadata-sized stack slots in the original outer reducer. A separate
  acceptance entry path uses 560 fixed bytes and six slots before entering the
  unchanged acceptance logic. This is a measured reduction in that call chain;
  it does not establish the crash's cause or hosted resolution. Assertions and
  deadlines remain unchanged.
- The explicit real-artifact check downloads the exact 111456962-byte macOS
  arm64 release and passes its pinned SHA-256, but initially fails during
  extraction before launching the native server. Offline fixture success is not
  claimed as real installation success. The compatibility fault is investigated
  against that verified archive. libz produced additional output without
  consuming new input at a valid chunk boundary. The reader now accepts either
  input or output progress and advances on an empty-input/no-output buffer
  boundary; exact compressed/decoded lengths, CRC and stream-end checks remain.
  The production real-artifact check then passes in 14.052 seconds: download,
  extraction, native initialize-only verification, activation, lease acquisition
  and owned removal all complete. No authentication or model request is sent.
  The final focus passes 35 Core declarations (15.347 seconds, including this
  actual check) and four native view/store declarations (3.426 seconds).
- The offscreen harness emits 24 narrow/wide, light/dark and LTR/RTL captures.
  An opaque native window background avoids transparent exported PNGs;
  representative narrow captures are inspected for wrapping and action placement.
  Vibrant text and composited Liquid Glass contrast still require actual window
  captures; offscreen dark-mode pixels are not claimed as contrast acceptance.
- The two synthetic decompression-boundary regressions and all ten existing
  extractor declarations pass (12 declarations, 0.099 seconds); truncated input
  remains rejected and owned partial output is removed. These were added after
  the full-suite run above, so that earlier count does not include them.
- Packaging completes in 0.67 seconds. Strict/deep signature verification and
  native math-resource rendering pass. The development app reopens and its real
  window is captured. A consistent private backup precedes storage 30-to-31;
  integrity remains `ok`, with the same four conversations, 25 messages and
  canonical workspace payload hash. No installed provider sign-in is performed.
  Hosted verification of the pushed changes remains pending.

## 2026-10-22 — native Antigravity ACP and explicit account setup

- Added a dedicated native adapter for the pinned flat ACP dialect and paired
  server/harness. Native prompt responses finish turns; admission, idle status
  and locally generated IDs cannot substitute for terminal proof. Models,
  account generations and modes are captured independently of future choices.
- Explicit account setup stages isolated profiles and Keychain credentials under
  an Engine lease. Google URLs remain transient and open only from the explicit
  native action. Initialization-only runtime checks do not claim account access.
  Failed or uncertain logout downgrades the exact saved generation rather than
  permitting automatic repeat. Credentials and authorization URLs are excluded
  from workspace persistence.
- Offline peers cover native framing, process ownership, setup, resume, questions,
  permissions, delegated files and Engine integration. Synthetic account sessions
  and private temporary registries keep these checks independent of real Google
  accounts and the user's Keychain. Installed execution, managed installation,
  usage, skills/MCP and broader recovery remain unfinished.
- All 57 focused declarations pass: nine native view/store declarations
  (1.059 seconds) and 48 Core declarations (0.674 seconds), including existing
  grouping and OpenCode stop-observation regressions. These include 49 new
  Antigravity declarations. The incremental build completes in 6.12 seconds.
  Real pipes verify cancelled queued notifications send no bytes, already-started
  frames finish intact, and the next request stays usable. A gated native probe
  verifies shutdown waits for a process whose metadata RPC already returned.
  Account leases reject new starts atomically and drain held baseline capture.
- The complete canonical `swift test --no-parallel` run passes 1131 declarations:
  1123 pass and eight optional installed-provider checks skip. Core reports 958
  declarations (270.968 seconds); all 154 native view/store declarations
  (51.536 seconds), six terminal declarations (1.333 seconds) and 13 Markdown
  declarations (0.127 seconds) pass. An earlier default-parallel invocation
  produced widespread timing failures under excess process load; it is not the
  documented/CI runner mode and is not claimed as passing. Assertions, deadlines
  and test coverage were not relaxed.
- Packaging completes in 0.58 seconds. Strict/deep signature verification and
  native math-resource rendering pass. The development app reopens and its real
  window is captured. A consistent private backup precedes storage 29-to-30;
  integrity remains `ok`, with the same three conversations, 25 messages and
  canonical workspace payload hash. Hosted native GUI acceptance remains pending.
- An opt-in offscreen render of the native question, permission and account views
  produces 24 narrow/wide, light/dark and left-to-right/right-to-left captures;
  its declaration passes in 0.866 seconds. Representative captures were inspected
  for wrapping and control placement. These do not establish composited glass
  contrast or installed-provider interaction acceptance.
- Hosted production run `39784118056` reports assertion failures in OpenCode's
  synthetic stop observation and grouped checkout selection. The exact same
  production Core code passes in `39783333814`; the failure is not a crash.
  OpenCode's fixture now retains its exact request owner and observes the native
  stop callback within the existing budget. The grouping test waits for thread
  creation's selection continuation before issuing the next selection. Existing
  assertions, coverage and deadlines are preserved.

## 2026-10-22 — history status accessibility identity

- Hosted run `39777011810` at `3645f869` finishes all 14 native GUI scenarios:
  13 pass, one fails and none skip (1609.096 seconds). Files/editor/inspector,
  checkpoint restore, model/reasoning/account controls, pull-request checkout,
  pull-request creation/inspection and steering all pass. Production remains
  green at that immutable head with all 1034 test declarations completed.
- The sole failure is the history workflow's status lookup. Its final native
  accessibility artifact contains both `Conversation rewound` and the recalled
  input, but the ancestor operation identifier replaces the leaf status ID.
  Wire evidence records one fork, one revert and three prompts; no history
  mutation was replayed. Removing the unused ancestor identifier retains the
  semantic status and action identifiers. Assertions and deadlines are unchanged.
- All 60 focused history declarations pass locally after the change: six native
  view/store declarations (1.305 seconds) and 54 Core declarations
  (15.963 seconds). The build finishes in 3.89 seconds. These checks do not
  replace the next hosted native accessibility run, which remains pending.

## 2026-10-22 — initial native Muse Session Protocol

- Added a dedicated native MSP transport and session actor using the pinned
  1.4.6 SDK contract. The bounded stdio connection separates RPC IDs, command
  IDs and server presentation requests, scrubs the inherited Meta API key,
  disables automatic updates and never retries an uncertain write. A metadata
  process has shell/write tools disabled and does not establish login or access.
- Captured model, effort and launch authority survive FIFO execution, SQLite
  reopen and journal replay. Storage 29 fences the new fields while preserving
  prior Pi and other conversations. Before a prompt, session read-back must
  prove the workspace, selected model and required permission profile. Old
  hosts lacking profile proof are refused; a model selected explicitly or
  observed during resume is never mislabeled as the native default.
- Actual admission and owned native turn completion have separate identities.
  ACK, idle and a reused view cursor cannot complete a run. Revisioned native
  snapshots replace partial text/tool output; retained background items keep
  their original run. Stop targets the native turn and waits for its terminal.
  Uncertain preparation, gaps, EOF and overflow fail closed without resending.
- The initial focused run passed 43 declarations: 38 Core (3.134 seconds,
  including the existing creation regression) and five native view/store
  declarations (2.734 seconds). Real offline stdio peers exercise the production
  factory, Engine FIFO, policy replacement, exact Stop and durable reopen.
  Compatibility effort descriptions retain their fallback provenance even when
  native per-tier descriptive text is also present.
- The initial complete local run passed 1076 declarations: 1068 passed and eight
  optional installed-provider checks skipped. Core reports 910 declarations
  (264.069 seconds), all 147 native view/store declarations pass (51.253 seconds),
  and all six terminal and 13 Markdown declarations pass. This run precedes the
  lifecycle corrections below and does not stand in for their validation.
- Review found and corrected three lifecycle gaps: shared response effects could
  dismiss a Muse row on ACK; pruning could let an absent old run's waiter close
  a healthy successor; and direct RPC catches could overtake already-queued native
  terminal proof. Muse rows now await native settlement, callback ownership must
  still exist, and turn/Stop responses follow the ordered stream. Stop registers
  its terminal waiter before dispatch and joins owned command tasks on close.
  Real stdio regressions cover terminal-before-held Stop ACK/error, pruning,
  late replies and ACK-before-native question/approval settlement. Deterministic
  transport tests pause consumption and verify notification-before-failure order,
  exact-once local failure callbacks and zero writes for rejected requests.
- After those fixes, all 49 focused declarations pass: 44 Core (4.894 seconds,
  including the existing creation regression) and five native view/store
  declarations (2.603 seconds).
- The final complete local rerun is green: 1082 declarations, 1074 passed and
  eight optional installed-provider checks skipped. Core reports 916 declarations
  (265.823 seconds); all 147 native view/store declarations (51.415 seconds), six
  terminal declarations (1.373 seconds) and 13 Markdown declarations
  (0.139 seconds) pass. This includes all lifecycle corrections above.
- Native approval choices retain their exact labels, scopes and rule previews;
  questions retain offered order, selections, separate notes and UTF-16 limits.
  Rendering never submits or cancels. Sixteen narrow/wide, light/dark and
  left-to-right/right-to-left offscreen layout combinations passed geometry
  checks. Full offered approval labels wrap separately from native action
  buttons. Offscreen glass/vibrant text caching is not reliable evidence of
  dark contrast; actual composited dialog appearance remains unverified.
- Packaging, strict/deep signature verification and native math-resource
  rendering pass. The development app reopened and its actual window was
  captured. A consistent private backup preceded the 28-to-29 migration;
  SQLite integrity and canonical workspace content remain unchanged, with
  three conversations and 25 messages.
- These checks use synthetic peers only. No installed Muse process, login,
  model turn or provider setup was performed. Steering, active-session adoption,
  history/gap recovery, MCP/configuration, skills, usage and full T3 parity remain
  unfinished. Exact owned-parent drain does not prove OS descendant exit.

## 2026-10-22 — native Pi RPC and atomic creation regression

- Added a dedicated Pi JSONL actor, typed durable provider/model/thinking captures,
  native confirm/select/input/editor controls and captured tool-approval policy.
  Native session-file resume validates an existing regular header and workspace
  before switching. Storage 28 preserves the new captures through queue/reopen
  and journal replay; older provider conversations retain their settings.
- Real stdio peers exercise command correlation, exact Unicode/tool projection,
  lost replies, lifecycle/compaction, cancellation, extension expiry and native
  abort. Only settled-plus-idle evidence releases a turn; ACK and `agent_end`
  alone do not. Run-owned waiter retirement prevents a completed run's deadlines
  or Stop replies from terminating its successor. Unresolved pre-start Stop
  retires the runtime rather than claiming a confirmed native interruption.
- The production factory-to-Engine fixture verifies captured FIFO settings,
  policy-driven process replacement, native session continuation, actual abort,
  source-file preservation and durable restart without resending. These are
  offline peers, not installed Pi or model-access verification. No Pi login,
  installation or vendor turn was performed. Steering, native history changes,
  broader extension behavior, setup/auth and usage remain unfinished.
- All 29 focused declarations passed: 26 Core declarations (3.193 seconds) and
  three native view/store declarations (0.176 seconds). A stale thinking choice
  now receives a normal rejected command; the engine stays healthy and accepts
  a subsequent valid default selection. Native dialog rendering preserves empty
  values/prefill and never answers merely because the view appeared.
- The isolated managed-project registration test reproducibly exited with
  signal 10 before its dispatch returned. Removing the compound creation path's
  recursive entry into the large reducer made that same test pass, including
  all journal/rebuild/atomicity assertions (0.017 seconds). Registration, clone
  and standalone creation now share the original insertion guards and runtime
  normalization. Validation/effect ordering remains unchanged. Binary inspection
  shows substantial fixed and dynamic stack allocation; the later hosted stack
  below corroborates excessive stack use from the nested reducer/validation path.
- The subsequent immutable diagnostic run `39775604839` at `40d1ca54` (before
  the creation fix) captured a sanitized report after 20 seconds and five scans.
  Its faulting thread shows `___chkstk_darwin`, collection mapping, conversation
  history validation, journal validation and two nested reducer invocations.
  `SIGBUS`/`KERN_PROTECTION_FAILURE` during stack probing directly corroborates
  the recursive path's stack pressure. The native GUI job skipped all 14 cases;
  this earlier run does not verify the later fix. The report fingerprint is
  `6568cf9d61f2dcbeae6a317f67ebc641c8c2ab7dca3013ce1660a0c08b898804`.
- The complete local run reached its end: 1034 declarations across 873 Core,
  142 native view/store, six terminal and 13 Markdown tests. There was one
  failing Pi fixture observation and eight optional installed-provider skips;
  all other declarations passed. The failure read the peer's response log before
  the peer consumed the completed pipe write. The test now waits for a complete
  received frame and observed dismissal under its unchanged deadline, and ignores
  a partially appended final log record. All 29 Pi declarations then passed again
  (Core 3.218 seconds, native 0.187 seconds). This is not a claim that the earlier
  full run was green; final hosted verification remains pending.
- Rebuilt packaging, strict/deep signature verification and native math-resource
  rendering passed. The development app reopened and a fresh window screenshot
  was captured. A private consistent backup preceded migration from 27 to 28;
  SQLite integrity and canonical workspace content remain unchanged, with three
  conversations and 25 messages.
- The final complete local run for code head `3645f869` is green: 1034 test
  declarations, 1026 passed and eight optional installed-provider checks skipped.
  Core reports 873 declarations (263.297 seconds), all 142 native view/store
  tests pass (49.324 seconds), and all six terminal and 13 Markdown tests pass.
  This rerun includes the corrected peer observation and the creation fix.
- Hosted run `39777011810` at the same immutable code head passes production:
  all 1034 declarations finish (752.554 seconds after a 272.29-second build),
  followed by packaging/signature/resource checks. The formerly crashing case
  reaches all 18 fixed phases through dispatch, rebuild and cleanup. Its separate
  14-scenario native GUI job is still running; production success does not stand
  in for that result.

## 2026-10-22 — delayed hosted crash reports and phase evidence

- Exact `2ec0a087`, run `39772129599`, reproduced the production test process's
  Darwin signal 10 after a successful build. There was no assertion or completed
  summary; the dependent native GUI job again executed zero of 14 scenarios.
  Its collector ran less than a second after the failure and captured no report.
- Diagnostic collection now waits at most 30 seconds, in intervals no longer
  than five seconds. Bounded recent files are filtered by their exact process
  payload rather than filename prefix. A fixed-key summary records aggregate
  rejection counts even when no stack is available. Existing input, stack,
  privacy and total-output bounds remain; raw paths and errors are not exported.
- Fixed direct-stderr markers identify phases of the repeatedly last-buffered
  managed-project registration test. Removing those markers restores its
  previous source exactly; every assertion and deadline remains. Markers do not
  establish a cause or make an interrupted test pass.
- The subsequent local working-tree run also exited with signal 10. Its markers
  reached `before-dispatch` but not `after-dispatch`, narrowing the interrupted
  interval to the awaited atomic registration command. This is not an immutable
  baseline result or a stack identifying the underlying fault.
- All 33 Python configuration/peer/diagnostic checks passed (1.967 seconds).
  Delayed capture and phase attribution still require the next hosted run.

## 2026-10-22 — native OpenCode 1 and Grok ACP flows

- Added a separate native OpenCode 1 HTTP/SSE conversation actor, preserving its
  server-generated sessions, authored-message/assistant-parent ownership, native
  idle completion, captured model/variant/agent/rules, questions and scoped
  permissions. A real TCP fixture exercises the production factory, owned
  process, URLSession, SSE, Engine FIFO and SQLite; it is not an installed server.
- Added a named Grok profile to both ACP adapters, prompt-correlated xAI
  completion/background activity, captured Ask/Auto/Always approve launch policy,
  existing noninteractive sign-in, cancellation metadata and typed questions with
  choices and notes in one durable response. Initialize-only status does not
  authenticate. Storage 27 fences the new profile/response semantics; migration
  from both 25 and 26 preserves existing native OpenCode and ACP conversations.
- The serialized local suite executed 1003 test declarations: 995 passed and
  eight optional installed-provider checks were skipped. Core reports 845
  declarations including those skips (258.375 seconds); all 139 native view/store
  tests (49.144 seconds), six terminal tests and 13 Markdown tests passed.
- Subsequent source review found that a delta could reveal an ignored/synthetic
  OpenCode part after its hidden snapshot. Projection now retains suppression
  through deltas, while an authoritative visible snapshot can clear it.
  A separate review corrected Default Model: v1 now omits model/variant and lets
  the native server resolve agent/history/config defaults, rather than guessing
  from per-provider catalog defaults. Grok v2 review also fixed raw RPC rejection
  text reaching durable errors and native idle bypassing unfinished background
  tasks. Real stdio regressions exercise both paths.
- After all four corrections, expanded OpenCode/ACP checks executed 120 test
  declarations: 115 passed and five optional installed checks were skipped.
  Core reports 112 including skips (6.546 seconds); all eight selected native
  view/store tests passed (0.299 seconds). Separate ignored/synthetic cases,
  captured default versus future-header selection, native question controls,
  Grok v1/v2/fallback and the real TCP Engine test are included. This final
  targeted run covers the corrections made after the full-suite result above.
- Final packaging, strict/deep signatures and native math-resource rendering
  passed. The rebuilt development app reopened and a fresh window screenshot
  was captured. A private consistent backup preceded the 26-to-27 migration;
  SQLite integrity and canonical workspace content remain unchanged, with
  three conversations and 25 messages.
- These checks use offline peers. No installed Grok or OpenCode 1 turn was sent;
  the installed OpenCode CLI is 2.1.2. Exact owned-parent shutdown is not proof of
  OS descendant exit. Native authentication/setup, broader controls/history,
  usage, other providers and complete T3 parity remain unfinished. Hosted GUI
  acceptance remains pending.

## 2026-10-22 — bounded hosted test crash diagnostics

- Exact head `d33e7c7`, run `39766284863`, built successfully but its production
  Swift test process exited with Darwin signal 10 (`SIGBUS`). No test assertion,
  completed test summary, crash stack or uploaded report established a cause.
  Buffered output cannot identify the crashing test from its last printed name.
  Packaging did not run and the dependent 14-scenario GUI job was skipped.
- The production workflow now records its test-start time and, only after test
  failure, attempts to export recent allowlisted test-helper crash stacks. Reports
  retain bounded exception enums, termination code, relative code offsets and
  symbol/image identity. Raw reports, absolute addresses, registers, environment,
  assertion payloads, private paths and memory are excluded. Both capture and
  upload are best effort and cannot change the original test outcome.
- Synthetic parsing/privacy checks cover two-object Apple IPS, compact timezones,
  malformed/stale/foreign/symlink inputs, stable fault-stack fingerprinting and
  input/output bounds. All 28 Python harness/configuration checks passed in
  2.110 seconds. This change adds diagnostics without retries, deadline changes,
  test removal or an inferred fix for the unlocalized crash.
- Exact diagnostic head `aa22177d`, run `39769282901`, reproduced Darwin
  signal 10 before packaging. Crash collection ran but returned zero reports;
  this does not establish whether report arrival, matching or another condition
  prevented capture. No stack or assertion localized the cause. The dependent
  native GUI job was skipped, so this run executed zero of its 14 scenarios.

## 2026-10-22 — native OpenCode 2 conversations

- Added a dedicated native HTTP/SSE conversation adapter, durable captured
  model/variant/agent settings, advertised menu choices, tool/text projection,
  typed permission scopes/forms and exact Stop routing. Storage 26 preserves
  these choices through queued turns, journal replay and restart, while existing
  OpenCode ACP conversations keep their transport. Native v1 chat, authentication,
  history, steering, reconciliation and complete provider parity remain open.
- Synthetic actor coverage separates HTTP admission, owned delivered input,
  execution start, step completion and terminal evidence. It covers stale/late
  responses, lost replies with conclusive native evidence, Stop during preparation
  and before admission, malformed ownership, child settlement after parent failure,
  autonomous Stop and separate retained-run projection budgets. Unknown delivery
  pauses the queue and never causes automatic replay.
- The real TCP Engine integration passed in 0.225 seconds through the default
  production factory, owned executable, URLSession, SSE, reducer and SQLite
  journal. It verifies exact queued model/variant/agent/permission capture,
  authoritative text/tool replacement, execution-only FIFO advancement, inbox
  cancellation plus interruption, concurrent shutdown, stdin EOF and exact owned
  PID disappearance. This executable is a private synthetic peer; no installed
  OpenCode server, model, provider authentication or account was used.
- Its first run rejected the fixture directory before creating a session:
  Foundation retained `/var/...`, while Python resolved the same working directory
  to `/private/var/...`. The peer now verifies the Foundation-provided directory
  with `samefile` before readiness, then retains strict literal protocol equality.
  Assertions and deadlines were unchanged. Failure diagnostics retain only bounded
  synthetic state and semantic wire fields, excluding credentials and raw headers.
- The final serialized full suite executed 961 declarations: 953 passed and
  eight optional installed-provider checks were skipped. Core reports 806
  declarations including those skips (256.033 seconds); all 136 native view/store
  tests (48.700 seconds), six terminal tests and 13 Markdown tests passed.
  This run includes the final unknown-admission Stop regression and the real TCP
  Engine integration (0.224 seconds), rather than relying on earlier synthetic
  or component results for the final implementation.
- Packaging, strict/deep signatures and bundled native math rendering passed.
  The rebuilt development bundle reopened successfully; a fresh native-window
  screenshot was captured. A consistent private backup preceded storage 25-to-26
  migration. SQLite integrity and canonical workspace content remain unchanged:
  three conversations and 25 messages. No installed-provider turn was sent.

## 2026-10-22 — native GUI workflow follow-through

- Exact head `8e37db3` passed hosted production (907 test declarations plus
  packaging, signatures and resource verification) in run `39759690418`. Its
  complete native suite executed all 14 scenarios: ten passed, four failed and
  zero skipped in 1658.404 seconds. The full checkpoint restore workflow now
  passes, including cancel, actual Git replacement, preserved conversation/draft
  and source state, restart and restore audit. Steering and Files/editor also pass.
- Two remaining failures were existing harness assumptions: the email Toggle is
  a native Switch, and indexed history-query handles repeatedly resolved to the
  first row. Exact identifiers now locate the Toggle independently of its native
  type; history uses stable element-bound handles and one exact direct prompt
  child, rejects ambiguity, and retains distinct-run/action/wire assertions.
- The other two failed farther into pull-request workflows. Exact hosted AX
  attachments expose description paragraphs as siblings carrying their own
  identifier, so the assertion now matches those exact paragraph values within
  the sheet. After checkout restart, foreground activation preceded saved sidebar
  selection; the existing ten-second blank-composer readiness check now runs
  before asserting the exact selected target. Both original text assertions and
  their deadlines remain. No product change was inferred from those observations.
- The whole native job budget is 45 minutes, providing room for all completed
  workflow paths and artifacts after the earlier `9b100dd` job used 29m59s with
  five paths still failing early. All 14 scenarios, individual deadlines, wire and
  state checks, and the zero-skip gate remain unchanged. Main/release runs are not
  cancelled and no retry was added.
- All 19 Python harness/configuration checks passed in 2.164 seconds. The final
  native GUI runner and immutable helper compiled and passed offline checks.
  No GUI automation test was run locally. These are compile/component checks;
  the newly pushed head still requires its own complete hosted GUI result.

## 2026-10-22 — native operation control follow-through

- Removed three additional unused outer identifiers from pull-request creation
  and checkout operation cards. These had the same nonsemantic-container pattern
  as the observed form/history collision; status, inspection, acknowledgement,
  result and Open Conversation controls keep their own identifiers. This is a
  source-audit follow-up, not a newly observed hosted failure.
- History/restore GUI checks accept the same exact success text in either native
  AX label or value. Destructive-review assertions still require both loss
  warnings and the exact checkout path. All 14 scenarios, wire/state assertions,
  original deadlines and the zero-skip result gate remain unchanged.
- After these view changes, all 130 native view/store tests passed again in
  48.475 seconds. Nineteen Python harness checks and native GUI runner/helper
  compilation passed. Packaging, strict/deep signatures and bundled math passed;
  canonical workspace content and integrity remain unchanged.
- Exact head `9b100dd` passed hosted production in run `39753904177`. Its native
  14-scenario job was still executing when this follow-up was recorded. The
  preceding `e09a5ce` run executed all 14 with eight passes, six failures and zero
  skips (1424.069 seconds), reproducing the same old control/text failures.
  Neither those results nor component tests establish hosted success for these
  subsequent changes; the next pushed head requires its own full GUI evidence.

## 2026-10-22 — native OpenCode HTTP/SSE foundation

- Added native Swift generation/version types, runtime-only header credentials,
  an owned loopback server, bounded URLSession networking, generation-specific
  metadata projections and a volatile SSE connection. The existing ACP provider,
  composer choices and storage version 25 are unchanged. This foundation does
  not yet implement native OpenCode HTTP chat, approvals, steering or history;
  [the integration boundary](OPENCODE_HTTP.md) records the remaining full scope.
- HTTP identity rejects HTML 200, unsupported/wrong generations and mismatched
  owned v2 PIDs. Authentication failure does not select another generation.
  Catalogs retain exact advertised wire model/variant/agent IDs and workspace
  scope while discarding raw headers, settings, system prompts and unknown fields.
  Metadata cancellation joins only owned reads and preserves shared event I/O.
- Networking rejects redirects and URL credentials, uses ephemeral state and
  incrementally bounds bodies, headers and stream buffers. SSE preserves split
  Unicode, CR/LF, comments, multiline data, empty/reset IDs and large single-line
  tool snapshots. An incomplete frame cannot advance its committed cursor.
  Heartbeat bytes refresh a 45-second watchdog; EOF, silence, malformed framing
  and overflow require reconciliation instead of completing or replaying a turn.
- Server fixtures cover exact generation-specific argv, fresh credentials,
  coalesced start, independent waiter cancellation, readiness rejection, deadlines,
  startup floods, continued post-ready log drainage and repeated/concurrent close.
  Process output can be bounded explicitly. Exact-PID termination replaces
  Foundation's group-targeting operation; nonblocking output readers can be
  closed and joined without signaling a descendant retaining inherited writers.
  The inherited-pipe test failed with the previous termination call and passed
  after targeting the positive owned PID. It also verifies the descendant remains
  alive until its own test-owned release.
- Testing exposed a synchronous stream-destructor deadlock on rejected/cancelled
  event opening. Teardown now retains the unreturned stream until after releasing
  the state lock. Native URLProtocol fixtures explicitly supply JSON MIME types
  for early body-limit checks and await their actual stop callbacks before
  asserting counts. No retry, timeout expansion or coverage reduction was added.
- All 60 focused checks passed in 4.705 seconds. The subsequent serialized full
  suite executed 906 declarations: 898 passed and eight optional installed checks
  were skipped. Core reports 757 declarations including those skips (254.826
  seconds); native views/stores 130 (48.385 seconds), terminal six and Markdown 13
  all passed. The later large-single-line framing regression is included in that
  full run.
- A separately added real TCP integration passed in 0.240 seconds. Its private
  Python server exercised the actual native owner, HTTP client, metadata reader
  and SSE connection together: ephemeral header authentication, owned PID/version,
  directory/model/variant selection, gated fragmented Unicode after metadata
  closure, independent stream/client lifetimes, real 401 and graceful server EOF.
  This is a synthetic server, not an installed OpenCode HTTP/provider result.
- Installed Codex and Claude handshake/model-discovery checks also passed (two
  tests, 1.816 seconds) after the common process changes; neither sent a model
  turn. Nineteen Python harness checks passed. Native GUI runner compilation,
  immutable helper checks, packaging, strict/deep signatures and math resources
  passed. Canonical user workspace content and SQLite integrity stayed unchanged
  (three conversations, 25 messages). No installed OpenCode server, authentication
  or database migration was performed for this work.

## 2026-10-22 — native workflow accessibility and model summary repairs

- Hosted run `39746111640` reached all 14 GUI scenarios (eight passed, six
  failed, zero skipped). Its attachments showed nonsemantic container identifiers
  replacing descendant Run History, history-review, checkpoint and pull-request
  control identifiers. Those container identifiers are removed; input, action,
  status, scroll-view and explicit history-row identifiers remain independent.
- The provider Menu now uses one native text title containing provider, selected
  advertised model and captured reasoning effort. Catalog changes update that
  title and its accessibility value without changing future configuration or an
  active run's separately captured settings. A regression hosts the full actual
  Menu and checks the backing AppKit title, bounded geometry and live refresh.
- GUI assertions now inspect the model menu's exposed value and accept exact
  transcript text in either AX label or value. They still require one authored
  row, absence of the queued prompt and the original wire/state evidence. Run
  History waits for its records scroll view and unique innermost Done owner.
  All 14 scenario methods and the zero-skip result gate remain unchanged.
- `swift test --no-parallel --filter CoincideUITests` passed all 130 native
  view/store tests in 48.662 seconds, including the new complete-menu regression.
  The initial local invocation used Swift's parallel default and exposed six
  selection assertions across three existing store tests; verification uses the
  repository's existing serialized CI invocation rather than adding retries.
  Nineteen Python harness/fixture checks also passed. The native GUI runner and
  signed immutable helper compiled and passed initialize/GitHub/descriptor checks
  without executing GUI tests locally.
- Native Cua inspection of the rebuilt development bundle confirmed the actual
  menu exposes `Provider and model` with the current `Codex` value. This read
  changed no conversation or provider settings. Offscreen AppKit backing controls
  do not directly expose SwiftUI's semantic AX overrides, so the refreshed-value
  assertion remains part of hosted GUI execution. Packaging, strict/deep
  signatures and bundled math rendering passed. SQLite integrity and canonical
  content stayed unchanged (three conversations, 25 messages).
- These are repairs with native component evidence, not a successful rerun of
  all 14 hosted GUI workflows. Full T3 functionality and provider parity remain
  incomplete; the preceding integration suite and installed-provider limitations
  below still apply.

## 2026-10-22 — native Cursor and Copilot ACP integrations

- Explicit vendor profiles are captured with each invocation, conversation and
  queued input. Settings adds native setup and initialize-only connection checks
  on separate owned transports. Observations stay in memory, require the exact
  saved configuration and drain replaced/cancelled work at shutdown. They do not
  authenticate, send a prompt or prove model entitlement.
- Cursor questions retain exact option IDs and multiple selections. Plans use
  explicit Accept/Decline; Skip, Stop, remote cancellation and reused wire IDs
  cannot accidentally answer an earlier request. Known payloads are bounded and
  unknown fields discarded. Todo notifications merge/replace; task/image events
  display activity without executing client tools or reading supplied paths.
- Copilot negotiates its documented raw-event metadata. Exact raw/chunk pairing,
  task/agent identity and original-run attribution keep child text/reasoning/tools
  separate from root output. Background launcher completion does not finish the
  child. Old children can finish while another run or baseline capture is active;
  invalid runtime/session/owner updates are discarded and replay retains ownership.
  Both ACP versions and same-transport v1 adoption retain the vendor flavor.
  Experimental v2 also opens a distinct owner before agent-initiated output and
  closes that exact activity. Its children retain it after idle, and an old
  activity ending during a new user's configuration cannot consume the unsent
  user's owner. Both normal and held-configuration sequences are covered.
- Review found pre-dispatch ownership and cancellation bugs: configuration replies
  can resume before preceding notifications drain, and Stop can arrive during a
  held configuration RPC. Both adapters now drain pre-dispatch events before
  assigning Copilot ownership; v1 also rechecks Stop before writing a prompt.
  Bounded fixtures verify resumed-running/idle transitions and zero prompts after
  cancellation, along with malformed child IDs failing without a process trap.
- The final full integration suite executed 844 Swift test declarations: 836
  passed and eight optional installed-provider checks were skipped. The core
  target reports 696 declarations including those skips (252.280 seconds); all
  129 native view/store (48.588 seconds), six terminal and 13 Markdown tests passed.
  The full run includes late configuration cancellation and both autonomous-wake
  regressions. All 89 focused protocol/view/store/history tests also passed before
  that final wake regression was added. Nineteen Python fixture/configuration
  checks passed.
- The actual installed Cursor CLI (`2026.10.19-6bbf2c4`) completed initialization,
  session creation and model discovery; the independent metadata-only test passed
  in 7.057 seconds. Its implementation-name field is optional and absent. A real
  marker turn returned `Upgrade your plan to continue` instead of the marker:
  successful model execution remains blocked by that provider plan, and no more
  model calls were attempted after identifying it. Copilot is not installed here;
  its evidence is protocol fixtures, not a live authenticated turn.
- Native Cua inspection of the packaged application verified both setup sheets,
  literal commands, existing-login guidance, experimental-v2 default off and
  visible Save/Cancel controls. Both sheets were cancelled without saving. Eight
  narrow/wide/light/dark component captures and geometry assertions verified
  bounded scrolling/action placement; offscreen PNGs do not establish WindowServer
  glass/vibrancy or a complete GUI interaction workflow.
- Packaging, strict/deep signatures and native math resources passed. The existing
  database was privately backed up before opening storage 25; SQLite integrity
  passed and canonical workspace content stayed identical (three conversations,
  25 messages). Staged/outgoing secret scans accompany the pushed implementation.
  This does not complete native authentication, full vendor SDK/control/history
  parity, installed Copilot verification or the full T3 Code port.
- The preceding account commit `a3ad449` completed hosted run `39746111640`:
  production passed its 792-declaration test run plus packaging/resources. Native GUI execution
  ran all 14 scenarios with eight passes, six failures and zero skips in 1454.225
  seconds. The immutable helper passed the five formerly blocked initialize
  preflights, so those workflows now reach actual app/provider interaction.
  Remaining failures concern Run History sheet opening, refreshed model labeling,
  PR creation/checkout button lookup and literal steering transcript lookup.
  Attachment inspection confirms container accessibility IDs overwriting semantic
  history/PR controls, a native Menu label losing its model/effort content, and a
  steering assertion checking only AX labels although the exact text is in AX
  values. Wire and state artifacts prove the single steering request was sent.
  These GUI repairs remain separate work; no full GUI success is claimed.

## 2026-10-22 — native Codex account and allowance status

- Settings now reads the existing CLI account/plan and allowance windows on an
  independently owned metadata connection. Email is hidden until explicitly
  revealed. Account details, opaque routing IDs and usage observations never
  enter workspace persistence or conversation events. This implements status,
  not native sign-in/logout, managed account profiles or usage history.
- The account reader checks identity before and after usage, correlates backend
  account IDs when supplied and rejects changing identities. The installed CLI
  emits an account-change notice during normal startup; one discarded observation
  can retry on the same connection inside the original 30-second deadline.
  Repeated changes still fail. Limits replies and sparse notifications are
  processed in wire order, preserving unrelated buckets and omitted window fields.
  Unsupported usage clears bars; failed reads may retain explicitly stale bars
  only for the same identity, without retaining quota authorization.
- All 792 Swift tests passed: 651 core (248.809 seconds), 122 native view/store
  (46.647 seconds), six terminal and 13 Markdown. The 29 focused account tests
  also passed after final presentation changes. Coverage includes startup notices,
  account switches, sparse updates, finite budgets, malformed/private responses,
  cancellation during reads and during both successful/failed metadata cleanup,
  exact session retirement, stale native-store ownership and SQLite non-persistence.
- A real installed-Codex status read passed in 3.818 seconds with a fresh usage
  bucket. It sent no model turn, login/logout or configuration mutation, and
  printed no email, account ID or credentials. Packaging, strict/deep signatures
  and native math resource verification passed. Cua captures of the actual
  Settings window showed the hidden-email account and readable allowance bar.
  Existing storage-24 workspace integrity and canonical content remained unchanged
  (three conversations, 25 messages).
- Nineteen Python fixture/configuration checks passed. The existing hosted model
  workflow now checks the synthetic account/plan, hidden email, remaining allowance
  and an explicitly read-only refresh before preserving its original restart
  assertions. All 14 scenario methods remain. The runner compiled and the actual
  embedded immutable helper passed initialize/GitHub and descriptor validation
  without launching GUI tests locally. Hosted execution remains pending below.
- Hosted run `39739331188` at `01fb90f` passed production but executed 14 GUI
  scenarios with eight passes, six failures and zero skips. Five provider
  preflights still used sandbox-created executable fixtures and failed with
  `Process.run` EPERM. The PR sheet inherited its outer accessibility ID onto
  child controls. Both source/harness fixes are in `fb45a729`.
- Hosted run `39742007509` at `fb45a729` then hit GitHub's 20-minute production
  job deadline. Compilation passed in 768.58 seconds, but tests had only about
  380 seconds before cutoff; the previous successful hosted suite took 728.7
  seconds. No assertion failure was logged before cancellation. Packaging and
  all 14 GUI scenarios were skipped, so the immutable launcher still needs hosted
  sandbox proof. The production budget is now 35 minutes with every check kept;
  the native GUI job remains 30 minutes. Local success is not full T3 parity or
  proof of the pending hosted GUI workflows.

## 2026-10-22 — model controls and default native Liquid Glass

- Commit `01fb90f` adds bounded, paginated Codex discovery, native advertised
  reasoning controls and per-model preferences. CLI Default Model reads current
  checkout configuration on an independently owned metadata connection, captures
  concrete model/effort values and rechecks ownership before committing. Active,
  queued and future settings remain distinct. Default resets, stale catalog/read
  results, cancellation, immutable steering/queue captures and SQLite replay are
  covered by protocol, engine and native-store regressions.
- The complete model-control build passed 761 Swift tests: 627 core, 115 native
  view/store, six terminal and 13 Markdown. All 34 focused new declarations
  passed. The installed-Codex discovery test also passed with real catalog and
  cwd-aware default reads; it sent no model turn or configuration mutation.
- Shared native chrome uses `glassEffect` and `GlassEffectContainer` on macOS
  26+, with native material/bordered-control fallbacks on older systems. Opaque
  Reduce Transparency and increased-contrast rendering inputs are checked
  without changing the user's system settings. Editors, transcripts, code output
  and terminal content retain their readable semantic backing.
- The visual changes passed 117 native view/store tests, six terminal and 13
  Markdown tests, plus focused composer, provider-menu, PR and glass-layout
  checks. Geometry covers 320/680-point panels, both appearances, opaque/normal
  surfaces and standard/increased contrast. Native menu checks catch short
  labels stretching their chevrons across the header and long labels overflowing
  narrow space. App packaging, strict/deep signatures and native math resources
  passed; a Cua capture of the running development app showed readable chrome.
- WindowServer composites real glass and vibrant text. `NSView.cacheDisplay`
  offscreen PNGs are insufficient evidence for that material; opaque accessibility
  variants can be rasterized, while actual glass needs native window captures.
  The backed-up storage-23 workspace opened as storage 24 with identical
  canonical content and a successful SQLite integrity check. No release was made.
- Hosted GUI run `39735788588` executed 13 scenarios: eight passed, five failed,
  zero skipped. Four offline provider preflights failed specifically at
  `Process.run` with EPERM; `fcntl(F_SETNOSIGPIPE)` succeeded. The PR sheet also
  exposed another container accessibility identifier replacing its child action
  IDs. These findings are separate from unit/geometry success. The updated
  14-scenario runner requires fresh hosted execution after the launcher and
  accessibility fixes. Older-macOS runtime, full accessibility, provider and T3
  parity remain unverified.
- The replacement offline test CLI is a built/signed immutable Mach-O resource;
  private `codex`/`gh` entries are symlinks and fixture descriptors are data. It
  validates opt-in, private ownership/modes, exact fields, closed-world peers and
  executable arguments, then replaces its PID with explicit Python `-I -S`.
  Compile/sign/byte/entitlement checks and the actual-helper initialize/GitHub
  positive and descriptor rejection checks passed without a GUI. Physical root
  identity permits equivalent `/var` and `/private/var` spellings while preserving
  exact descriptor/environment binding. Seventeen Python checks passed. This
  does not yet prove execution inside the hosted XCTest sandbox; all 14 strict
  workflows, preflights, assertions and deadlines remain required.

## 2026-10-22 — durable native steering and full-suite handoff

- Native Queue/Steer preference, explicit delivery menu and alternate
  Command/Control-Return target the existing run. Compatible queued promotion
  captures the exact selected input and leaves the current draft alone. A saved
  Chat action reads the latest editor text, persists it before acceptance and
  cannot resurrect an older debounced draft. Later edits survive delivery.
- Codex uses the reviewed native `turn/steer` contract with the exact expected
  turn and authored message ID, without changing model/permissions or starting a
  new turn. Claude uses `priority: now`; a transport submission remains distinct
  from native acknowledgement. Foreground Agent/Task ownership gates steering,
  and semantic ownership events refresh the UI without per-token queries.
  Claude's controlled three-result Stop race now produces one root completion.
- SQLite accepts the authored row, captured input, exact run/runtime/native
  target and owned outbox together, then commits the dispatch marker before RPC.
  Late receipts retain their original run. A proven-unsent completed parent can
  create one follow-up using the same row; Stop/removal/restart suppress delayed
  fallback. Unknown delivery pauses FIFO; acknowledgement only releases its
  delivery hold, and Resume Queue is a separate action. Restart never resends.
- History rejects working and unverified retained steering, preserves failed
  input only in source audit, and retains inherited acknowledged provenance after
  fork/source removal. Its optional delivery proof preserves legacy fingerprints
  when no steering exists. Lost history acknowledgements remain inspectable after
  restart. Provider echoes cannot forge or overwrite local authored ownership.
  Storage version 23 protects the new durable ledger from older binaries.
- The focused run passes seven native declarations (including one existing
  history regression) in 4.643 seconds and 27 Core declarations in 0.878 seconds.
  Twenty offscreen composer/recovery captures cover 320/680-point widths in both
  appearances; narrow Steer, wide Queue and unknown-recovery layouts were inspected.
- The full suite passes all 727 Swift declarations: 600 Core in 248.470 seconds,
  108 native view/store in 46.643 seconds, six terminal in 1.388 seconds and
  thirteen Markdown in 0.136 seconds. Opt-in live checks remain off in that suite;
  deterministic protocol fixtures do not establish real provider execution.
- The separate installed-Codex engine smoke passes in 9.738 seconds: exactly one
  provider start, one steering call, one native thread/turn and an acknowledged
  receipt, the exact generated final marker, two attributed user inputs and
  preserved unrelated draft/checkpoints/files/index/HEAD. No unexpected tool or
  approval occurs. The opening counting marker had not yet appeared before
  steering; this verifies an active-turn handoff, not mid-tool interruption.
  Its one generated native thread was archived, private local cleanup passed
  and bounded process inspection was clear. Evidence is mode 600. This does not
  establish installed-Claude steering or broader provider versions.
- The repository-owned app packages and runs at its exact bundle path; deep/strict
  app/helper signatures and native math-resource rendering pass. A fresh private
  SQLite backup after graceful shutdown precedes storage 22 to 23. The complete
  canonical workspace remains identical: three conversations, 25 messages,
  integrity `ok`. No system installation or public binary release was changed.
- All fourteen Python harness checks pass. The actual strict-thirteen desktop
  runner compiles locally without running GUI tests. Its new workflow verifies
  default Return queueing, removal of that queued input, literal Unicode steering,
  one native run/turn, exact durable receipt/row/configuration linkage and restart
  without another input RPC. The peer accepts the provider's opaque message IDs,
  including the production `user-<UUID>` shape. Actual hosted proof is pending.
- Exact `1be63d13` [run 39731469631](https://github.com/apoorvdarshan/coincide/actions/runs/39731469631)
  passes all 694 production tests in 591.757 seconds. Its actual twelve GUI
  workflows pass eight, fail four and skip zero in 775.165 seconds; Files/editor
  passes in 90.827 seconds. The same three old combined preflight catches produce
  EPERM before app launch, and the old PR card identifier still hides its child
  control identifier. These results do not determine the precise failing launch
  statement or verify the already-pushed diagnostic/identifier fixes.
- Exact `60b2231f` [run 39732271528](https://github.com/apoorvdarshan/coincide/actions/runs/39732271528)
  passes all 694 tests in 699.495 seconds, packaging, signatures and native
  resources. Its fifteen-minute production deadline interrupts archiving before
  artifact upload, so GUI does not run. The production budget is now twenty
  minutes. The GUI budget is thirty minutes: the previous twelve-workflow run
  already took 775 seconds with three provider workflows failing preflight,
  and the new gate requires thirteen complete workflows. No individual assertion,
  test wait, coverage or zero-skip requirement was relaxed.

## 2026-10-22 — hosted twelve-workflow result and precise launch diagnostics

- Exact `e1184d13` [run 39729008478](https://github.com/apoorvdarshan/coincide/actions/runs/39729008478)
  passes all 676 production tests, packaging, signing and resources. Its actual
  desktop job executes twelve workflows: eight pass, four fail, zero skip
  (732.06 seconds). Files/editor passes again in 89.733 seconds.
- History, restoration and PR checkout fail before app launch in the exact
  offline-provider preflight, with POSIX EPERM and no stderr. The catch wraps
  both `fcntl(F_SETNOSIGPIPE)` and `Process.run`, so these results do not prove
  which operation failed. The preflight now records the exact stage, pipe flag
  result/errno, wrapper mode/length and a bounded shebang prefix. It preserves
  the initialize/exit checks and all twelve required workflows. A host-only
  owned-pipe probe succeeds; that does not establish hosted runner behavior.
- The PR creation screenshot and accessibility tree show an enabled Pull
  Requests button whose child identifier was overwritten by its parent card
  identifier. Removing only that unused parent identifier preserves the child
  controls' identifiers. The screenshot also contains a GitHub context error;
  this change does not establish that the complete creation workflow passes.
- All eleven GUI-free Python harness tests pass, and the strict desktop runner
  compiles without executing local GUI tests. Hosted proof of these changes
  remains pending. No workflow was skipped or assertion weakened.

## 2026-10-22 — independent PR worktrees and busy read-only reuse

- PR checkout now holds only the affected checkout. Source provider events,
  FIFO queues, editor buffers and terminals continue during an independent
  worktree job, including an uncertain outcome. Separate target paths and branch
  reservations can coexist; shared Git mutations serialize. Every retained
  native operation has its own Stop/Inspect/Acknowledge/Open controls bound to
  its durable ID. Closing the sheet leaves accepted jobs with the engine.
- Independent source proofs bind repository/admin/common ownership, pointers,
  selected remotes and transport/execution policy, allowing unrelated source
  edits, staging, commits, branch switches and branch tracking to progress.
  Local and refreshed target proofs retain their exact working/index/HEAD and
  configuration checks. Legacy plans retain conservative proof behavior.
- Busy registered targets, including a completed setup script with a still-live
  owned helper, receive a separate read-only review. Inspection preserves files,
  index, refs, tracking, submodules and setup, creates no private ownership data,
  and reports a consistent actual HEAD through an exact child reuse result.
  New activity after a refresh review rejects acceptance and requires review
  again. Read-only errors/cancellation/restart create no target or unknown write
  hold. Storage version 22 prevents older binaries from losing concurrent holds;
  older requests decode with the original refresh policy.
- The full run exercised 693 Swift test declarations. Two assertions/fixture
  boundaries needed updating: the multiple-job fixture released a review UUID
  instead of its primitive plan UUID, and the real integration test still
  expected a worktree checkout to hold the source. The fixture now checks its
  exact release key; the integration requires the destination hold before and
  after restart and a source hold only for Local. No deadline, policy or
  production safety check was weakened. All 102 native UI/Store tests then pass
  in 46.433 seconds, and the four real Git-to-SQLite normal/lost-completion cases
  pass in 9.592 seconds. The remaining 571 Core declarations, six terminal and
  13 Markdown passed in the full run (Core target: 245.660 seconds).
- Pure reuse now uses the same public child completion inspector without waiting
  for the shared mutation gate. A real-Git regression holds that gate and proves
  both observation and inspection finish before release, preserving exact
  child/base/result HEAD, index and files; it passes in 2.434 seconds. All 30
  affected GitHub/checkout/integration declarations pass in 110.132 seconds after
  this final change. Current source has 694 passing Swift declarations across
  the full and focused runs.
- Forty-four offscreen review/recovery captures cover 320/680 points in both
  appearances; readonly review and pending captures were visually inspected.
  The strict twelve-workflow hosted harness is unchanged. Previous exact commit
  `e1184d13` [run 39729008478](https://github.com/apoorvdarshan/coincide/actions/runs/39729008478)
  passes all 676 production tests, packaging, signing and native resources;
  its actual twelve-workflow desktop GUI job remains pending.
- The repository-owned app packages and launches with strict/deep app/helper
  signatures and native math-resource rendering verified. A fresh private SQLite
  backup after graceful shutdown precedes storage 21 to 22. The whole canonical
  workspace remains identical: three conversations, 25 messages, integrity `ok`.
  No system install was changed.

Full T3 parity and broader real-host/network and interactive concurrency
verification remain unfinished. No live GitHub checkout or public binary release
has been performed.

## 2026-10-22 — native pull request checkout and blank conversation import

- PR details now offer explicit reviewed local checkout or a separate worktree,
  capturing the exact GitHub repository/head, requested SHA, source/destination
  ownership and new-conversation agent settings. Fork branches use collision-safe
  base identity; deleted head repositories can use the exact base pull ref.
  Existing registered worktrees retain local commits and dirty files. A bare-name
  alias remains unverified even when its SHA coincides. Results and retained
  conversation lineage show actual branch/HEAD and off-head warnings.
- Git runs under the common-directory operation gate. Plans bind index/status,
  configuration and source/destination node and pointer proofs, including
  destination-only `config.worktree` changes. Expected-old ref updates preserve
  racing external branch advances. A rewritten reused head requires a clean
  checkout at its captured previous upstream AND the exact PR head repository
  and branch; unproven tracking never permits reset. The earlier commit is
  retained in an owned recovery ref before a proven rewrite. This upstream
  identity requirement is stricter than the pinned T3 implementation.
- The engine saves a distinct intent/outbox/dispatch before Git. It reserves an
  immutable target identity without creating a thread. Confirmed completion or
  read-only inspection atomically creates one blank conversation with captured
  settings, checkpoint policy and lineage; source history and latest draft stay.
  No prompt, queue or provider session is inherited. New/moved worktrees can
  discover setup for explicit review; unchanged reuse skips it. Accepted intents
  fail after process loss, dispatched unknowns remain held, and neither Git nor
  setup automatically repeats. Explicit unknown acknowledgment creates no target.
  Storage version 21 prevents older binaries from dropping these holds.
- Native Store tests cover shared windows, pre-SQLite acceptance, cold archived
  sibling holds, blocked Send preserving its current draft, selection changes,
  unknown reopen/inspection/acknowledgment, shutdown draining, specific admission
  errors and clean editor/PR metadata refresh after canceled stale reads.
  Physical inspector presentation stays available during PR holds independently
  of file/write readiness, and the PR recovery entry does not require a fresh
  Git snapshot after restart. Removed terminal tabs/windows now retain their directory ownership until their
  actual process and output drain. Real PTY tests use HUP/TERM-resistant commands,
  prove immediate checkout stays blocked after a tab/window closes, then verify
  the child PID is gone before review becomes available.
- Thirty-two offscreen review/recovery captures pass at 320/680 points in light
  and dark appearances; representative images were visually inspected. Geometry
  checks keep the explicit action reachable below scrolling metadata. The
  strict desktop runner compiles with all twelve workflows required and zero
  skips. The added offline workflow uses real private bare Git refs and exact
  GitHub-to-file URL rewriting, creates one source provider turn, opens the PR in
  a worktree, and checks its blank target, source history/draft/Git preservation
  and restart. All original eleven workflows remain. Eleven GUI-free Python
  harness/configuration tests pass. Actual hosted execution remains pending;
  no interactive GUI workflow ran locally.
- Prior exact commit `8f1568af` [run 39725843972](https://github.com/apoorvdarshan/coincide/actions/runs/39725843972)
  executed all 644 production tests and failed one managed-project fixture's
  replay equality comparison; the GUI job was skipped. That fixture observed
  provider idle before the automatic post-run checkpoint settled. Its wait now
  observes both completed runs and their final checkpoint state under the same
  existing deadline, retaining the replay assertion and checkpoint policy.
  The provider-wrapper execution-boundary issue in the earlier hosted history
  and restoration workflows is still awaiting hosted evidence.

- The full regression run passes 675 Swift test declarations: 557 Core in
  223.873 seconds, 99 native UI/Store in 41.331 seconds, six terminal and 13
  Markdown. The production checkout service also runs through the real SQLite
  engine in four local/worktree and normal/lost-completion combinations. The
  wrapper requires a saved dispatch marker and running outbox before real Git
  writes. A lost acknowledgment retains no target until reopen/receipt inspection;
  inspection performs no extra GitHub calls, checkout attempt or provider start.
  Target bytes/HEAD, captured blank settings, unchanged source history/draft and
  full journal reconstruction are verified.

- After the final terminal drain correction, the complete native UI/Store target
  passes all 99 tests again in 40.967 seconds and all six terminal tests pass in
  1.357 seconds. SwiftTerm clears its child PID before output drain, so shutdown
  now waits through both running and callback-drain phases without relying on
  that cleared PID. The two-case real PTY regression verifies both phases ended.
  A new local/worktree regression retouches tracked-file timestamps while keeping
  their bytes, forces inherited `GIT_OPTIONAL_LOCKS=1`, and proves prepare and
  completion inspection preserve exact index bytes through the runner's existing
  `--no-optional-locks` policy. Both cases pass in 4.571 seconds. Current source
  therefore has 676 passing Swift test declarations across these runs, plus the
  eleven Python checks; the final twelve-workflow runner compiles.

- The repository-owned app packages and launches with verified deep/strict app
  and helper signatures and bundled native math-resource rendering. A fresh
  private SQLite backup after graceful shutdown precedes storage 20 to 21.
  Whole canonical workspace comparison is identical: three conversations and
  25 messages, with SQLite integrity `ok`. The backup is retained in the app's
  private Backups directory. No system install was changed.

No live GitHub checkout or public binary release has been performed.
Whole-project idle admission remains more restrictive than T3's independent-worktree concurrency and busy read-only reuse; full T3 parity
is not claimed.

## 2026-10-22 — native GitHub PR browser and durable reviewed creation

- Changes opens a native GitHub PR browser with state/search filters, exact
  URL/number lookup, bounded native Markdown descriptions, checks, reviewers and
  labels. Creation reviews the repository, published head branch and commit,
  server base branch and commit, exact title/body and draft state. It requires an
  already published branch and rechecks its captured Git ownership before the
  single explicit `gh pr create`. An exact existing open head is reused before
  checking a changed base. No implicit push, fork, login or browser launch occurs.
- The durable engine commits a separate intent and outbox identity, then a
  dispatch marker before external creation. Project/incarnation and checkout
  holds prevent conflicting provider, Git, file, terminal and removal actions.
  Unsent drafts remain editable. Accepted work is not replayed after restart;
  dispatched uncertain outcomes remain held for read-only inspection or explicit
  acknowledgment. Not finding a PR is not treated as proof that creation failed.
  Storage version 20 protects these holds from older binaries.
- Real Git fixtures push only to private local bare repositories, then use a
  bounded offline `gh` peer with no HTTP path. Coverage includes exact fork and
  published-upstream identity, existing PRs with another base, literal Unicode
  title/body, one-create concurrency, stale/forged review rejection, cancellation
  and child drain, missing CLI, authentication/access/rate limits and bounded
  diagnostics. The production service also runs through the real SQLite engine:
  the peer requires its exact operation to be dispatching and outbox row running
  before accepting creation. Success and lost replies before/after mutation retain
  Git/index/HEAD, the current draft and journal projection across reopen, without
  another create. Reconciliation is read-only.
- Native Store coverage checks shared checkout ownership across windows, the
  pre-SQLite acceptance hold, blocked Send preserving the latest draft, uncertain
  restart/found/not-found/acknowledgment and stale canceled context reads. Native
  offscreen reviews, descriptions, unpublished-branch guidance and the entire
  unconfirmed sheet fit at 320/680 points in light/dark appearances. These checks
  do not execute interactive GUI tests locally.
- A retained registry drains every canceled/replaced PR read during shutdown,
  including an old read after its replacement finishes. The regression fails on
  the previous implementation and passes with the fix. Valid 4,096-byte titles
  also reproduced a clipped recovery screen. Pending recovery now scrolls between
  the fixed header/footer; completed operation cards have a bounded scroll area.
  Tests measure the actual heading and close-button frames, preserve the full
  captured title and cover both pending and read-only reconciled outcomes. The
  same test fails when the unbounded operation layout is restored.
- Hosted screenshots exposed an earlier composer draft being submitted. The
  actual Send action now reads the latest Store draft when invoked. Two injected
  provider cases capture the action before editing, set a complete Unicode
  prompt and submit before the debounce can save; the complete input reaches the
  provider and durable user message exactly once. Hosted fixtures additionally
  assert the intended editor value and run an initialize-only exact-wrapper
  preflight with bounded launch/error evidence. The launch failure itself is
  still awaiting hosted diagnosis; no speculative provider-protocol fix is made.
- The hosted runner now requires all eleven workflows and zero skips. The added
  offline native workflow reviews exact fields, cancels without a create, creates
  once with a lost reply, restarts with a held state, inspects without retry and
  preserves the draft and published local Git state. All original ten workflows
  remain. Ten GUI-free peer/configuration tests pass and the complete runner
  compiles. Actual hosted execution of the new workflow remains pending.
- Previous commit `b3d64cc` [run 39722212655](https://github.com/apoorvdarshan/coincide/actions/runs/39722212655)
  passes production tests, packaging, signing and native resource checks. Its
  actual ten-workflow GUI run passes eight, fails two and skips none. The native
  Files/editor/inspector workflow passes in 93.148 seconds, establishing hosted
  evidence for the AppKit inspector replacement. History and restoration fail
  before the first offline provider reply, with an OS operation-not-permitted
  notice and no peer wire receipt; their later history/file assertions did not
  run. Execution-boundary diagnosis remains separate from protocol correctness.
- The complete initial PR run passes 642 Swift tests, including 533 Core in
  166.742 seconds, six terminal and 13 Markdown. After the final App-only draft,
  read-drain and long-title corrections, the entire native UI/Store target passes
  92 tests in 36.236 seconds. Current source therefore has 644 passing Swift tests
  across these runs, plus the ten GUI-free Python checks. No interactive native
  GUI workflow ran locally.
- The repository-owned app packages and launches. Deep/strict app/helper
  signatures and native math-resource rendering pass. A fresh private SQLite
  backup after graceful shutdown verifies storage 19 to 20 preserves the entire
  canonical workspace: three conversations and 25 messages. No system install,
  public binary release or live GitHub mutation was performed.

AI PR content generation, compound commit/push/create, PR checkout/import,
review/merge actions, stacks, other hosts and broader live authentication/network
coverage remain pending. No live GitHub PR was created by these tests, and this
milestone does not establish full T3 parity.

## 2026-10-22 — combined native rewind and checkpoint restoration

- Rewind now offers Cancel, Revert and Keep Changes, and a separately prepared
  Revert Files Too review. The destructive choice shows the exact observation's
  time, scope, affected paths, bounded preview and loss warning. Fork remains a
  separate history-only action. The first input targets its original pre-provider
  baseline; later inputs target the preceding visible local run's latest ready
  post-run observation. A later baseline with intervening user edits is not
  substituted. Missing or ambiguous evidence disables file restoration.
- One durable parent owns provider and file stages with continuous source/path
  locks and a distinct file outbox identity. Confirmed provider history and local
  retained removal audit commit with the file intent before restoration starts.
  The Git writer runs only after owned provider/model connections have drained.
  Partial file outcomes retain provider success and hold work for read-only
  inspection or explicit Keep Current Files. Unknown provider outcomes never
  schedule delayed restoration, even when later inspection confirms the rewind.
  Restart never repeats either external mutation. Storage version 19 protects
  these new holds from older binaries.
- New rewind reviews recall the original prompt and attachments only after all
  requested external stages succeed. A durable hold prevents sending between
  completion and one-time latest-draft append. Merged attachment capacity is
  checked before acceptance and again at recall. A late capacity failure keeps
  the current draft and offers explicit Keep Current Draft. Legacy reviews retain
  manual recall. No prompt is automatically submitted.
- Real production Git through the durable engine verifies provider-before-files
  ordering, durable dispatch markers, the preceding post-run target with
  deliberately different selected-baseline bytes, exact restored working files,
  staging reset, ignored-file preservation and unchanged HEAD/branches/main
  checkout. The latest draft and complete run/message audit survive journal
  rebuild and reopen. Duplicate acceptance/recall and reopen do not repeat either
  mutation. Stale reviewed Git files prevent even the native provider mutation.
  Lost native acknowledgments before and after mutation retain untouched files
  across reopen and read-only reconciliation.
- Exact previous commit `c4df517` [run 39720191412](https://github.com/apoorvdarshan/coincide/actions/runs/39720191412)
  executed 575 production tests and failed one clone FIFO projection assertion;
  its GUI job was skipped. The fixture now waits for the exact second completed
  run's final post-checkpoint, provider readiness and empty queue before comparing
  projections. Existing checkpoint behavior and FIFO/configuration/attachment
  assertions remain enabled. Its focused local regression passes.
- The hosted runner still requires all ten workflows and zero skips. The history
  workflow now checks automatic prompt append, consumed recall, unchanged provider
  send count and one-time persistence across reopen. Seven GUI-free harness tests
  pass, and the updated native runner compiles. No interactive GUI test ran
  locally. Actual hosted verification of the native inspector and combined
  provider/files UI remains pending. Offscreen 320/680-point three-choice, file
  review and partial-outcome controls fit in both appearances.
- The complete local run passes 611 tests: 509 Core, 83 native UI/Store, six
  terminal and 13 Markdown. A subsequent App-only correction protects late draft
  saves across the 350 ms debounce and Quit while recall awaits SQLite. The
  complete final native UI/Store target passes 84 tests in 36.114 seconds,
  including held-write debounce, shutdown and identical-late-edit cases. Current
  source therefore has 612 passing tests across these runs; unchanged Core
  completes in 135.282 seconds. No compiler warnings were reported.
- The repository-owned app packages and launches; deep/strict app/helper
  signatures and native math-resource rendering pass. A fresh private SQLite
  backup taken after graceful shutdown verifies storage 18 to 19 preserves the
  entire canonical workspace: three conversations and 25 messages. No system
  install, public binary release or live combined-provider smoke was performed.

Full provider recovery, broader history contracts, large-workspace restoration,
recovery-storage management, remote environments and the other gaps in
`PORTING.md` remain unfinished. These checks do not establish full T3 parity or
live-provider verification of the combined file path.

## 2026-10-22 — reviewed native checkpoint file restoration

- Ready baseline, post-run and retained earlier observations now offer explicit
  native file restoration in an isolated conversation worktree. The selected
  attempt is exact and independent of the other checkpoint or provider's history
  capabilities. Review shows the checkout, observation time, affected paths,
  bounded current-to-target patch and destructive working/staging/new-file
  warning. Cancel is the default action. Conversation history, settings and the
  latest unsent draft are retained.
- Review prepares a frozen private Git administration/index and an owned shadow
  checkout. Git restore/clean/reset runs only there. Publication requires the
  unchanged reviewed working inventory, configuration, index, HEAD identity,
  directory ownership and exact saved target. Exclusive file publication retains
  displaced original bytes in private recovery storage; index publication follows
  working-file verification. HEAD and branches remain unchanged. Ignored files,
  nested repositories, symlinks, executable modes, empty scopes, outside-scope
  staging and unborn/no-index behavior have real-Git coverage. A direct isolated
  upstream Git probe corrected an invalid test expectation: deleting an untracked
  ignore file in a single clean does not also delete the files it had ignored.
- Accepted intent and outbox are journaled together, and dispatching is committed
  before the sole filesystem writer. Conflicting provider/configuration/removal
  work, dirty editors, active terminals and overlapping conversations are blocked.
  Owned provider/model-discovery connections drain before first write; detached
  closing connections retain their former working directory. JSON-RPC closure now
  awaits its exact native parent process's exit, including caller cancellation.
  This does not establish termination of all provider descendants.
- Local acceptance bridges the asynchronous durable lock across windows. Clean
  editor and Git caches remain read-only through authoritative refresh. A gated
  regression releases an older canceled read after a newer read and proves it
  cannot clear or replace the newer clean document. Deleted clean files close;
  existing dirty buffers are preserved and prevent acceptance.
- Restart never repeats a restore. Accepted undispatched work fails;
  dispatched uncertain work remains held. Inspect Restore State reads the pinned
  owned manifest/lock/completion and can confirm the exact result or untouched
  state. Missing, altered or partial evidence stays unresolved. Explicit Keep
  Current Files releases the hold without restoring or repeating anything.
  Canceled unused reviews remove only sealed scratch; unknown additions,
  interrupted cleanup and all started recovery data are preserved.
- Real production Git through the durable engine verifies Cancel, exact restored
  bytes, staging reset, ignored-file retention, nonignored-file removal, unchanged
  main checkout/HEAD/branches, latest draft and complete conversation/audit,
  journal rebuild, normal-close unused-review cleanup and reopen without replay.
  Gated own/other metadata-close tests prove the old directory remains protected
  through closure. Real process/RPC shutdown fixtures prove the close does not
  return before the exact owned native parent exits.
- Prior commit `22b140ac` [run 39715997685](https://github.com/apoorvdarshan/coincide/actions/runs/39715997685)
  executed 530 production tests and failed two assertions in one project-group
  removal fixture; its GUI job was skipped. The fixture now waits for its exact
  surviving completed run's provider release and terminal post-checkpoint before
  comparing/reopening projections. Its checkpoint policy, assertions and timeout
  budget remain enabled. The local worktree FIFO replay fixture likewise waits
  for both exact completed runs' final observations before comparing projections.
  A legacy migration expectation also advances to storage 18 with the new
  restoration journal field.
- The hosted GUI gate requires all ten workflows, zero failures and zero skips.
  The new workflow uses a native managed worktree, production automatic Git
  checkpoints and a private offline peer that edits only its synthetic README.
  It checks Cancel, real restore loss/preservation, original transcript/draft,
  unchanged source/HEAD, applied audit and reopen without provider replay.
  All original nine workflows remain. Seven GUI-free peer/configuration tests
  pass, and the complete runner compiles. No interactive GUI tests ran locally;
  the native inspector replacement and newest workflows still require an actual
  hosted result. Offscreen 320/680-point reviews and unconfirmed controls render
  and fit in light/dark appearances; 240-point action layout is unverified.
- Final `swift test --no-parallel` passes **575 tests**: 479 Core, 77 native
  UI/Store, six terminal and 13 Markdown, with no compiler warnings. Core
  completes in 117.702 seconds and native UI/Store in 31.565 seconds. Additional
  cancellation/archive/model-change review regressions verify exact unused
  scratch disposal and zero writes. Once acceptance starts, a disappearing review
  cannot dispose its pending action's scratch. A completed restore whose evidence
  becomes a FIFO/directory remains uncertain and retains recovery bytes.
- The repository-owned app packages and launches. Deep/strict app/helper
  signature checks and native math-resource rendering pass. Storage upgrades from
  17 to 18 with the complete canonical workspace unchanged against its private
  SQLite backup: three conversations and 25 messages. No system install or public
  app release was performed.
- After the provider shutdown change, the opt-in installed-Codex history smoke
  passes again in **11.549 seconds**, with two generated-marker turns, exact
  native fork/rewind and independent readback, unchanged Git state, retained
  draft/settings/audit, no unexpected tools/approvals and completed test-native
  archive/local cleanup. This verifies the existing live history flow; it does
  not exercise combined provider rewind plus file restoration.

Current restoration limits are 100,000 nodes, 4 MiB of path names and 512 MiB of
regular-file bytes per working inventory, including ignored files. Whole
repository copying/hashing, special/cross-device files, executable checkout
filters, unsupported sparse layouts and recovery-storage management remain
compatibility limits. Preview is bounded to 1 MiB and 128 leaf pairs with explicit
omission warnings. Inventory limits do not cap transient Git materialization,
conversion expansion or retained recovery storage. Combined provider rewind plus
file restoration, broader provider history and the other areas in `PORTING.md`
remain unfinished. This
milestone does not establish full T3 parity.

## 2026-10-22 — durable native conversation forks and rewinds

- Run History now reviews an exact verified Codex boundary before accepting a
  native Fork After Run or history-only Rewind Before Run. The engine binds the
  complete review to its current incarnation and source fingerprint, journals the
  accepted action and outbox together, and saves dispatching before the sole
  mutating RPC. Repeated acceptance observes the original action. Conflicting
  provider/configuration/archive/removal commands wait; drafts and selection stay
  available.
- Fork uses a fresh target actor and creates a separate conversation with the
  selected run's settings and visible prefix, without changing the source or
  sending a prompt. Rewind retains all messages/run audit with removal markers,
  keeps current settings/draft/attachments, and retires the old event stream.
  Explicit one-time Recall Prompt appends to the latest draft. An older Recall
  cannot run during a newer pending history action.
- Restart never repeats history mutations. Accepted undispatched actions fail;
  dispatched actions become unconfirmed. Read-only inspection resolves an
  uncertain rewind only when the unchanged or expected head is observed twice;
  an unrelated head stays unresolved. Drafting remains available while provider
  work is held. Deterministic engine tests cover lost acknowledgments before and
  after native mutation, reopen, no replay, source preservation, journal rebuild,
  stale reviews and external native changes.
- A held old turn-start acknowledgment exposed an adapter generation boundary:
  successful fork/revert now fences that suspended send before it can restore an
  old active turn ID. The protocol regression releases the old acknowledgment
  after rewind, then verifies the next explicit turn completes normally.
- The installed-Codex smoke uses two synthetic replies in its own Git project,
  production automatic checkpoints, exact native fork/rewind and independent
  paginated readback. Its first live review caught native `/private/var` versus
  app `/var` spelling for the same folder. Metadata ingress now applies the
  app's existing path convention; protocol tests cover snapshot/fork/revert on
  that actual directory alias while preserving wrong-workspace rejection.
- The final opt-in installed-Codex engine smoke passes in **12.008 seconds**:
  both expected replies, distinct native fork identity, exact fork/rewind head,
  independent native readback, preserved source/draft/settings/audit and unchanged
  tracked/untracked bytes, index, HEAD and status. No unexpected tools or approvals
  occurred. Only its two generated native conversations were archived and its
  local fixture was removed after a no-foreign-process proof. Earlier failed
  fixtures were preserved until separate archive and non-use checks permitted
  cleanup; their original failure evidence remains private.
- The cleanup proof excludes only the current test process's own open database
  handles and waits within its existing five-second budget for owned providers
  to drain. Darwin `lsof` can return status 1 with numeric matching PIDs, so such
  foreign matches remain a hold, not a successful deletion proof. Errors,
  nonnumeric output or stderr preserve the folder. A separate real-descriptor
  regression passes in **5.181 seconds**, proving own-handle exclusion, foreign
  holder preservation and clearance after that child exits. This proves directory
  non-use, not independent reaping of every provider descendant.
- Exact `fc869947` [run 39712233248](https://github.com/apoorvdarshan/coincide/actions/runs/39712233248)
  executed 491 production tests and failed two timing fixtures; its GUI job was
  skipped. ACP recovery now waits for the exact completed run's provider release
  and final checkpoint before shutdown, and checks the provider-start effect
  rather than the earlier checkpoint effect. Organization replay waits for its
  exact final checkpoint before comparing projections. Automatic checkpoints,
  assertions and timeout budgets remain enabled.
- The hosted gate now requires all nine real GUI workflows with zero failures
  and skips. The new isolated offline Codex peer persists across fresh processes
  and exercises native Fork/Rewind cancel/confirm, draft recall, reopen, exact
  mutation counts and unchanged Git bytes. The original eight workflows remain.
  The runner compiles and passes deep/strict signature verification; five Python
  fixture/configuration checks, shell syntax and project-plist validation pass.
  No actual GUI tests ran locally. The native inspector replacement still needs
  an actual hosted verdict after the earlier seven-of-eight GUI result.
- Final `swift test --no-parallel` passes **530 tests**: 438 Core, 73 native
  UI/Store, six terminal and 13 Markdown, with no compiler warnings. The Core
  summary completes in 83.612 seconds; native UI/Store completes in 30.266 seconds.
  Default execution does not opt into installed-provider prompts. The separate
  live result above and hosted interactive GUI evidence remain distinct.
- The repository-owned app packages and launches; deep/strict app/helper
  signatures and native math-resource rendering pass. Storage upgrades from 16
  to 17 with the complete canonical saved workspace unchanged against its private
  SQLite backup: three conversations and 25 messages. No system install or public
  app release was performed.

Support remains limited to verified new paginated histories on the reviewed
Codex 0.163.x profile. Filesystem restoration, other-provider/legacy history,
portable transfer and full T3 parity remain open. The provider protocol has no
compare-and-swap history RPC, so another client can still race the final read.

## 2026-10-22 — provider history contracts and durable transcript attribution

- Newly accepted and agent-initiated runs attribute their messages to their local
  conversation/run. Provider replacements cannot forge that reference; existing
  rows, user-echo association, late entity updates, terminal notices and recovery
  preserve it. Earlier transcripts are not backfilled. Verified prefix slicing
  rejects active, unknown, interleaved or unattributed later boundaries and does
  not invent an opening user message for agent-initiated work.
- Journal text-append optimization now requires unchanged run attribution. A
  same-text or appended-text attribution change uses a full message mutation;
  rebuilding the journal preserves the exact resulting snapshot.
- Native history contracts use opaque provider IDs. The reviewed Codex 0.163
  adapter reads bounded paginated summaries, forks an exact inclusive/exclusive
  boundary into a distinct target connection with goal continuation deferred,
  and reverts before a selected turn only on a loaded idle thread with a safe
  goal and an unchanged reviewed head. It verifies the resulting provider
  identity, workspace and head. Unsupported contracts do not drop the boundary.
  An uncertain mutation blocks further writes on that connection and is never
  automatically repeated; read-only inspection remains available.
- Initialization has one shared handshake with independently cancellable waiters.
  An isolated installed-CLI initialize-only check confirmed the actual
  `coincide/0.163.0` server user-agent prefix. It made no thread/model requests.
  New threads explicitly request paginated history only on the reviewed profile;
  existing legacy resume remains unchanged. History handshake errors are generic
  and do not expose the provider's private message/data.
- Deterministic protocol peers test exact request parameters, cursor/page bounds,
  cross-page boundaries, missing/unknown turns, unsafe goals, changed heads,
  unrelated identities, uncertain replies and target adoption. These do not
  establish live provider history mutation or complete provider parity.
- `swift test --no-parallel` passes **491 tests**: 405 Core, 67 native UI/Store,
  6 terminal and 13 Markdown, with no compiler warnings. This includes the
  repaired settlement fixture: it waits for the final checkpoint to finish
  before testing archive/unarchive against a retained provider-close owner.
- The repository-owned app packages and launches; deep/strict app/helper
  signature verification and native math-resource rendering pass. Storage
  upgrades from 15 to 16 with the complete canonical saved workspace unchanged
  against its private SQLite backup: three conversations and 25 messages.
- Exact `c5622dd` [run 39710791452](https://github.com/apoorvdarshan/coincide/actions/runs/39710791452)
  previously failed that one timing boundary in its 460-test production job;
  the dependent GUI job did not execute. The new native inspector replacement
  therefore still requires an actual hosted GUI verdict.
- App-level durable fork/rewind intents, recovery, transcript adoption and native
  controls remain to be implemented. Filesystem restoration and full T3 parity
  remain open.

## 2026-10-22 — automatic run checkpoints and native workspace comparisons

- Newly accepted input captures its checkpoint policy, defaulting to automatic.
  Before provider dispatch, the engine saves an immutable plan and attempts its
  baseline. A non-cancellation failure releases the original accepted payload
  with visible missing evidence. Legacy queued messages retain their absent
  policy without being retroactively changed.
- Completed/interrupted provider boundaries save a final workspace observation
  before the next FIFO message. Failure holds the queue for an exact-attempt
  Retry Current Workspace or Continue Without Snapshot. Retries retain earlier
  attempts and label their later observation; they never replay provider work.
  Failed, unknown, app-lost and never-dispatched runs record unavailable final
  evidence instead of inventing a successful capture.
- Incarnation/run/stage/attempt/path/plan fences protect asynchronous results.
  Stop, archive, removal and shutdown drain owned work outside the command inbox.
  A second canceled baseline cannot join its own drain. Restart performs bounded
  inspection only, does not replay provider work/captures or resume the restored
  FIFO, and a late inspection cannot override a newer explicit resume intent.
- Successful receipts bind a bounded scratch manifest by SHA-256. Cleanup checks
  retained directory anchors, exact file identities/content and known entry sets
  before unlinking only the temporary alternate index/private Git admin. Unknown,
  replaced, modified or locked entries are preserved. Matching durable markers
  permit partial cleanup to resume. Saved refs, objects, plans and receipts remain
  usable, including after cleanup and restart; legacy unproven scratch is kept.
- Unused executable filter settings, including global Git LFS configuration, no
  longer reject ordinary repositories. Actual driver use is checked against the
  frozen private admin/index before and after add, using bounded real/scratch
  inventories and literal attributes. Selected executable drivers remain omitted
  and unsupported. Fixtures prove missing-attribute fallback, staged ignored
  additions, removed real-index entries, configuration changes and attribute-only
  races cannot execute a filter or publish an unsupported capture.
- Native controls expose policy, preparation, queue holds, later-observation
  retries, preserved attempt status and bounded read-only Workspace Changes.
  Captured drafts, settings and selection survive reopen. Sixteen offscreen
  banner/history/diff/unavailable renders at 320/680 points in light/dark were
  inspected for readability and overflow. They do not establish interactive GUI
  or keyboard behavior.
- A real-Git engine fixture proves the baseline is ready before provider send,
  final receipt precedes second FIFO dispatch, scratch is removed, diff survives
  reopen, and working bytes/real staging remain unchanged. Focused Core execution
  passes **49 tests**, including cancellation/recovery, cleanup and filter races.
- Final `swift test --no-parallel` passes **460 tests**: 374 Core, 67 native
  UI/Store, 6 terminal and 13 Markdown, with no compiler warnings. Native tests
  include real setup/worktree/settlement FIFO using the production checkpoint
  factory and this Mac's unchanged global LFS configuration. Offscreen native split
  tests verify bounded loaded/dirty Files content, divider width restoration,
  retained host/cache ownership and first-responder preservation. These checks
  remain separate from the hosted interactive crash verdict.
- The repository-owned app packages, signs and launches successfully. Deep/strict
  app/helper signature checks and native math-resource rendering pass. Storage
  upgrades from 14 to 15 with the complete canonical workspace unchanged against
  its private SQLite backup: three conversations and 25 messages. No system install
  or public app release was performed.
- Fork, conversation rewind, filesystem restore and full T3 parity remain open.

## 2026-10-22 — strict-eight GUI result and explicit native inspector hosting

- Exact pushed `16b61a4` [run 39707700757](https://github.com/apoorvdarshan/coincide/actions/runs/39707700757)
  passes production tests/package/signatures/resources and **7 of 8 actual GUI
  workflows**, with zero skips (795.343 seconds). Setup (77.360 seconds) and settle
  (99.074 seconds) now pass their exact output/exit/draft checks and explicit
  Continue/Resume actions using the observed native triangle location.
- Files still aborts when opening the inspector. The retained `7483BE6F…ips`
  has the same constraint exception through `NSWindow._postWindowNeedsUpdateConstraints`,
  `SplitViewChildController.hostingView` and `NSHostingView.SizeConstraints`.
  The geometry-bound SwiftUI inspector candidate did not fix the actual crash.
- The next candidate replaces that inspector host with a narrow native
  `NSSplitView` bridge and retained hosting controllers whose intrinsic sizing and
  inner scene bridging are disabled. Existing sidebar, outer toolbar/commands,
  explicit inspector toggle, Files/Changes views and shared buffers are retained.
  Actual GUI proof of this replacement is still pending; no test assertion or
  workflow was removed to obtain a passing result.

## 2026-10-22 — inspector constraint boundary and script-output GUI targeting

- Manual strict-seven run [39705334238](https://github.com/apoorvdarshan/coincide/actions/runs/39705334238)
  at `d14b85a` passed five actual GUI workflows and failed two, with zero skips
  (665.317 seconds). Dark/light chat, manual scripts, grouping and worktrees pass.
  The toolbar-overflow script helper and folder-import readiness correction work.
- Files now imports its fixture successfully, then the app aborts at inspector
  reveal. The retained crash is a constraint-update exception through
  `NSWindow._postWindowNeedsUpdateConstraints`, `SplitViewChildController` and
  `NSHostingView.SizeConstraints.update`. Moving the inspector to the outer
  navigation host did not resolve it. The next controlled candidate keeps native
  inspector chrome while bounding asynchronous Git/file content to the allocated
  geometry, so its intrinsic minimum cannot grow the split host. A new offscreen
  regression checks unloaded/loaded files and a dirty editor at 280/360 points;
  this does not establish an actual GUI crash fix.
- The setup workflow reaches reviewed execution and the real exit status 7.
  Retained video/AX show the default disclosure click hits label text and leaves
  the native triangle collapsed. Setup and settle now click the observed triangle
  relative to its AX frame, require expanded state 1, and keep the exact output,
  exit, draft, checkout and source-byte assertions. No retry or assertion removal
  substitutes for expansion.
- Hosted proof of these two changes remains pending. The strict gate still
  requires all eight actual workflows with zero skips.
- The updated strict-eight runner compiles and passes deep/strict signature
  verification without executing GUI tests locally. Packaging/launch, app/helper
  signatures and native math-resource loading pass. Storage upgrades from 13 to
  14 with the complete saved workspace unchanged against its private SQLite
  backup: three conversations and 25 messages.

## 2026-10-22 — isolated native Git checkpoint primitive

- A read-only prepare step pins workspace/repository/admin/common/object directory
  identities, HEAD, effective configuration and the real-index revision. Capture
  uses one exclusive private ref and a separately owned alternate index. An owned,
  drained successful command path writes the completion receipt; a ref or orphaned
  process alone never proves completion. Retry cannot overwrite an incomplete
  attempt, and completed capture is idempotent.
- Snapshot staging uses frozen private Git configuration, sparse/ignore/attribute
  sources and the anchored original object store. Global/system/legacy config,
  hooks, fsmonitor, external diff/text conversion, replacement refs and lazy fetch
  cannot supply implicit execution. Preexisting executable clean/process filters
  fail visibly; a gated clean/process configuration change during add cannot run
  its sentinel. New private refs never change the branch, HEAD or real index.
- Real Git fixtures cover dirty/staged/untracked/deleted and ignored files, unborn
  repositories, modes, symlinks, literal/newline names, nested and linked worktree
  scopes, split indexes, ordinary/manual flags and cone sparse/full indexes.
  Sparse rules distinguish missing included manually skipped files from excluded
  entries. Auxiliary global/info ignore and attribute behavior is tested separately.
  Cancellation, changed ownership/configuration/HEAD/index, collisions, forged
  receipts, late ref/mapping changes and redacted bounded diffs also have coverage.
- Compatibility limits remain explicit: non-cone sparse and executable filter
  drivers are unsupported; modern Git with `--no-lazy-fetch` is needed. Auxiliary
  files are capped at 128 KiB each, the real index at 64 MiB and Git configuration
  and ordinary command output at 4 MiB. Operations have a 60-second budget with
  30-second command limits; diff defaults to 1 MiB and permits up to 8 MiB. Failed
  attempts and private indexes are preserved. Capture is not a transactional lock
  against another process changing working files while Git reads them.
- Automatic run integration, checkpoint UI and restore remain pending. No user
  checkout was captured, restored or deleted during this milestone's fixtures.
- Final focused run passes 32 declarations across Core and native UI/Store,
  including all 20 checkpoint declarations and parameterized race/compatibility
  cases. Full `swift test --no-parallel` passes **427 tests**: 345 Core, 63 native
  UI/Store, 6 terminal and 13 Markdown, with no compiler warnings. This includes
  the inspector size-boundary and completion-only Codex regressions.

## 2026-10-22 — durable per-run history and native inspection

- Newly started user turns retain their exact captured configuration and user
  message reference. Agent-initiated foreground work has its own origin and never
  creates a fake user prompt. Observed adapter turn references survive completion;
  they are not treated as proof of native provider fork or rollback support.
- Queue advancement closes the previous record before opening the next. Approval,
  Stop, forced runtime closure, start failure, provider failure, connection loss,
  unknown stop reasons and application restart retain distinct outcomes. Stale
  scoped events and repeated completed activity cannot reopen or rewrite a run.
  Legacy transcripts remain unchanged without guessed historical boundaries.
- Codex completion-only notifications retain the actual completed turn reference
  even when both its start notification and start response arrive later or not at
  all. The late-acknowledgment protocol fixture also covers this ordering.
- Seven focused Core test declarations cover these transitions, legacy recovery,
  journal reconstruction and invalid boundaries, including parameterized failure
  and ACP activity cases. The existing real-engine FIFO test also verifies the
  completed run settings, user references and rebuilt projection.
- The workspace menu opens a read-only native Run History sheet. Three native
  cases check captured settings, mixed/unknown history, agent-managed model
  options and small-sheet geometry. Light/dark offscreen renders at 320 and 560
  points were captured; recorded, mixed and legacy states were visually inspected.
  This is separate from actual hosted GUI execution.
- The serial run-history suite passes **406 tests** (325 Core, 62 native UI/Store,
  6 terminal and 13 Markdown). The separate checkpoint primitive was excluded
  while it was still under development. No compiler warnings were reported.
- Fork, rewind, filesystem restore and automatic per-turn checkpoints remain
  separate work; the history sheet performs none of those actions.

## 2026-10-22 — explicit settlement generations and reviewed cleanup scripts

- Native workspace/context/Thread menus offer Settle Conversation with a
  confirmation and default-on settle-script review. Settle requires an idle
  conversation, empty queue, no pending questions and resolved checkout setup.
  Repeating Settle keeps the same generation. Provider idle does not settle it.
- A generation holds provider readiness independently of script exit. Anchored
  discovery selects the first run-on-settle role in a proven separate linked
  worktree; main/shared checkouts and unproven legacy ownership skip it. Command
  review pins the exact configuration and cwd. Changed configuration fails before
  execution; retry creates another reviewed run. The async flag remains a setup
  setting and does not release a settled conversation.
- Retained setup jobs and prior cleanup for the exact thread drain before settle
  discovery. Scoped cleanup joins cover archive/unarchive followed by Settle,
  including an already-closing idle provider. Unrelated threads stay responsive.
  Resume or new user input drains the generation's owned script jobs before
  clearing its gate and starting captured FIFO messages. A later Stop preserves
  the paused queue when cleanup completes; explicit Resume Queue releases it.
- The shared runtime uses a typed setup/settlement owner, per-run output and
  incarnation fences. Script exit remains separate from job lifetime. Archive,
  removal, shutdown and restart retain those ownership rules. Interrupted cleanup
  never replays after restart, and an unstarted review can resume without running.
  Existing manual terminal tabs stay open.
- Seventeen focused Core settlement cases and four new native Store/view cases
  pass alongside the existing setup coverage. Native cases run actual temporary
  Git worktrees and helper commands, including TERM-ignoring background jobs,
  two output listeners, automatic input-driven Resume, captured models/permissions,
  changed commands, fresh review, restart, main-checkout skipping, unsent drafts
  and preserved source files. The confirmation and exact-command review were
  inspected in light/dark offscreen renders; small-display geometry passes.
- Full `swift test --no-parallel`: **396 passed** (318 Core, 6 terminal,
  13 Markdown, 59 native UI/Store). The eight-workflow actual GUI runner compiles
  and passes deep/strict signature verification without launching local GUI tests.
- Packaging/launch, deep strict app/helper signatures and native math-resource
  loading pass. Storage upgrades from 12 to 13, preserving the complete saved
  workspace against its private SQLite checkpoint: three conversations and
  25 messages.
- An eighth actual GUI workflow covers native confirmation/default review,
  both Cancel paths without execution, exact command/cwd, first-role execution,
  exit/output while still settled and explicit Resume with the same draft,
  thread, checkout and source bytes. Its strict gate requires all eight workflows
  and zero skips; actual hosted execution remains separate from local build proof.
- Automatic inactivity/PR settlement, snooze settings and idle-terminal closure
  remain pending.

## 2026-10-22 — reviewed checkout setup and provider readiness

- Worktree requests persist the setup-review choice before Git starts. Discovery
  reads the ready checkout's anchored configuration and selects the first
  run-on-create role. It captures a complete plan for explicit native review;
  Cancel never starts it. Missing roles skip setup, while malformed or changing
  configuration requires a visible retry/continue decision. Reusing the main
  checkout skips the role, including when the source is a linked checkout.
- Files and Terminal use checkout readiness independently of the provider gate.
  Blocking setup releases captured queued messages only after actual exit 0;
  asynchronous setup requires a durably recorded startup acknowledgment. Later
  asynchronous failure does not cancel provider work already accepted.
- The Core owns one raw-output consumer and the managed job across windows.
  Bounded Unicode text snapshots fan out to independent listeners without storing
  raw output in the workspace journal. Stop, Continue Without Setup, Retry,
  archive, removal and shutdown drain the owned session; a closed output snapshot
  cannot precede that drain. Retry creates a new run and review. Restart marks
  uncertain work interrupted and never replays the command automatically.
- Sixteen focused Core cases pass, including exact approval, first-role selection,
  blocking/async readiness, FIFO provider settings, commit failure before launch,
  claimed-outbox recovery, retained background jobs after exit 0, held cleanup,
  Stop followed by removal/shutdown, archive/unarchive/retry joining an existing
  drain, no-runtime log closure, stale owner IDs and main-checkout reuse. Three new native Store/view cases pass with actual local
  Git worktrees and the native helper executable: two-window output/cleanup, real
  exit 7 and environment/cwd, changed configuration, fresh retry, restart review,
  unsent drafts/source-file preservation and small-display form geometry.
- Full `swift test --no-parallel`: **375 passed** (301 Core, 6 terminal,
  13 Markdown, 55 native UI/Store). Offscreen setup-review and worktree-form
  previews were inspected in light and dark appearances. The first light capture
  mixed SwiftUI's light scheme with the host's dark AppKit semantic background;
  scoping the capture window and drawing appearance fixed the harness. The
  focused render check passes again; no product colors changed.
- The repository-owned app packages and launches with deep strict signature,
  separate helper signature and native math-resource checks passing. Storage
  upgrades from 11 to 12, with the entire saved workspace unchanged against its
  private SQLite checkpoint: three conversations and 25 messages.
- CI run `39701358026` at the preceding helper-only commit failed compilation
  under Apple Swift 6.3.3 before tests could execute. The local Swift 6.4 compiler
  accepted C argument-vector inference that the hosted compiler rejected. The
  helper and launcher now use explicit String and C-pointer array types, with an
  unambiguous filesystem path. All 375 local tests pass again; the seven-workflow
  native runner also compiles and verifies its signature. Exact-head hosted
  compilation then succeeded in run `39703856781`. Its setup Store test failed
  because the default Codex executable was absent on the runner, so the Store
  rejected input before reaching the injected provider. A four-line fixture fix
  at `d14b85a` saves/selects a synthetic ACP executable (`/usr/bin/true`); the
  injected peer still owns protocol behavior and all queue assertions remain.
  Seven focused native setup/settlement cases pass locally with that fixture.
  Hosted push run `39704717961` passes all 375 tests (142.235 seconds), packaging,
  signing and resources. Its fixture-only path filter intentionally skips GUI.
  Manual run `39705334238` records the same immutable `d14b85a` head with the
  unchanged seven-workflow suite enabled; actual GUI results remain pending.
- Actual setup GUI workflow verification remains separate from these focused
  tests. The existing manual script workflow and its terminal ownership remain
  unchanged. Settle/resume generations and settle-script execution remain pending.

## 2026-10-22 — managed native script process primitive

- A separately signed native helper owns a PTY and remains its process-group
  leader after the command shell exits. Actual wait status travels through a
  separate framed status pipe; terminal text cannot impersonate it. Background
  jobs may retain the PTY without delaying command completion. Explicit close or
  authority-pipe EOF stops the owned group and drains transport readers before
  the leader is reaped. Processes that deliberately leave that group are outside
  this ownership guarantee.
- Plans capture the exact script/index, complete configuration revision, anchored
  project/checkout identities and absolute shell. Inherited environment values
  are not serialized in the plan. Preparation validates without running commands;
  a one-shot Start revalidates immediately before descriptor-based cwd handoff.
  Configuration/root replacement rejects execution rather than silently running
  a changed command. Startup handshakes and frames are bounded and versioned.
- Output uses one ordered, lossless consumer with bounded backpressure. Separate
  nonblocking control processing keeps Stop responsive under output pressure;
  closing does not await an arbitrarily stalled presentation callback. Shell
  children do not inherit authority/status pipes or directory anchors. The app
  retains its helper child identity until final group signaling and cleanup.
- The first focused run failed in fixture discovery because Swift's test runner
  executable lived outside the build folder. The fixture now uses the explicit
  checkout/build configuration, and the test target depends on the helper product.
  Removing only the generated helper binary and running ordinary `swift test`
  relinked it. The final fourteen-case focused run passed, covering exit 7,
  background jobs with closed stdio, continuing PTY output after command exit 0,
  owner-loss EOF, root/config replacement, cancellation/input/resize, ordered
  Unicode output, held-consumer pressure, descriptor isolation and strict plans.
  Further cases cover coalesced Stop/Start without execution, unexpected helper
  death without replay, commands that never read pending PTY input, and aggregate
  control-write admission before frame allocation (16 pending writes/1 MiB).
  Write reservations release before completion resumes; close also waits for the
  serial writer barrier. The final focused run passed in 8.317 seconds.
- Full `swift test --no-parallel`: **356 passed** (285 core, 6 terminal,
  13 Markdown, 52 native UI/Store). Packaging/launch, deep strict app signing,
  separate helper signature, bundled-helper executable loading and native math
  resources pass. The complete saved workspace remains unchanged against the
  private checkpoint: three conversations, 25 messages and storage version 11.
- This is a Core process primitive, not yet automatic setup/settle behavior. Native review,
  durable readiness/approval/restart state and app-owned presentation remain
  separate integration work; the existing manual script path is unchanged.

## 2026-10-22 — inspector layout crash investigation

- Hosted run `39697982965` at `8c0df0b` passed four of five actual GUI workflows,
  with no skips. Project scripts completed discovery/Cancel, stale-config rejection,
  Reload, dedicated command cwd/environment/exit status, and running-tab close
  confirmation. Light, dark and grouped-checkout workflows also passed.
- Files/editor testing crashed the app immediately after opening the inspector,
  before its Files control appeared. The crash report and video confirm an app
  failure; changing a test selector would not address it. The main-thread exception
  cycles through AppKit window constraints, SwiftUI toolbar preferences and layout.
  This stack identifies the failing framework path, rather than proving an exact
  source-level cause.
- Commit `076efa3` moves the inspector from a conditional detail split view to the
  stable outer navigation host, preserving its content and existing controls.
  All 342 serial tests pass; packaging/launch, deep strict signing and native math
  resources pass. The entire saved workspace remains unchanged: three conversations,
  25 messages and storage version 11.
- Run `39699162944` at `4e76a90` passed five of six actual GUI workflows, with no
  skips. Files reproduced the same inspector constraint/toolbar crash. The new
  worktree workflow passed its complete local-base/branch/submodule-choice,
  draft/cwd/restart and source-preservation checks (93.905 seconds). Project scripts
  passed again (93.121 seconds). Actual six-test execution took 647.088 seconds.
- The unchanged six-workflow GUI suite in run `39699875038` passed four, failed
  two and skipped none (534.352 seconds). Files stopped before opening the
  inspector: the combined readiness predicate timed out, while the exported
  native location, screenshot and accessibility diagnostic showed the requested
  folder with Add Project enabled and hittable. Scripts stopped because Run Script
  had moved into the native toolbar overflow, visible in both pixels and the
  accessibility tree. No inspector execution occurred, so this run does not
  establish whether the layout change resolves the crash.
- Harness navigation now waits for the observed native folder-location value
  before directly asserting Add Project's enabled/hittable state, and follows
  the actual toolbar overflow when Run Script is hidden there. Existing workflow
  assertions remain. A seventh workflow adds reviewed setup/Cancel, exact command
  and cwd, first-role execution, exit/output, explicit Continue and retained draft
  and source checks; the result gate rejects fewer than seven tests or any skips.
  Its execution allowance is 20 minutes, reflecting the earlier six-workflow
  647-second test-only duration plus the new workflow and complete Files body.

## 2026-10-22 — explicit submodule initialization for new worktrees

- New worktree requests capture an explicit None/top-level/recursive choice. None
  remains the native default; old requests, ownership records and completion
  receipts decode without enabling downloads. Retry preserves the captured mode.
  Registered-worktree reuse rejects initialization and remains read-only. Storage
  version 11 prevents older apps from ignoring a selected preparation stage.
- Initialization follows successful owned checkout creation and precedes the
  final completion receipt and eligible queued provider start. It uses the new
  checkout, pinned regular `.gitmodules` bytes (up to 256 KiB), an unchanged index, captured Git
  administration/common-directory ownership, and `--checkout` without force,
  remote-update, reset or source-submodule mutation. Final synchronous config
  revalidation rejects a replacement during awaited policy/mapping reads; this
  does not claim filesystem locking against arbitrary external writers.
- Only standard transports allowed by effective Git policy and any inherited
  allowlist can run. File transport requires explicit allowance; arbitrary/ext
  helpers and configured custom update commands cannot execute. Planning,
  checkout creation and completion inspection continue to deny transport access.
  Development regressions use private nested local repositories and gated wrapper
  processes, with no real remote requests.
- Normal initialization failures/timeouts/output limits persist one fixed generic
  warning with a usable checkout. The warning remains visible after restart and
  contains no raw Git output, URL or configuration value. Cancellation, changed
  configuration and lost ownership preserve partial files without a completion
  receipt; their queues stay held. Explicit reuse/new selection remains necessary
  for an unproven partial attempt rather than replaying Git over retained files.
- Five new primitive cases cover mode/legacy/policy validation, None/top-level/
  recursive nested checkout contents and source dirty-file/HEAD preservation,
  custom-update/ext-helper rejection, warning recovery, owned cancellation, and
  config replacement during policy discovery. An engine case checks held FIFO
  readiness and persisted warning recovery. The existing native Store workflow
  now carries top-level selection through real Git, queued settings and restart.
- A committed gitlink without `.gitmodules` initially returned success without
  trying the selected initialization. The regression fails before the fix; missing
  pinned configuration now requires proven absence and still invokes Git, whose
  normal failure becomes the generic warning. Ordinary repositories remain no-ops.
- The sixth hosted GUI workflow exercises the native worktree sheet, explicit
  older local base/new branch, safe default and all mode controls, retained draft,
  native readiness, actual new cwd/HEAD/content, restart reuse and unchanged source
  HEAD/dirty/untracked files. It is separate from the immutable five-test run on
  `8c0df0b`; compilation alone does not establish its runtime result.
- Final `swift test --no-parallel`: **342 passed** (271 core, 6 terminal,
  13 Markdown, 52 native UI/Store). All six Xcode GUI methods compile, the runner
  passes deep signature verification, and Python CI configuration checks pass 3/3.
  Packaging/launch, deep strict app signature and bundled math-font rendering pass.
  Migration to storage 11 preserves the entire canonical user workspace against
  its private storage-10 backup, including three conversations and 25 messages.

## 2026-10-22 — explicit native project scripts and process pipe isolation

- Native discovery reads the current checkout's anchored `t3.json`, capped at
  256 KiB, with the pinned declaration schema, comments and trailing commas.
  Eight core cases cover strict known types/null rejection, ordered duplicate
  declarations, literal strings, malformed JSON, size/depth limits, file revisions,
  contained links, special files, cancellation and root replacement. Foundation's
  decoder accepted a malformed repeated-comma fixture; grammar validation now
  rejects it before normalization. Diagnostics do not include configuration values.
- The native sheet displays the chosen command and checkout. Explicit Run checks
  the displayed file revision and script, fresh anchored root metadata, captured
  conversation incarnation and current window ownership before synchronous PTY
  creation/registration. Replacing the root during a gated read preserves both
  folders and launches nothing. Removal/re-add and switching away/back invalidate
  old actions even when a surviving owner keeps the same file session. Removal and
  shutdown cancel and drain late reads. These checks do not claim cross-process
  locking against an external filesystem mutation after the final check.
- Script tabs receive literal shell-command arguments and T3 project/worktree
  environment values, retain output and exit status, and preserve the draft,
  provider/model settings and existing terminal tabs. Setup/settle/async/preview
  fields remain data: discovery does not run commands or open URLs. Eight native
  Store/process workflows and two command-terminal cases use controlled local
  shells and private fixtures; none submit a provider turn.
- Hosted worktree-head run `39696929949` failed the existing terminal-removal
  fixture at its 60-second limit and resumed after its unrelated 120-second child
  exited. Native GUI execution was skipped. Investigation found inheritable
  Foundation pipe descriptors: a new deterministic test failed before the fix
  because a terminal child kept another process's stdin open, and passed after
  setting close-on-exec on all six provider pipe descriptors. Pipe setup and the
  app's native terminal fork now share a short synchronous lock. This proves the
  inheritance defect; its exact interleaving in the hosted failure is inferred.
  The unchanged removal fixture passes locally with CI's serial settings.
- `swift test --no-parallel`: **336 passed** (265 core, 6 terminal, 13 Markdown,
  52 native UI/Store). The five-method Xcode runner builds and passes deep signature
  verification; Python CI configuration checks pass 3/3. A fifth actual GUI workflow
  covers discovery/Cancel, changed-config rejection/Reload, explicit command cwd/env
  and exit status, and running-tab close confirmation with retained drafts. The
  strict hosted gate requires all five actual tests and zero skips; compilation
  does not establish their runtime result. Hosted execution remains pending.
- `./script/build_and_run.sh --verify` packages and launches the repository-owned
  app. Deep strict signature and bundled math-font rendering checks pass. Storage
  remains version 10, with the entire canonical user workspace unchanged against
  its private checkpoint, including all three conversations and 25 messages.

## 2026-10-22 — durable native worktree preparation

- Worktree choices now save an intent and target cwd before asynchronous local Git
  resolution. A second durable stage saves the immutable plan before Git mutation;
  readiness, the prepared target, and the first eligible FIFO provider effect commit
  together. Queued turns preserve provider/model/permission/ACP/attachments. Retry
  changes only their cwd/native-session fields when assigning a fresh destination.
  Old provider session IDs cannot resume in the newly selected checkout.
- Native choices cover a new branch with an explicit local base, an existing local
  branch, and registered local-branch worktree reuse. Git inventory parses NUL
  fields, including newline paths and lock reasons. Actual inventory normalizes
  macOS `/private/var` and `/var` aliases consistently; lexical validation still
  rejects traversal, empty components, remote URLs, and credential-bearing URLs.
  The first real-Git run exposed the alias mismatch; this was corrected without
  relaxing repository or inode containment.
- Plans capture source/admin/common-directory and parent identities and a pinned
  commit. Git commands use captured repository binding and an owned process group
  with bounded output, timeouts, cancellation, and exit/pipe draining. A gated
  linked-source `.git` replacement verifies that neither repository nor destination
  is mutated. Exclusive managed destinations and sibling ownership records prevent
  overwriting retained folders; reuse verifies registration, common directory,
  checkout/admin identities, and backlinks.
- Automatic completion requires a durable receipt written only after owned Git
  exits successfully, plus exact pinned HEAD and matching ownership. A running
  post-checkout hook cannot satisfy completion. If a crash precedes that receipt,
  registration alone remains unproven and preserved; explicit verified reuse can
  accept it later. No branch reset, worktree deletion, pruning, or missing-base fetch
  is performed. Git may clean its own unfinished files when cancelled.
- Cancel and restart hold queues. Startup publishes interrupted state immediately,
  then runs owned read-only completion probes in four lanes. A gated probe proves
  load and unrelated provider commands remain responsive. Attempt/incarnation and
  removal fences reject late results and old begin intents even after same-ID
  re-add. Failed empty setup can choose another worktree; previous attempts remain
  journaled. Manual path edits cannot invalidate a preparation record.
- Checkout changes reject unsaved file edits and conversation terminal tabs across
  all registered windows. Running commands remain open for explicit closure.
  Synchronous preflight locks the old path through intent commit/application, and
  terminal creation rechecks its captured conversation path/attempt. Regressions
  preserve a dirty completed-worktree editor and both window terminal owners,
  retain unrelated terminals, and reject a stale terminal action after transition.
- Eleven primitive cases, thirteen engine cases, and four native Store workflows
  cover real Git bytes/receipts, source edits/untracked sentinels, new/existing/reuse,
  aliases/newline paths, replacement/FIFO/containment, cancellation, queued settings,
  corrected setup, restart windows, background recovery, stale owners, transaction
  rollback, dirty buffers, and terminal ownership. No installed provider model turn
  or local interactive GUI was used for these new cases.
- The full suite passed 318 tests: 257 core, 4 terminal, 13 Markdown, and 44 native
  UI/store. The 31-case focused worktree run also passed. Packaging/launch,
  strict deep app/runner signing, bundled-font rendering, GUI-runner compilation,
  and all three CI-configuration tests pass. A private SQLite backup precedes the
  storage 9-to-10 migration; canonical comparison confirms the entire existing
  workspace, all 3 conversations, 25 messages, and project fields are unchanged.
- Hosted run 39694657397 at `288000b` passed all three actual GUI workflows with
  zero failures or skips: full light/dark and complete grouped/separate checkout,
  three drafts, restart/selection, group rename, Cancel, and confirmed group removal.
  The fourth Files/editor/content-search/reference/unsaved-Quit workflow is now
  compiled with a strict four-test gate; its actual hosted execution remains pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — native external-editor handoffs

- Added the pinned editor catalog and native Xcode support, local preferred-editor
  settings, explicit file/result/checkout actions, and separate Finder reveal.
  Discovery inspects application metadata and contained launchers, including
  stable/Insiders separation, versioned JetBrains bundles, and Antigravity IDE
  versus Hub. It does not execute PATH wrappers. Bundle identifiers and launcher
  layouts were checked against current Homebrew package manifests; this is not
  vendor-signature validation or proof every installed editor works.
- Existing file/directory metadata uses anchored descriptors without reading file
  contents. Binary files and internal links are supported; escaping links, special
  files, replaced roots, and unavailable owners are rejected. The selected bundle
  and captured workspace owner are rechecked after asynchronous preparation and
  immediately before synchronous submission. Native buffers remain unsaved and
  unchanged; external apps receive the saved disk version. Native actions pass a
  line, without asserting cross-editor Unicode column conventions.
- Launch Services completion errors reach the caller. CLI argument vectors remain
  literal; detached children use null standard streams, are reaped on exit, and
  never receive Coincide timeout/shutdown signals. A synchronous request returns
  its completion receipt before any await, preserving the final ownership boundary.
  Accepted external apps and delayed completion remain independent of later
  cancellation, removal, and shutdown. Pending preparation cancels; shutdown drains
  the actual shared discovery scan even after its callers have detached.
- Eight core and ten UI/store regressions cover catalog/position/argument rules,
  fixture-bundle discovery and replacement, metadata containment, preference
  fallback, dirty buffers, same-ID owner replacement, shared-root survival, final
  target revalidation, completion failure, concurrent discovery/cancellation, and
  shutdown before and after handoff. An initial shared-waiter test exposed a wait
  on the uncancelled common task; per-caller continuations now release cancelled
  waiters while retaining the underlying scan's independent ownership and drain.
  No installed editor, Finder window, or local interactive GUI was launched.
- The full suite passed 290 tests: 233 core, 4 terminal, 13 Markdown, and 40 native
  UI/store. Packaging/launch, strict deep app signing, bundled-font rendering, and
  all three CI-configuration tests pass. Canonical comparison confirms the existing
  3 conversations, 25 messages, and non-identity project fields are unchanged;
  storage remains version 9. The GUI runner compiles and passes strict deep
  signature verification without local interactive execution.
- Hosted run 39693126654 passed both complete light/dark workflows. Grouping
  passed checkout creation/preferences and draft capture, then XCTest could not
  click a visible native OutlineRow. Retained screenshot/accessibility evidence
  shows its identified title inside the row. The harness now clicks that visible
  title and requires the actual row to become selected; all three workflows remain
  required, with complete grouping GUI verification pending the next hosted run.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — native workspace content search

- Added whitespace-preserving literal/regex search with case and Unicode whole-word
  options. Matches use one-based lines and original UTF-16/end-exclusive ranges.
  Whole-word filtering handles letters, marks, numbers, underscore, astral scalars,
  punctuation-edged adjacent matches, and later accepted candidates after rejected
  raw matches. Zero-width regex matches are bounded and excluded in whole-word mode.
- Path and content searches share fresh, anchored, ignore-aware discovery: at most
  25,000 entries and a 15-second discovery budget. Content matching has a cooperative
  250-ms budget, at most 500 matching lines, 100 lines per file, 100 ranges per line,
  1 MiB read per file, 32 MiB aggregate reads, and 16,384 UTF-16 units per line.
  Binary/malformed prefixes consume the read budget before exclusion. Large-file
  prefixes contribute complete lines only. Every omission or exhausted budget is
  reported through `truncated`; queries are never written into diagnostics.
- Native ICU regex compilation failures return a generic visible error with no
  pattern or raw Foundation diagnostic. SDK-supported progress callbacks, per-line
  checks, and owned task cancellation provide cooperative interruption. The
  pathological-pattern regression checks partial-result behavior under the test
  framework timeout; it does not prove a specific callback interleaving or a hard
  real-time deadline. Native regex/fallback semantics are not fff compatibility.
- The inspector adds Paths/Contents, Match Case, Whole Words, and Regex controls.
  A lazy native list groups and highlights matching lines. Opening a result targets
  its captured file, line, and UTF-16 range, with existing dirty-buffer confirmation.
  Same-file navigation retains unsaved edits. Search generations and complete
  request/options fence late results; superseded reads/scans cancel and drain before
  a replacement starts. Same-file navigation cancels and fences an older pending
  other-file open while retaining its shutdown drain. A held real-read completion
  verifies that the latest navigation and subsequent dirty edit cannot be replaced.
  Watch refreshes preserve conversation and dirty editor state.
- The full suite passed 272 tests: 225 core, 4 terminal, 13 Markdown, and 30 native
  UI/store. Thirteen new core cases cover Unicode/CRLF/case folding, literal spaces,
  word filtering, regex/zero-width/privacy, Git ignores, file/line/range/result and
  byte budgets, special files, cancellation, root replacement, and pathological
  regex. The new offscreen UI test checks actual NSTextView selection after an
  emoji and retains dirty text, drafts, provider, selection, and source-file bytes.
  All prior file/walker/read and Git regressions pass. No local interactive GUI test ran.
- Hosted run 39691871298 passed both full light and dark workflows, including
  restart, draft persistence, warning text, Cancel, confirmed removal, and original
  Git files. The grouping workflow reached checkout menus but XCTest rejected a
  207-character path passed to its convenience identifier lookup (128-character
  runtime limit). Exact property predicates replace that lookup; full grouping
  GUI verification remains pending. All three workflows remain required.
  The passing warning checks do not establish that the OCR fallback ran; the
  exported result contains no OCR attachment for those successful checks.
- Packaging/launch, strict deep app/runner signing, bundled-font rendering,
  GUI-runner compilation, and all three CI-configuration tests pass. Canonical
  comparison confirms the existing 3 conversations, 25 messages, and non-identity
  project fields are unchanged; storage remains version 9.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — native workspace file sessions and editor integration

- Added local async listing, path search, ignored-file inventory, bounded UTF-8
  reads, exclusive creation, revision-checked saves, and advisory recursive
  FSEvents invalidations. Immediate listing includes hidden/empty/ignored entries;
  path search excludes ignored paths, including tracked files matching ignore
  rules, while tracked files are not labelled ignored in immediate listings.
  Search has a 256-UTF-16 query limit, 200-result ceiling, 25,000-entry scan ceiling,
  and shared 15-second scan budget. Ranking is native, not upstream fff ranking.
- Filesystem workers use owned directory descriptors and nonblocking regular-file
  reads. Tests cover repeated enumeration, internal/dangling/escaping links,
  special nodes, named/resolved Git and bare/linked-worktree metadata, optional
  absence, strict UTF-8 and partial Unicode previews, binary rejection, stale
  revisions, same-byte inode replacement, executable mode, exclusive-create races,
  root replacement, and cancellation. Real Git ignore probes use bounded private
  input/output and sanitized context; a config FIFO verifies cancellation waits
  until the owned Git process has exited. Watch streams are ready before return,
  bounded/coalesced, and finished/drained on close.
- The inspector now uses background services end to end. Cached editors retain
  unsaved buffers through inspector visibility, tab, and conversation changes.
  Clean buffers reload on invalidation; dirty buffers and external bytes survive
  conflicts. Truncated previews are read-only. Normal Quit offers Cancel or an
  explicit discard choice. Native file/folder search inserts an escaped relative
  link into the captured conversation only, retaining selection, provider, queue,
  attachments, and drafts across restart. Last-owner cleanup drains editors and
  services; a shared-path surviving project retains both. Legacy synchronous
  compatibility reads/writes share anchored checks, and untracked Git diff reads
  now use the bounded async service.
- The full suite passed 257 tests: 212 core, 4 terminal, 13 Markdown, and 28 native
  UI/store. All 11 file-service core tests, the untracked Git-preview regression,
  and both new UI/store workflows ran, including real Git cancellation.
  Independent service and UI lifecycle
  reviews found no remaining blocker. No local interactive GUI test ran.
- Packaging/launch, strict deep app signing, and bundled-font rendering pass.
  The Xcode GUI runner compiles and passes strict deep signature verification.
  Canonical comparison confirms all 3 existing conversations, 25 messages, and
  non-identity project fields are unchanged; storage remains version 9.
- Hosted run 39690616352 passed the 243-test production suite and ran all three
  real GUI workflows without skips. Light/dark reached physical removal and
  displayed the complete warning; XCTest truncated its informative value at
  512 UTF-16 units. The grouping workflow reached the correct native folder but
  its global confirm-button query also matched an offscreen Touch Bar button.
  Harness queries now scope native panels/sheets and their observed identifiers.
  For the observed text-truncation boundary only, on-device Vision checks both
  warning concepts in retained native-alert pixels. All functional, copy, and
  geometry assertions remain enabled. Complete hosted GUI verification is pending.
- Revision saves are a guarded check followed by atomic replacement, with a final
  check-to-rename race against arbitrary external writers. They are not atomic
  cross-process compare-and-save. Content/regex search, host/remote file APIs,
  external-editor integration, and crash recovery remain pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — atomic group rename and removal

- Whole-group rename and removal validate every registration ID and literal
  checkout path. Removal additionally validates the full active/archived
  conversation union. Stale, missing, duplicate, moved, or regrouped members reject
  before changing any project. SQLite rollback tests preserve journal, receipts,
  preferences, leases, and effects; successful transactions replay after restart.
- The native removal sheet lists all checkout paths, explains retained files and
  recovery history, and warns about unsaved edits. Cancel preserves the group.
  Removal starts after dismissal so a stale-confirmation error remains visible.
- Every affected path locks before the first suspension. A real queued worktree
  assignment blocked by a separate SQLite writer commits before removal preflight;
  the new path remains locked even after its conversation disappears. Two-window
  PTY coverage checks targeted closure and surviving terminals. A held unrelated
  provider cleanup does not delay group completion. Shared inspectors and files
  remain usable afterward. Archived fallback stays visible and restores on restart.
- The full suite passed 243 tests: 200 core, 4 terminal, 13 Markdown, and 26 native
  UI/store. Independent source review found no remaining blocker. Hosted run
  39689027117 exposed an installed-Codex assumption in the preceding grouping
  fixture; that test now configures its injected ACP agent explicitly and passes
  locally without depending on a developer's installed Codex.
- The third hosted GUI workflow now includes native whole-group rename, physical
  mode headers, removal-sheet paths, Cancel/draft retention, confirmed removal,
  and unchanged Git HEAD/file checks. The gate still requires all three workflows
  without skips. Complete hosted GUI verification remains pending.
- Packaging/launch, strict deep app and runner signing, bundled-font rendering,
  and UI-runner compilation pass. No local GUI test ran. Canonical comparison
  confirms all 3 existing conversations, 25 messages, and non-identity project
  fields are unchanged; storage remains version 9.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — persisted logical checkout groups and conversation selection

- Registered projects now acquire credential-free repository identity on load,
  registration, and clone readiness through bounded native Git discovery. Request,
  path, and project-incarnation checks fence both successful and failed results,
  including explicit callers resuming after removal. Cleanup drains canceled
  discovery outside the command inbox. Failures preserve known identity without
  stopping agents; unchanged metadata does not add journal events or outbox work.
  The exact SQLite commit/actor-ack interleaving is source-reviewed; held-result
  and held-error tests reproduce removal and same-ID re-add boundaries.
- Repository, repository-and-folder, and separate-checkout modes derive groups
  while preserving physical project/thread records, fork identity, local folders,
  and duplicate-path registration references. Preferences persist grouping mode,
  physical-path overrides, expansion, and the future-conversation checkout.
  Activity includes eligible conversations across all members. Group moves retain
  untouched physical interleaving and reject stale order or membership; self drops
  are no-ops. Collapse retains the selected eligible conversation.
- Native menus expose physical checkout paths for new conversations and individual
  rename/removal. Clone badges and readiness use each thread's actual owner.
  Changing future checkout does not rebind a conversation, draft, queue, or agent.
  Removal confirms the captured path and leaves sibling checkouts open. The last
  selected conversation persists; archived selection restores the archived view.
- Storage 8 to 9 migration retains absent/default legacy fields and protects the
  new state from older writers. Journal replay covers identity, preferences, and
  selection. Tests cover invalid metadata, forks/worktrees, monorepo boundaries,
  duplicate physical paths, activity, stale commands, cleanup, clone readiness,
  nonfatal discovery errors, restart, and unchanged thread/runtime/outbox state.
- The full suite passed 235 tests: 195 core, 4 terminal, 13 Markdown, and 23 native
  UI/store. The final pass includes the error-side and public-continuation owner
  guards. Three CI-configuration tests pass, and the Xcode UI runner compiles
  without local GUI execution. A third hosted GUI workflow uses two private real
  Git repositories to check grouping, physical checkout routing, distinct drafts,
  mode changes, selection restoration, and unchanged HEADs. All three workflows
  must pass without skips; real hosted verification remains pending.
- Native packaging/launch, strict deep app/runner signing, and bundled-font
  runtime verification pass. A private backup preceded the real storage 8 to 9
  migration. Canonical comparisons confirm all 3 existing conversations, their
  25 messages, and every non-identity project field are unchanged. One existing
  project acquired repository metadata; no user checkout was added or removed.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — small-display window layout and native alert verification

- The third hosted run verified real Git HEAD and draft entry. The rename dialog
  appeared, but macOS omitted its SwiftUI text-field identifier; the test now
  scopes the single field to the observed native sheet and its Save control.
- Actual screenshots and accessibility frames showed a 1280-point default window
  extending beyond a 1024-point display, plus an oversized chat detail. Default
  sizing now fits the current display's visible area, and chat/detail containers
  accept smaller proposed widths. Large displays retain the 1280 by 820 default.
- Both hosted appearance workflows now require the entire window and each sidebar
  control to fit the actual display. All rename, draft, collapse, persistence,
  removal, and preserved-file checks remain enabled. The fourth hosted run
  confirmed unclipped light/dark geometry, rename, collapse, graceful restart, and
  retained draft/selection. It then stopped at the Add Project geometry lookup:
  macOS removes the image-derived identifier after relaunch, while the native
  title remains stable. The helper now queries that observed title and retains
  every existence/bounds assertion. Complete hosted verification remains pending.
- The full 220-test suite passed (183 core, 4 terminal, 13 Markdown, 20 native
  UI/store), including small-display sizing and offscreen narrow-detail checks.
  The Xcode UI runner compiled without launching a local GUI. Configuration tests,
  app packaging/launch, strict deep signing, and bundled-font verification passed.
  Canonical comparison confirmed the real workspace and its 3 conversations and
  25 messages are unchanged.

## 2026-10-22 — repository identity foundation

- Added native local Git identity resolution without remote access. Tests cover
  protocol/port and Azure aliases, nested names, IDNA hosts, SCP/IPv6 round trips,
  upstream/origin fork separation, fetch-only selection, bare repositories,
  nested and symlink roots, detached worktrees, and current configuration reads.
- Returned URLs strip authentication, queries, and fragments; encoded host
  delimiters and inconsistent stored metadata are rejected. Inherited Git context
  and trace variables cannot redirect discovery or write trace files. Metadata is
  bounded, errors omit raw Git diagnostics, and cancellation waits for Git exit.
- All nine focused tests and the full 218-test suite passed (183 core, 4 terminal,
  13 Markdown, 18 native UI/store). Independent source review found no remaining
  blocker. Existing workspace models and storage version 8 are unchanged.

This is a tested core foundation. Persisted identity enrichment, grouping
preferences, and the grouped sidebar remain pending.

## 2026-10-22 — native project removal and hosted GUI test foundation

- Added confirmed project removal covering active and archived conversations in
  one journal/projection/receipt transaction. The confirmation includes the exact
  conversation set; a new conversation requires renewed confirmation. Pending
  actions cancel atomically, running actions retain their executor leases, and
  exact action identities fence late registration and cancellation. Provider,
  clone, and owned model operations wait across the removal commit/acknowledgement
  window. Old model results cannot attach to a re-created owner with the same IDs.
- Runtime handles detach before publication. Tracked cleanup waits outside the
  serial inbox, so unrelated projects remain responsive while processes close.
  All registered native windows close only the removed conversations' terminals.
  Pending imports/worktree setup and clone retries cancel, drafts/model caches and
  stale selection/navigation clear, and inspectors with surviving path references
  remain open. Coincide does not delete checkout, worktree, staging, or attachment
  files. Git can clean up its own unfinished files when an active clone stops;
  the removal confirmation and documentation explicitly qualify that case.
  Append-only recovery history remains; the confirmation does not promise erasure.
- File edits register dirtiness synchronously. Project editor scopes freeze
  before waiting for earlier UI commands, and a queued preflight checks for newly
  dirty buffers. Rejected removal releases the scopes. Shared workspaces stay
  locked through cleanup and become editable again for surviving owners. Stale
  file callbacks cannot reopen an unreferenced workspace.
- The full SwiftPM suite passed 209 tests: 174 core, 4 terminal, 13 Markdown, and
  18 native UI/store tests. New regressions cover stale/duplicate confirmations,
  empty projects, receipt replay/collision, transaction rollback, restart/journal
  rebuild, saturated pending/running effects, slow close responsiveness, same-ID
  metadata reuse, late clone events, preserved file/attachment bytes, terminals in
  two window owners, never-finishing paste cancellation, shared inspector paths,
  dirty-buffer confirmation, edit locks, and stale navigation. The full suite
  passed again after the final catch-side metadata guard found during review.
- Native packaging/launch, strict deep signature checks, and bundled-font runtime
  verification passed. A private backup and canonical JSON comparison confirmed
  storage version 8 and all existing 3 conversations/25 messages are unchanged.
- Added a test-only Xcode UI runner exercising the SwiftPM-built app through real
  macOS windows, menus, keyboard input, and screenshots. The runner compiles and
  passes strict deep signature verification without launching a local GUI. Its
  three configuration tests and workflow lint pass. The CI script refuses local
  GUI execution. A copied app uses a dedicated bundle identifier and DEBUG-only
  private workspace; invalid test configuration cannot fall back to user data.
  Hosted light/dark workflows cover project creation and initial Git commit,
  rename/collapse, retained selection/draft, and graceful quit/reopen. The first
  hosted run passed all 209 SwiftPM tests but both GUI tests failed before app
  launch: Xcode's generated runner is sandboxed and could not create fixtures in
  shell-owned scratch. Fixtures now use the runner's Foundation temporary
  directory; screenshots remain retained XCTest attachments exported after the
  run. A second hosted run reached project creation in both appearances but its
  Git verification child exited unsuccessfully; the harness now resolves the
  actual developer Git executable outside the runner sandbox and retains command
  diagnostics. Recordings confirm readable selected rows and symbols in the live
  light/dark app, unlike the earlier offscreen captures. Later frame diagnostics
  identified window and content overflow; see the small-display entry above.
  The workflows now also
  test Cancel/confirmed removal, draft retention, and preserved README/icon/HEAD
  bytes. Local compile/configuration checks pass; the complete hosted workflows
  and screenshot review remain pending.

Full T3 Code parity remains incomplete; see `PORTING.md` for the remaining areas.

## 2026-10-22 — persistent native project organization

- Added native project collapse/expand, display-name editing, a project-sort menu,
  and Manual drag/context-menu ordering. Collapse retains the selected eligible
  conversation; existing search/archive filters still apply. It does not alter
  drafts, queues, provider connections, or running turns. Rename preserves project
  and thread identities, checkout paths, clone state, and canonical manual order.
- Last user message is the default sort. Ranking includes accepted queued input
  before provider execution, and later assistant/tool activity cannot outrank an
  existing user-input date. Created at ranks by the newest nonarchived conversation
  in each project. Empty projects use their available project timestamps; legacy
  projects without dates retain their relative canonical order. Dated ties use
  localized title and stable identity. Search and archived-view filters do not
  rewrite the activity score.
- Switching sort modes retains the exact saved Manual order. Moves require
  Manual mode and the current expected project order; stale moves are rejected
  without partial reordering. Native multi-row moves commit one complete order.
  Preferences and rename/order mutations use journal events with command receipts
  and transaction rollback. Default-expanded/default-activity preferences and
  absent legacy project dates decode without synthetic migration timestamps.
  Storage version 8 prevents older binaries from dropping the new state.
- `COINCIDE_RENDER_ORGANIZATION=1 swift test --no-parallel` passed all 197 tests:
  166 core, 4 terminal, 13 Markdown, and 14 native UI/store tests. Coverage includes
  user/assistant/queued dates, newly created threads, archived exclusion, invalid
  dates, stable fallbacks/ties, Manual round trips, multiple-index moves, rename
  validation, deduplication, concurrent/stale commands, malformed preferences,
  atomic rollback, restart, projection rebuild, and storage 7 → 8 compatibility.
  A gated provider regression confirms queueing changes activity ranking while
  leaving the active run and transcript intact, then drains that queue normally.
- Native packaging/launch, strict deep signature verification, and bundled-font
  runtime verification passed. A private backup preceded the actual storage
  migration from 7 to 8. Canonical JSON comparison confirmed the existing
  3 conversations and 25 messages were unchanged, with old project dates unset.
- Offscreen AppKit captures at 280 and 340 points were inspected in light/dark
  appearance. Headers, layout, and row presence are visible. The light selected
  row appears black, and some SF Symbols stay dark. These captures do not establish
  whether that is a capture limitation or a live rendering issue. Live contrast,
  pointer drag behavior, menus, and keyboard interaction remain
  unverified while the desktop is locked; no production palette workaround was
  added to conceal that verification limit.

Logical checkout grouping, project removal/cleanup, and the other remaining areas
in `PORTING.md` are still required for full T3 Code parity.

## 2026-10-22 — managed native New Project

- Added a focused-window New Project sheet and File/sidebar actions. Creation
  runs off the main actor, while existing workspace commands remain usable.
  A single journal command saves the prepared project and first conversation
  together; invalid starters, duplicate paths/identities, and command collisions
  leave the existing workspace intact. The first conversation uses the created
  folder, and saved titles/drafts survive restart and projection rebuild.
- Managed folders live under Coincide's application-data `Projects` directory.
  Folder names follow the pinned upstream NFKD/ASCII slug rules, 64-character
  truncation, reserved-name suffixes, and up to 100 atomically claimed collision
  candidates. Display names remain intact, with the upstream 200-UTF-16-unit limit.
  Unicode line separators are rejected; emoji ZWJ sequences remain valid.
  Existing files, directories, and symlinks are preserved.
- Git initialization respects `init.defaultBranch`, falling back to `main`.
  Coincide generates its own README and SVG icon, force-stages those two paths
  despite global ignore rules, then attempts `Initial commit`. Git identity,
  hooks, and signing settings are retained. Missing identity, failed signing or
  hooks, and commit timeout produce a visible Project Created warning with a
  usable repository; they do not offer a second Create action for that result.
- Git mutations explicitly target the new `.git` and worktree, and inherited
  Git directory/index/config overrides cannot redirect staging into another
  repository. Diagnostics are bounded and URL credentials are redacted. Setup
  failures report the preserved folder for recovery. Shutdown cancels owned
  creation tasks before draining accepted workspace commands; a cancelled setup
  never registers an unfinished project. Cancellation after registration has been
  accepted does not undo a saved project or delete its files.
- `swift test --no-parallel` passed all 172 tests: 143 core, 4 terminal,
  13 Markdown, and 12 native UI/store tests. New real-Git fixtures use isolated
  identity/global configuration and cover starter content/commit, configured
  branches, global ignores, missing identity, signing/hook/timeout warnings,
  collision exhaustion, concurrent claims, unsafe inherited Git context,
  cancellation, and recovery paths. The cancellation fixture observes its hook
  process exiting; it does not require a killed hook to write a final marker.
  A store test opens the same folder during creation and confirms registration
  refusal preserves the already-open project and prepared files.
- Light/dark offscreen AppKit captures of the native sheet and commit-warning
  content were inspected. Native packaging/launch, strict deep signature checks,
  and bundled-font runtime verification passed. Storage remains at version 7;
  canonical JSON comparison confirmed the existing 3 conversations and 25
  messages were unchanged. Physical menu, keyboard, and sheet interaction still
  need an unlocked desktop. Live signing-provider interaction and behavior under
  an active same-user process replacing project directories remain unverified.
  Timeout tests do not establish complete arbitrary hook-descendant cleanup.

Project rename/removal, collapse, sorting/reorder, hosting/publishing, and other
remaining work in `PORTING.md` are still required for full parity.

## 2026-10-22 — native background repository cloning

- Added a native Clone Repository sheet, focused-window File command, sidebar
  status, and conversation progress/cancel/retry controls. A project and its first
  conversation appear after one atomic journal/outbox commit, while Git runs
  separately. Drafts remain editable, submitted turns retain their configuration
  and attachments, and no provider or workspace terminal starts before the
  checkout is ready. Other projects remain responsive during a gated clone.
- Clone attempts use distinct private staging folders and never replace an
  existing destination. Git runs with a retained checkout directory as its working
  directory; metadata uses retained directory handles. Identity checks surround
  completion-marker writes and exclusive promotion. Gated tests replace the
  checkout, staging folder, or parent while Git runs, and verify writes stay in the
  original checkout and replacement folders receive no completion marker.
  These checks do not claim atomic source-identity protection against an active
  same-user process swapping paths between the check and rename.
- Cancellation stops the owned Git process group and awaits cleanup. A lost-child
  observation disables all later signals and closes only owned pipe readers;
  a regression reaps the fixture child early while another helper retains its
  pipes, then verifies no process signal was attempted. Bounded backpressure
  preserves raw stderr chunks before CR/LF parsing and URL redaction. Stress
  fixtures exercise 40,000 progress frames, split UTF-8, oversized remote noise,
  cancellation under continuous output, and stalled progress.
- Unexpected FIFO metadata and lock files fail promptly without being removed.
  Directory descriptors are kept above standard input/output descriptors before
  spawn actions; that closed-stdio edge was source-reviewed, not tested by closing
  the shared test runner's descriptors. Existing Git credentials and SSH setup are
  retained; interactive credential prompts are disabled. Password/userinfo HTTP
  URLs and query/fragment sources are rejected before journal or outbox persistence.
- Retry uses a fresh attempt and preserves previous staging folders. Coincide
  does not delete partial files, although Git may roll back its own failed clone;
  partial network transfers are not resumed. Late Cancel and restart first inspect
  local ownership/completion evidence. Restart never reruns a lost clone or sends
  waiting messages automatically. Explicit Cancel holds queues even if the clone
  finished at the same moment. Stale attempt callbacks cannot alter a retry.
- `swift test --no-parallel` passed all 148 tests: 122 core, 4 terminal,
  13 Markdown, and 9 native UI/store tests. Real Git fixtures clone isolated local
  bare repositories and file URLs, including paths with spaces. Engine/store
  tests cover queue order, captured options/attachments, failure/retry, held
  queues, restart, completion recovery, privacy, and atomic effect-ID collisions.
  Light/dark offscreen AppKit captures of the sheet and six progress/error states
  were inspected. Native packaging/launch, strict deep signature verification,
  and bundled-font runtime verification passed. A private backup preceded the
  actual workspace migration from storage 6 to 7; canonical JSON comparison
  confirmed all 3 existing conversations and 25 messages were unchanged.
  Physical menu, sheet, and keyboard QA still needs an unlocked
  desktop; live SSH/HTTPS authentication and network recovery remain unverified.

This establishes native background cloning, not full T3 Code Git parity.
Managed New Project, project organization/removal, PR/stack/host integrations,
checkpoints, and broader worktree lifecycle behavior remain open.

## 2026-10-22 — native Git branches and synchronization

- Replaced the HEAD-dependent status read with a single NUL-delimited
  [porcelain v2](https://git-scm.com/docs/git-status#_porcelain_format_version_2)
  snapshot. Empty repositories, detached HEAD, missing upstream commits,
  ahead/behind counts, rename paths, submodules, and conflicts now have explicit
  native state. Nested project folders resolve repository-relative paths against
  the actual worktree root, including roots and filenames containing newlines.
- Added native initialization, branch creation/switching, remote branch tracking,
  fetch, clean fast-forward pull, and explicit single-branch push controls. Pull
  overrides rebase/squash/autostash configuration; divergence leaves the current
  commit intact. Push overrides mirror configuration and uses an explicit refspec,
  with force updates and automatic tag propagation disabled. Pre-push hooks remain
  active. Existing credential helpers and SSH configuration are reused; secrets
  are not copied into app settings, and URL userinfo/query/fragment are removed
  from error messages.
- Git mutations share a cancellable FIFO keyed by the common Git directory, so
  linked worktrees and multiple windows serialize their operations. Literal NUL
  path input prevents pathspec expansion and command-line-size limits. Unstaging
  an initial file removes only its index entry, preserving newer worktree bytes.
  Repository initialization refuses an existing or containing repository.
- Native inspector state survives switching panels and is owned by the workspace.
  Application shutdown cancels and awaits its mutation, status, and diff tasks.
  A regression cancels a commit while its hook is waiting and verifies that no
  commit was made and staged file bytes remain. Another cancels a waiting push
  hook and verifies that no remote branch or tracking configuration was created.
  Cancellation now consistently surfaces as `CancellationError` in CommandRunner.
- Real Git tests use isolated local bare repositories and two working copies.
  They cover initial commits, modified initial-file unstaging, literal magic-like
  paths, nested roots, renamed/newline paths, detached state, preserving edits on
  checkout failure, remote tracking, fetch/pull/push, divergent history, conflict
  resolution, mirror/force/matching/tag configuration, remote names containing
  equals signs, deleted tracking refs, hooks, cancellation, and queued mutations.
  These tests do not establish live SSH/HTTPS authentication or network recovery.
- `swift test --no-parallel` passed all 120 tests: 97 core, 4 terminal, 13 Markdown,
  and 6 native UI/store tests. The Git inspector/store tests exercise initialization,
  staging, first commit, branch switching, recoverable errors, and app shutdown.
  Light/dark offscreen AppKit captures were inspected at 280- and 420-point widths.
  Native packaging, launch, strict signature checks, and bundled-font runtime
  verification passed. Physical menu, sheet, and keyboard interaction still needs
  unlocked-desktop QA.

Clone/progress/retry, PR/stack/host integrations, checkpoints, worktree cleanup and
setup, automatic-pull policies, and comprehensive network/credential recovery
remain open Git parity work. No external repository was used by these fixtures.

## 2026-10-22 — opt-in ACP v2 connections and foreground lifecycle

- Added an opt-in native adapter for the current ACP v2 draft, using the same
  [official schema baseline](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/schema/v2/schema.json)
  (`e47fe81d2db877fe182bdca2ce4ac52ffd62ec61`) inspected for transcript entities.
  Initialization supplies v2 `info`/`capabilities` plus legacy fields for agents
  choosing v1. A v1 result adopts the existing connection without another process
  or handshake. The per-agent **Use ACP v2 (experimental)** switch defaults off.
- Prompt responses associate the inserted native user ID with its client command;
  they never imply completion. Foreground state updates control busy/action/idle
  state independently of pending session-level permission requests. Native
  agent-initiated work creates no synthetic user message. Early setup/resume
  notifications are drained in order, and repeated idle snapshots do not complete
  a new submission. Unknown idle outcomes end busy state but hold the queue.
- Native select/boolean options use v2 `configId` and the schema's `id`/`boolean`
  request value types. Each queued turn captures its own typed configuration.
  Reset Agent Options clears overrides without changing saved invocations.
  Native settings/store tests verify experimental-mode and boolean persistence.
- Permission responses use a runtime-pinned outbox action, so a background request
  can remain pending through another foreground turn. Resolving one of several
  requests never infers that the agent has resumed; its state update is authoritative.
  Rejected and unconfirmed user submissions retain visible error information and
  are never automatically retried. Request cancellation before insertion uses
  `$/cancel_request`; active work uses `session/cancel`. Unresponsive cancellation
  stops only the owned process after the configured timeout.
- The transport now retains JSON-RPC error code/data and can deliver a request's
  outcome in order with notifications and disconnection. A regression confirms
  acceptance is associated even when the peer immediately exits. Other tests cover
  echo-before/after acceptance, idle-before-ack, repeated idle, pre-insertion hook
  failure, lost acceptance response, concurrent/background permissions, autonomous
  activity, resume while waiting for permission, cancellation before/after insertion,
  unknown outcomes, queue configuration, and journal rebuild after restart.
- Review found a startup Stop race: an early native running snapshot could make
  Stop available while configuration was still waiting. The adapter now cancels
  that unsent input and checks cancellation after setup/configuration. A gated
  regression verifies the start effect becomes cancelled and the peer never receives
  `session/prompt`, even after releasing its delayed configuration response.
- The complete suite passed 107 tests (86 core, 4 terminal, 13 Markdown, 4 native
  UI/store) with Codex/Claude discovery and image/file turns, OpenCode discovery
  and a real marker turn, and the v2-negotiation marker turn enabled. Installed
  OpenCode selected **v1**, and fallback completed a real turn. This is not live
  v2-server validation; the v2 lifecycle cases use deterministic stdio peers.
- Native packaging, launch, strict signature verification, and bundled-font runtime
  verification passed. A private backup preceded storage migration 5 → 6; canonical
  comparison excluding only new optional fields preserved all 3 existing
  conversations and 25 messages. Physical interaction with the new settings and
  state/error UI remains part of unlocked-desktop QA.

The v2 protocol is still a draft. Older draft variants, live v2-provider checks,
native authentication/elicitation, managed agents, session browsing/import/fork,
live notices, richer media, and display-terminal UI remain open parity work.

## 2026-10-22 — durable provider transcript entities

- Added native transcript entities keyed by session, type, and opaque ID. The
  reducer preserves structured content and unknown fields, applies omitted/null/
  replacement semantics, patches `_meta` by top-level key, and keeps chunk metadata
  separate. Binary terminal chunks decode independently before appending; complete
  terminal snapshots replace prior bytes. Plans, compaction summaries, and unknown
  future updates retain their payloads.
- The entity reducer follows the current official
  [ACP v2 entity rules](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle)
  and [tool/terminal updates](https://agentclientprotocol.com/protocol/v2/tool-calls).
  The inspected official schema's Git blob was
  `e47fe81d2db877fe182bdca2ce4ac52ffd62ec61`. The v2 wire adapter is not implemented
  yet; these tests do not establish v2 connection or foreground-lifecycle support.
- ACP v1 tool updates now use these entities, preserving their input/output,
  locations, status, and other metadata. The native disclosure shows the tool
  title/status, input, output, files, and raw details. Its v1 adapter filters null
  updates according to v1 semantics before applying the native patch.
- A gated protocol test waits for the engine to become idle before allowing the
  fixture to send background tool output. The update is saved without starting a
  new turn and survives journal rebuild. Restart/resume tests now verify three
  distinct tool identities and their input/output across three turns.
- Tests also cover entity-ID collisions between types/sessions, streamed-content
  replacement and clearing, unknown variants/content, plan envelope fields,
  metadata-only journal changes, stale runtime events, and native user-message
  association with echo arriving before or after acceptance. Original local text
  and timestamps are preserved; equal content never establishes identity.
- Malformed entity updates fail their owning runtime while the workspace command
  engine remains usable. A regression sends another turn and completes it with a
  new provider connection after that failure.
- `COINCIDE_LIVE_ACP=1 COINCIDE_LIVE_ACP_TURN=1 COINCIDE_ACP_TEST_MODEL=opencode/glm-5.3-flash-free swift test --no-parallel`
  passed all 93 tests: 72 core, 4 terminal, 13 Markdown, and 4 native UI/store.
  Installed OpenCode discovery and a generated-marker turn passed again.
- Packaging, launch, strict signature verification, and bundled-font verification
  passed. A private SQLite backup preceded storage migration 4 → 5; canonical
  comparison excluding only the new optional entity field confirmed all 3 prior
  conversations and 25 messages were unchanged. Physical interaction with the new
  tool disclosures remains part of unlocked-desktop QA.

## 2026-10-22 — native ACP v1 agents

- Added a native JSON-RPC 2.0 stdio adapter following the official
  [initialization](https://agentclientprotocol.com/protocol/v1/initialization),
  [prompt lifecycle](https://agentclientprotocol.com/protocol/v1/prompt-turn), and
  [configuration](https://agentclientprotocol.com/protocol/v1/session-config-options)
  contracts. No T3 server or JavaScript adapter is launched by Coincide.
- Deterministic tests cover streaming, images, reasoning, tool updates, plans,
  opaque permission options, model/mode changes through both legacy fields and
  grouped config options, unsupported versions/images/resume, authentication
  errors, concurrent discovery, and cancellation (including an agent that ignores
  Stop). Client filesystem, terminal, authentication, and elicitation capabilities
  are not advertised yet. Unknown configuration categories keep their select UI.
- The native engine test confirms a start effect settles while a permission is
  still waiting; two queued turns complete through exact permission responses.
  After shutdown/reopen, the same native session loads and completes another turn
  without duplicating its replayed history. Event barriers drain already-decoded
  notifications and release their waiters on cancellation or connection close.
- Native store tests cover saving, selecting, editing, removing, and reopening
  agent configurations. Existing conversations retain their captured invocation.
  Light/dark offscreen AppKit settings captures were inspected. Physical settings,
  permission-button, and keyboard interaction still need unlocked-desktop QA.
- Real installed OpenCode initialized, advertised models through config options,
  and completed a generated-marker turn through the native engine using the
  advertised `opencode/glm-5.3-flash-free` model. The agent's default
  `opencode/flint-40b-free` failed after roughly 91 seconds with
  `Endpoint is unavailable`; this service failure remains recorded. No sign-in,
  provider installation, credential changes, or user files were needed.
- A combined live-provider check also exercised Codex and Claude attachment turns.
  One Codex OCR response substituted an en dash for the image marker's hyphen.
  The fixture now uses letters and digits to avoid that visual ambiguity; its
  exact independent image/file-marker assertion remains unchanged.
- The complete offline suite passed 84 tests: 63 core, 4 terminal, 13 Markdown,
  and 4 native UI/store tests. A combined run enabling live Codex/Claude discovery,
  both image/file cases, OpenCode discovery, and its native-engine turn also passed
  all 84 tests. CI keeps live-provider checks opt-in. The preceding
  transport fix passed [GitHub CI](https://github.com/apoorvdarshan/coincide/actions/runs/39667658837)
  with every test retained and the original one-second deadline assertions.
- Packaging, launch, strict signature verification, and bundled-font runtime
  verification passed. A private SQLite backup preceded storage migration 3 → 4.
  Canonical comparison excluding only new ACP fields confirmed all 3 existing
  conversations and 25 prior messages were unchanged.

ACP v2, registry/managed installs, native authentication and elicitation, delegated
filesystem/terminal operations, richer content/config types, session browsing and
import, and provider-specific features remain pending. These checks establish a
working ACP v1 integration, not full ACP or T3 Code parity.

## 2026-10-22 — durable native attachments

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 COINCIDE_LIVE_ATTACHMENTS=1 swift test`
  passed all 74 tests: 54 core, 4 terminal, 13 Markdown, and 3 native UI/store tests.
  The installed-provider attachment test ran two real-provider cases. CI leaves
  the provider-dependent discovery/model-turn checks disabled.
- Real Codex and Claude each read a random marker rendered into a synthetic image
  and a different random marker stored in an attached text file. Both returned the
  exact combined markers through the native command engine. The final two-provider
  smoke check passed in about 11 seconds after the transport correction below.
  No user file was attached, no network tool was permitted, and only the generated
  text file's Claude Read approval could be accepted by the test.
- Tests verify immutable private copies after source deletion, mode 700 directories
  and mode 600 files, image type detection, TIFF conversion, resizing, SVG-as-file
  handling, long names, size/count limits, checksum changes, symlink rejection,
  attachment-only queued turns, draft/queue/history restoration, queue editing,
  native image payloads, and attachment-only journal mutations. Storage version 3
  prevents older builds from silently discarding these references.
- Native NSItemProvider tests cover file-URL paste, image-data paste, concurrent
  imports, partial failure, removal, and persistent drafts. Cancellation also
  completes when a provider never calls back, so shutdown cannot wait indefinitely
  for clipboard data. Light/dark offscreen AppKit captures of the attachment shelf
  and image preview were inspected. Actual keyboard-paste/drop and copy/save-panel
  interaction still require an unlocked-desktop smoke check.
- Provider transports now allow bounded 128 MiB incoming frames for image-bearing
  messages; the default transport limit remains 16 MiB. The incremental decoder
  scans only newly appended bytes. A 17 MiB fragmented-frame regression verifies
  decoding and the smaller default's rejection.
- A blocked-stdin regression crashed the previous implementation with SIGPIPE.
  Provider input now uses per-descriptor signal suppression and a serial queue of
  nonblocking writes. RPC actors remain responsive during backpressure; timeout,
  cancellation, and close stop a partial frame without replay. Tests also verify
  whole-frame concurrent writes and cancellation before a write starts. The
  previously crashing regression passed, as did the complete suite and real
  Codex/Claude image/file turns after the fix.
- GitHub's slower runner then exposed an additional responsiveness failure while
  a large JSON payload was being serialized. Encoding now runs on the serial input
  queue, outside the protocol actor and Swift's cooperative executor. Cancellation
  before pipe writing begins leaves the connection intact. The deadline assertions
  remain unchanged; the full 74-test suite and both live attachment cases passed
  again locally after this correction.
- A subsequent hosted run still missed the deadline while many process, PTY,
  image-rendering, and database tests launched concurrently. The measured interval
  also included constructing the 8 MiB test string before the RPC timer existed.
  The fixture payload is now prepared before timing, and CI runs every test with
  `swift test --no-parallel` to keep process-startup contention out of timer checks.
  The same timeout, close paths, payload size, and one-second assertions remain.
- Native packaging, launch, strict signature verification, and bundled-font
  runtime verification passed. A private backup preceded migration of the real
  workspace from storage version 2 to 3. Canonical comparison, excluding only new
  empty attachment defaults, confirmed all 3 conversations and 25 prior messages
  were unchanged.

Removed or failed-import attachment copies are retained for now; reference-aware
cleanup is pending. Files remain local, and remote upload, question attachments,
long-paste conversion, prompt stash, and larger source-image handling are not yet
implemented. This does not establish full T3 attachment or overall feature parity.

## 2026-10-22 — native display equations and packaged fonts

- Added SwiftMath 1.7.3 at the locked revision, with its MIT notice and original
  font bundle/licenses. SwiftMath uses native CoreText rendering. Display formulas
  accept closed, standalone `$$` or `\[` / `\]` blocks and closed `math` code
  fences, including fences nested in quotes. Incomplete fences stay as code.
- The complete local suite passed 60 tests: 43 core, 4 terminal, and 13 Markdown.
  Math tests check Markdown characters retained inside formulas, protected code
  and HTML, prices, incomplete delimiters, nested fences, bounded parsing of many
  unfinished formulas, font loading, fractions/integrals/matrices, invalid-command
  fallback, and expression-size/nesting limits. A final focused math run passed
  after excluding protected code/HTML from closing delimiters.
- Native light/dark offscreen captures include the typeset quadratic formula and
  its Copy LaTeX control. Original message text remains available through response
  copy. Oversized or unsupported expressions display source rather than disappearing.
- Packaging copies the SwiftPM font resource bundle. `--verify-resources` renders
  a formula before starting the app, without opening a workspace, provider process,
  or window. CI now runs this check after bundle/signature verification.
- Native packaging and strict signature verification passed. The resource check
  also passed from a temporary relocated copy of the complete app; that copy was
  removed afterward. Both earlier Markdown commits passed GitHub Swift CI.

Inline formulas, same-line display delimiters, display delimiters nested in quotes,
and full upstream math syntax remain pending. This does not claim KaTeX-level
coverage, interactive copy verification, or complete T3 transcript parity.

## 2026-10-22 — native Markdown transcript

- Added Swift Markdown 0.9.0 and Swift cmark 0.9.0 at the revisions locked in
  `Package.resolved`. Their original licenses/notices are bundled in the app.
  Rendering uses SwiftUI/AppKit; there is no webview or JavaScript renderer.
- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed 56 tests:
  43 core, 4 terminal, and 9 Markdown. New coverage includes nested inline styles,
  streamed unfinished code fences, GFM tables/tasks/lists, inert HTML, rejected URL
  schemes, workspace containment and symlink escape, line-number links, Unicode
  syntax coloring, large-input fallback, cache isolation, and UTF-16 line selection.
- Native offscreen AppKit hosting-window captures were inspected in light and dark
  appearance. They contain the rendered code, tables, list numbering, task states,
  nested lists, and inline styles. Inspection exposed table sizing/alignment issues,
  which were corrected. SwiftUI ImageRenderer alone omitted scroll-view content,
  so those initial images were not used as evidence of code/table rendering.
- File links open the inspector's native text editor with the requested line
  selected. The editor preserves unsaved-change confirmation, conflict-checked
  writes, standard undo, and workspace path checks. The line calculation is tested;
  a full interactive file-link/copy-control smoke check is still pending because
  the desktop was locked during this milestone.
- Development app packaging and strict signature verification passed.
- Repeating packaging exposed read-only dependency notice files copied from the
  package checkout. The script now installs notices with mode 644. Two consecutive
  packaging runs and signature verification passed after that correction.

Code highlighting is lexical and limited to common language families. Unknown or
large code blocks retain plain source. Images currently retain their alternative
text and safe link; media previews, mathematics, and full upstream Markdown
extensions remain pending. This is not a full transcript-parity claim.

## 2026-10-22 — native command engine and queued turns

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed 47 tests:
  43 core and 4 terminal. Installed-provider tests perform only handshake/model
  discovery; deterministic fixtures verify execution and failure behavior.
- Runtime tests cover ordered queues and captured configuration, durable command
  retries/rejections, responsive approvals while start acknowledgement is pending,
  reserved control capacity with eight blocked starts, stale run/connection events,
  questions, native interruption, Stop during startup, process loss, concurrent
  draft/pin edits, queue editing, restart, exclusive ownership, and lost effect leases.
- A controlled Codex fixture completes two turns before acknowledging their start,
  starts a third, and then delivers the older acknowledgements. The previous guard
  failed by targeting a completed turn on interrupt; the corrected implementation
  passed and targets the third turn. The source was restored after that comparison.
- Native Claude QA sent two prompts in rapid succession. The second appeared in the
  queue, both expected markers arrived in order, and the thread returned to idle.
  A later long response was stopped with a queued message waiting. The app held the
  queue, preserved the same queued ID across a graceful rebuild/restart, and returned
  the expected marker after **Resume Queue**. No queued turn replayed on restart.
- Native Codex QA created a conversation, typed directly into the automatically
  focused composer, and submitted with Return. The real provider returned
  `COINCIDE_NATIVE_ENGINE_CODEX_OK`; state returned to idle and the outbox recorded
  success. These model prompts requested no tool or filesystem actions.
- The database was backed up before migration. Stripping only the newly added
  queue/runtime fields produced an identical canonical snapshot: the existing
  project, both conversations, and all 14 prior messages were preserved. Storage
  version 2 prevents older binaries from silently discarding the new fields.
- Final native development packaging, launch, and strict code-signature
  verification passed after the lease-ownership failure handling change.

This establishes the native orchestration milestone, not full T3 parity. Provider
effects cannot guarantee exactly-once external execution. The current projection
cache still writes a full snapshot; broader live approvals, all providers, remote
environments, checkpoints, and complete transcript rendering remain pending.

## 2026-10-22 — transactional provider outbox foundation

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: all 33 tests passed
  across core (29) and terminal (4). New tests verify atomic effect/intent rollback,
  logical command retries after newer state commits, concurrent claims, owner and
  expiry fencing, lease renewal, failure handling, and cancellation after process
  loss. Expired process-bound effects are not automatically reclaimed or replayed.
- Turn-start, interrupt, and approval/answer intents have typed Swift payloads.
  Turn configuration excludes transcript history and credentials. Pending effects
  commit with the journal, projection, command receipt, and audit marker.
- Native development packaging/launch and strict signature verification passed.
  Canonical JSON comparison confirmed that adding the outbox tables left both
  existing conversations and all 14 messages unchanged.

This is the durable outbox API and its failure/ownership contract. The desktop
still dispatches provider actions directly after persistence; the execution
worker, normalized decisions, and queued-message UI are not yet wired in.

## 2026-10-21 — replayable workspace journal

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: all 29 tests passed
  across core (25) and terminal (4). New coverage includes replay of streaming
  Unicode combining marks, reorder/truncate/removal, concurrent command-ID
  deduplication, stale revision rejection, legacy import, projection rebuild,
  SQLite transaction failure/rollback, empty history, and future/incomplete data.
- Events, projection, receipt, and audit marker commit together. A trigger that
  failed the last transaction write left no partial journal events, receipt, or
  projection change; retrying that command after removing the fault succeeded.
- The app's existing database was backed up before migration. Canonical JSON
  comparison confirmed that its project, both conversations, and all 12 existing
  messages were unchanged after the native app imported the legacy snapshot.
- A real Claude turn through the migrated native app returned
  `COINCIDE_JOURNAL_SMOKE_OK` and finished `idle`. The journal recorded metadata,
  message-upsert, and streamed text-append events for that turn. Development
  packaging and strict code-signature verification passed.
- The database and its WAL/SHM files use private permissions. Replay reads one
  record at a time rather than materializing the whole journal in memory.

The desktop currently derives journal mutations from serialized snapshot writes.
The explicit commit API deduplicates stable command IDs; the convenience `save`
API creates a fresh ID for each call. Normalized domain commands, a transactional
effect outbox/worker, queued turns, and incremental projection storage still need
to be implemented. No exactly-once provider execution is claimed.

## 2026-10-21 — native terminal

- Added SwiftTerm 1.99.1 at locked revision
  `2f573f73af5e768d90847dce20c97fa9535d7164`, with the native macOS frontend and
  PTY backend. No browser terminal or Node terminal service is involved.
- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test` passed all 23 tests
  across the core (19) and terminal (4) test targets. Focused terminal tests were
  repeated after the final accessibility/focus change. Tests verify an actual
  PTY in a workspace containing spaces, Unicode/ANSI rendering, final output and
  exit status, PTY resize, interrupt while keeping the shell alive, closure of
  the foreground job, idempotent close, and rejection of an unavailable folder.
- Native UI QA typed and observed `COINCIDE_TERMINAL_UI_OK`, the workspace path,
  and markers in two separate terminal tabs. Hiding and showing the panel kept
  a shell variable set to `kept`. Creating or closing a tab correctly focused
  the resulting terminal. The terminal exposes its visible text and a focus
  action through accessibility; full screen-reader text navigation needs work.
- Rebuilds now ask only this repository's development bundle to quit through
  AppKit, wait for it to finish, and stop the build if it refuses. They do not
  force-quit another installation. Rebuild QA recorded both owned shell PIDs and
  verified that neither survived shutdown. Workspace close/open events were
  also persisted. The bundled SwiftTerm and T3 license notices were verified,
  and strict code-signature validation passed.
- After further binary rebuilds, Claude model discovery from the native header
  completed in about 0.7 seconds with the stable development signature. It no
  longer stalled on the Documents permission request seen with ad-hoc rebuilds.

Terminal history and processes currently survive panel hiding and thread changes
within a window, not application restarts. Remote terminals, durable attachment,
search/settings, and broad terminal compatibility remain pending.

## 2026-10-21 — Claude and native chat interface

- `COINCIDE_LIVE_CLAUDE=1 COINCIDE_LIVE_CODEX=1 swift test`: 19 tests passed.
  The live tests list models without running model turns. Offline Claude fixtures
  verify streaming/snapshot reconciliation, repeated turns, approval/decline,
  user questions, cancellation, interruption, provider failure, and old workspace
  decoding with the new provider/draft fields.
- Native UI QA verified the ChatGPT-style layout, new-conversation provider menu,
  rounded composer, hidden-by-default inspector, and live Claude text responses.
  Two consecutive real turns returned `COINCIDE_CLAUDE_SMOKE_OK`; a later turn
  after an app restart resumed the same Claude session and returned the marker
  from its conversation history. The resulting thread returned to `idle`.
- Startup initially timed out while macOS awaited Documents-folder consent for
  this machine's shared CLI instructions. Unified logging confirmed the TCC
  request and that ad-hoc rebuilds invalidated the previous code requirement.
  Consent was granted through the native macOS dialog. Local build scripting now
  uses an existing Apple Development identity when available; hosted CI retains
  ad-hoc signing. Strict signature verification passed. Release notarization and
  the oldest supported macOS version remain unverified.
- Provider logs record connection/request stages without prompts, file contents,
  raw provider frames, stderr, or credentials. Noisy temporary byte logs were
  removed after diagnosis. Initialization timeout messaging now identifies a
  possible macOS permission dialog and states that no model turn was submitted.
- Drafts persist per conversation and are cleared with the durable send intent,
  before provider startup, so startup latency does not leave a sent prompt in the
  composer. Failed sends remain visible in the saved conversation.
- The initial Swift CI and both refreshed dependency-update branches passed
  tests, native packaging, and signature verification on GitHub's macOS runner.
  Checkout v7 and cache v6 updates were merged only after those checks passed.

These checks establish basic Codex/Claude conversations, not complete provider
or T3 Code parity. Real tool approvals, all control methods, remote environments,
and long-running behavior still need broader end-to-end verification.

## 2026-10-21 — initial Swift runtime and native workspace

Implementation commit: `c5290b7b6cc2cfa0e8d9f4537bf8e2d6a2fa3ad8`.
Local toolchain: Apple Swift 6.4, Xcode 27.1, Apple Silicon macOS 27.

- `COINCIDE_LIVE_CODEX=1 swift test`: 14 Swift Testing tests passed, including
  the optional installed-Codex handshake/model-discovery check. The preliminary
  XCTest runner reports zero tests because the actual suite uses Swift Testing;
  the Swift Testing summary is the authoritative test count.
- `./script/build_and_run.sh --verify`: built, packaged, and launched Coincide.
- `codesign --verify --strict dist/Coincide.app`: passed for the ad-hoc signed
  development bundle. This does not establish Developer ID signing/notarization.
- Native UI inspection confirmed the empty state, Add Project panel, project
  folder open events, new thread, supervised permission selection, composer,
  source-control inspector, and displayed repository changes.
- A real Codex turn was sent through the native composer with the prompt
  `Respond with exactly COINCIDE_NATIVE_SMOKE_OK. Do not use tools or change files.`
  The native transcript displayed `COINCIDE_NATIVE_SMOKE_OK`. The database
  persisted both user and assistant messages and returned the thread to `idle`.
- The Add Project panel was changed from a synchronous modal loop to an
  asynchronous AppKit panel after accessibility input exposed a responsiveness
  issue. Project folder opening was also verified through Launch Services.
- Process/protocol tests exposed and fixed pipe buffering and thread-pool
  starvation issues. File containment tests exposed and fixed symlink-parent
  resolution when the final path does not yet exist.

This is evidence for the initial implementation only. It does not establish
complete T3 Code parity, all-provider reliability, live tool/approval behavior,
remote support, long-running stability, accessibility completeness, or support
on the oldest declared macOS version. CI results remain separate live evidence.

## 2026-10-23 — delegated tasks, Claude filesystem skills and editor recovery

- Native `delegate_task`, `task_status` and `task_cancel` use independent briefs,
  captured provider/model controls, registered launch profiles, both permission
  ceilings, durable original command receipts and real spawn/result provenance.
  Async and bounded wait modes return questions/approval/timeouts without
  cancelling a child. Original task results remain immutable; explicit later
  child rounds have separate results. Full stored results use a scoped paged
  reader; the tool response keeps a bounded UTF-8 preview under the MCP limit.
- Shared tasks keep the parent cwd. Isolated tasks capture its verified local
  HEAD and create a project-root worktree without copying staged, unstaged or
  untracked parent changes. Discovered setup gates the first brief. Recursive
  cancellation retains unrelated queued drafts paused and captures exact old
  runtime/job owners so an old receipt cannot close a successor.
- Completion cohorts acknowledge explicit terminal status reads, steer a
  compatible exact active parent or queue a continuation. Pending context
  transfers defer idle automatic notices. Uncertain notification delivery and
  restart never replay provider effects. Ledger capacity includes worst-case
  JSON escaping and future result/provenance reservations.
- A native task panel exposes parent/child navigation, current child requests,
  original/latest results and explicit cancellation without acknowledging agent
  result notices. Closing the panel drains an accepted cancellation independently.
- Claude filesystem skills read captured home/project/ancestor/add-directory/
  plugin scopes. Full YAML parsing has iterative native preflight limits before
  recursive composition and bounded alias expansion. Native command and
  filesystem diagnostics remain separate. Known inline skill mentions lower
  to native final slash-command blocks while authored text, images and immutable
  historical context stay separate. Composer insertion checks exact UTF-8 bytes.
- Native and remote editor recovery use private bounded atomic CAS journals,
  explicit restore/copy/discard and visible durability errors. Root/path/base
  revisions stay attached to the recovered record. A remote save durably binds
  the original operation before sending; late acknowledgements cannot rebase or
  delete a replacement record at the same path, even with identical text.
- Focused runtime verification found task-completion stack exhaustion. Compiled
  prologs showed a 16,144-byte task reducer re-entering a 58,288-byte general
  reducer. Heavy task request/preparation payloads now use value-semantic heap
  storage with unchanged flat Codable, and completion steering calls the same
  guarded native helper directly. Existing steering cases verify the fix without
  changing stack sizes, deadlines or assertions. The complete run exposed two
  additional stack-pressure paths: isolated worktree admission and Pi history
  preparation. New lineage/completion metadata is also heap-backed, and native
  worktree/Pi preparation now use small dedicated reducers with independently
  compared, unchanged validation and effect bodies.
- Hosted run 39942092760 reached its 35-minute job limit after a 721.81-second
  cold compile and progressing tests; it produced no passing overall result or
  GUI artifact. Compilation now has a separate 35-minute job. Tests restore only
  the exact current-SHA build, compare the Swift toolchain and execute all existing
  isolated probes, full tests, ABI checks, packaging, signature/resource checks
  and GUI shards. No test deadline or coverage was reduced; hosted verification
  of this split remains separate from local checks.

Final verification on the frozen Core and corrected App source:

- All 2,136 declarations are covered by final passing target runs: 1,774 Core
  declarations (1,761 passed, 13 optional installed/live checks skipped) in
  550.585 seconds; 332 UI/store declarations in 79.976 seconds; 17 terminal
  declarations in 10.259 seconds; 13 Markdown declarations in 0.130 seconds.
  This is 2,123 passed declarations plus 13 optional skips. The intact pinned
  Pi 0.80.5 package acceptance remains enabled with its isolated synthetic stream.
- The complete run passed Core, terminal and Markdown. Its one UI failure exposed
  a recovery-inventory await after document publication, allowing fresh contents
  to appear before write readiness. FileBrowserStore now completes that I/O and
  rechecks ownership before publication. The complete 332-declaration UI target
  then passes with unchanged assertions/deadlines. Core source and its passing
  executable fingerprint are unchanged by this App-only correction. These are
  separate passing target runs, not a claim that the earlier aggregate exit was
  successful.
- The final targeted stack regression passes 23 Core and four UI declarations,
  including actual private-Git worktree/setup admission and forged Pi history
  proof handling. UI recovery tests also cover both same-root and replaced-root
  late save acknowledgements.
- All 75 Python CI/launcher/crash-collector checks pass in 2.669 seconds. Changed
  private Python fixtures parse without writing bytecode; workflow YAML and the
  exact build-cache/toolchain dependency gates validate.
- The ABI guard inspects 1,138 actual objects (798 Core and 323 App objects),
  finds zero weak async default records, and accepts three local records.
- The native GUI runner compiles at the fixed DerivedData path and its offline
  launcher envelopes pass. No local interactive GUI test, installed app launch,
  real provider/model/account call or SSH connection is claimed.
- The native app/helper package builds and passes strict deep signature checking.
  Compiled and packaged UUIDs agree; bundled Yams/libyaml notices match source.

Installed task/skill execution, broader provider/account acceptance, real remote
hosts, hosted verification of this commit and full T3 Code parity remain pending.


## 2026-10-23 — native model controls, saved-session import and composer recovery

- Codex captures actual advertised service tiers, native defaults and bounded
  legacy speed-tier metadata. Explicit choices recheck the native catalog before
  starting/resuming a conversation or sending input. Clearing an app-owned sticky
  tier sends the native persistent null reset; untouched defaults retain the CLI
  cascade. Owned ChatGPT connections do not advertise unsupported tier controls.
- Claude captures supported effort/fast/thinking/context choices, lowers only
  pinned aliases and prompt efforts, and keeps requested fast mode separate from
  reported effective state. Launch-only changes and clearing explicit effort
  drain/recreate the connection to the same native conversation. Queued/active
  inputs keep their own captured controls. Native menus, durable edits and app
  tools share validation; stale menu captures cannot overwrite a newer profile
  or sibling choice. Indirect control cases preserve bounded reducer frames and
  backward decoding of commands without an optional expectation.
- Explicit local project discovery/import follows the pinned T3 filesystem
  sources, Codex and Claude. Bounded selective JSONL reads skip private tool/image
  payloads, retain visible history, and inspect Git metadata without subprocesses.
  Reviews bind physical roots, descriptors, digests and project incarnations.
  Adoption creates settled histories, no provider input or invented run proof.
  Durable provenance protects edited/archived/deleted imports and native owners,
  including legacy Codex captures with an unknown home across instance aliases.
  Import cursors retain their original completed-source view across page commits.
  Cache admission accounts for full retained pages, including duplicate metadata.
- Large native pastes become immutable text attachments; explicit inline paste,
  a global 20-prompt local stash, and retained-original attachment retry are wired
  into the composer. Exact draft/reference compare-and-swap preserves newer text.
  Private manifests precede mutation, and unknown outcomes inspect/fence the
  original command rather than replaying it. Project removal and Quit join owned
  work; unfinished session-only attachment copies have an explicit Quit warning.
  Canonically equivalent byte changes survive journal rebuilds for both draft
  metadata and imported native transcript content.
- Final source compilation passes. The new checks cover 51 Core and 16
  native UI/store declarations; the repaired focus run passes 66 Core and 19
  UI/store declarations, including existing Pi and attachment regressions. Initial test-only formatter and registered-path
  fixtures were corrected, retaining their assertions and production guards.
  The final serial aggregate run exits zero: **2190 declarations pass and 13
  optional installed/live-provider declarations skip**, covering all 2203 listed
  declarations. Core covers 1825 in 523.480 seconds (1812 pass, 13 skip), native
  UI/store 348 in 79.464 seconds, Terminal 17 in 10.423 seconds, and Markdown 13
  in 0.137 seconds. The full Pi package uses the existing pinned offline runtime;
  no model service is contacted. This final run includes the previously crashing
  Pi adoption/restart case and unchanged legacy attachment/removal assertions.
- The first aggregate regression run exposed two App-only attachment-state/
  removal regressions and a reproducible Pi native-history validation stack fault.
  Busy-state reporting is again separate from failed/unknown submission blocking;
  removed transient imports drain/dispose while global saved prompts and original
  receipts remain recoverable. Existing assertions and deadlines are preserved.
  Native journal validation now runs in a non-inlined 112-byte wrapper before
  entering the separate 5584-byte event-diff frame (formerly 5648 bytes allocated
  during validation). The previously crashing exact Pi case and complete focused
  history/Unicode/import checks pass. Hashing, stack limits and validations stay
  unchanged. The final aggregate run below is separate from that failed attempt.
- All 75 Python support tests pass in 2.743 seconds; both new private Python peers
  parse successfully. The ABI guard checks 1181 objects (837 Core and 343 app
  coverage entries), with zero weak async-default records and three local ones.
  The native GUI runner compiles and its offline launcher checks pass without
  opening a GUI application. The packaged app passes strict deep code-signature
  verification and native math resource rendering.
- Separate evidence for the preceding pushed head `9c0f067`: its entire
  [hosted run](https://github.com/apoorvdarshan/coincide/actions/runs/39951666097)
  passes, including build, complete Swift tests, packaging, ABI/resources,
  all four native GUI shards and the final shard-coverage gate. This result
  does not validate the unpushed changes in this batch.
- Compiled and packaged UUIDs match: Coincide
  `78D14BE8-6696-3C28-AC87-02D627EBB95C`, CoincideEnvironment
  `82C9819C-11DD-3064-9C6D-BA1C52C1DA03`, and CoincideScriptHelper
  `6F07B85F-C0D5-3C39-AF1B-8E4F454EB599`.

These checks use private offline peers and generated transcripts. No real native
session file was changed, provider/model turn sent, authentication migrated, or
installed app replaced/opened. New native GUI interaction, installed-provider
control acceptance, remote display controls/composer/import parity and broader T3 parity remain
unverified. Scanner-only duplicate alias metadata is reported without a hidden
write in the read-only preparation API; deterministic native ownership still
prevents duplicate thread adoption.

## 2026-10-23 — lifecycle, Claude profiles and rich Markdown

This batch adds local snooze/wake and an owned automatic-settlement service,
private future-conversation Claude profiles with optional native auto-compaction
settings, and native alerts, details and optional inline/display math. Existing
captured Claude runtimes retain their namespace and launch settings; legacy
nil-runtime conversations retain native CLI defaults. Neutral profile catalogs
cannot leak into captured/legacy conversations or republish after a corrupt
profile reload. The product's math preference defaults off. SSH automatic
settlement remains disabled until its remote settings/Resume controls exist.

The first complete focused run passes **98 declarations**: 59 Core in 56.845
seconds, 10 native UI/store in 0.981 seconds, and 29 Markdown in 0.636 seconds.
It covers stale settings and proposals, exact snooze stamps, owned timer/lookup
cancellation and drain, latest proven PR associations, notification suppression
without completion replay, profile persistence, late catalog replies, inert
HTML/code and the pinned math grammar. Initial new fixtures needed their exact
registered path and terminal-run end reason corrected, plus test-only error
markers/import access. The alert test also exposed a real upstream nested-task
scanner limitation; the renderer now recovers only source-verified plain task
markers and preserves escaped/code/entity text and styled bodies. Assertions
and deadlines are retained.

The preceding pushed head `fe8b934` passed its local aggregate but its
[hosted run](https://github.com/apoorvdarshan/coincide/actions/runs/39962570256)
crashed with SIGBUS in the local PR-checkout case. The sanitized stack records a
guard-page fault in `___chkstk_darwin` / ICU IDNA / `URLComponents.host` during
checkout validation beneath the general command reducer. All six checkout
command stages now use a dedicated non-inlined reducer with the original
admission and common finalization. Fresh compiled fixed locals along that path
fall from **59008 to 3504 bytes**, excluding saved-register prologues; the new
reducer itself uses 976 bytes and avoids the broad reducer's dynamic temporaries.
The exact previously crashing test passes locally in all five cases. New hosted
crash resolution still requires the next CI run. URL parsing, validation,
hashing, stack limits and timeouts are unchanged.

The first ABI check found mismatched weak async-default sleep-closure contexts
(144 production bytes versus 128 test bytes). The default is now nil, resolved to
a named static async function inside the initializer. The first aggregate was
intentionally interrupted after all 358 UI/store declarations passed, so the
corrected build can be checked and run as a whole; it is not counted as a full
aggregate success. The partial terminal run had no assertion failure. Only its
owned Swift test process was interrupted, and no owned test helper remained.

After rebuilding the sleep change, all 17 targeted lifecycle declarations pass
(3 native UI/store and 14 Core). The ABI guard passes across **1209 objects**,
with 855 Core and 351 app coverage entries, **zero weak async-default records**
and three local ones. The separate 75 Python helper tests pass in 7.485 seconds.

The first completed aggregate of this batch executes all **2257 declarations**:
1853 Core (13 optional skips), 358 UI/store, 17 Terminal and 29 Markdown.
Terminal and Markdown pass (11.500 and 0.675 seconds). Core finishes in 1327.615
seconds with three failed declarations / eleven expanded-case issues, all at
reviewed file-ledger validation after pin edits. The UI/store suite finishes in
202.673 seconds with three existing queue/setup wait timeouts. This aggregate
exits nonzero and is not reported as a passing full suite.

The file-ledger regression is corrected by excluding workspace attention metadata
from the file-ownership fingerprint; workspace, runtime, checkpoint, settlement
and source-audit guards remain intact. No-op pin/submit reconciliation also
preserves absent legacy lifecycle metadata. The existing restore regression now
includes an actual snooze and pin-wake with retained wake timestamp before
acceptance, retaining all previous assertions. Targeted verification passes all
**23 affected declarations**: 17 Core in 0.528 seconds and 6 UI/store in 19.648
seconds, including all six previously failing declarations. The three UI tests
retain their original deadlines and assertions and now emit safe boolean/count/
enum diagnostics only on failure. Their timeout cause has not been established;
a separate whole-UI rerun checks ordering. High concurrent build load was observed
but is not treated as proof of causality. Full-suite CI after the push remains
the next combined verification of this final patch.

The final whole-UI rerun passes **all 358 declarations in 80.542 seconds** with no
failure diagnostics. Final ABI inspection again reports 1209 objects, zero weak
async-default records and three local records. The packaged app passes strict
deep code-signature verification and native resource rendering. Compiled and
packaged UUIDs match: Coincide `8D31AFA8-9C5A-38CB-92B9-9097D5E465CE`,
CoincideEnvironment `F4B16351-3431-34D4-B35D-F4C8C006CB42`, and
CoincideScriptHelper `31980CE8-C6BE-32A5-876D-73D41F10E5C4`.

No installed app was replaced/opened, authentication migrated, real provider
turn sent, or native session changed by this batch. Hosted GUI interaction,
installed compaction behavior, the next combined CI result and broader full T3
parity remain unverified. The final local patch has complete whole-UI, focused
Core regression, Markdown, Terminal, helper, ABI and package evidence; a new
single all-green aggregate after the final file-proof fix is not claimed.

### Hosted compiler workaround after dc7b893

[Run 39976411282](https://github.com/apoorvdarshan/coincide/actions/runs/39976411282)
failed during compilation on Apple Swift **6.3.3**
(`swiftlang-6.3.3.1.3`, clang `2100.1.1.101`, Xcode 26.6). At
2026-10-23 15:21:18 UTC, IRGen aborted with signal 6 and a SmallVector capacity
overflow while generating `WorkspaceLifecycleSettingsSection.swift`. The failing
SIL symbol `$sSbScA_pSgIeAghyg_SbIeAghn_TR` demangles to an isolated, Sendable Bool
setter reabstraction thunk. The two direct actor-isolated method references in
the section's Binding setters are replaced with explicit closures, preserving
the same settings actions. No toolchain, workflow, test assertion or deadline is
changed. The [next hosted build, 39984676572](https://github.com/apoorvdarshan/coincide/actions/runs/39984676572),
passes on Apple Swift **6.3.3** (`swiftlang-6.3.3.1.3`) in **835.14 seconds**.
Its complete test job is still running at this check. The earlier failed run
never executed tests or native UI shards.

### Provider usage and remote lifecycle controls (2026-10-23)

This batch adds typed Claude/OpenCode usage retention and native/remote displays,
plus capability-negotiated remote conversation lifecycle controls and automatic
sweeps. Remote manual settlement currently exposes an explicit **without cleanup
script** action; normal reviewed remote cleanup execution, stop and output remain
unfinished. Usage observations do not alter history/checkpoint/context authority.
Context handoff clears old passive session metadata while preserving recorded
run accounting. Terminal Claude events publish final run accounting before a
separate passive snapshot, without another provider request.

Local Apple Swift **6.4** (`swiftlang-6.4.0.34.1`) verification:

- `swift build --build-tests` passes after correcting new fixture compilation
  issues. No production API, assertion, deadline or test coverage was weakened.
- One serial `swift test --skip-build --no-parallel` selection passes **423
  declarations**: the complete **368-test CoincideUITests suite in 80.734 seconds**
  and **55 Core declarations in 3.193 seconds**, including parameterized cases.
  The selection covers Claude/OpenCode usage ownership and normalization,
  cumulative replacement, durable replay and proof invariance, context-profile
  handoff, large leased usage documents, remote native-helper lifecycle controls,
  lost-reply receipt recovery and stale roots/claims, negotiated auto-settlement,
  existing lifecycle policy, file-proof pin edits, file-write locks and PR reuse.
- `python3 -m unittest discover -s UITests/macOS -p 'test_*.py' -q` passes all
  **75 tests in 4.715 seconds**.
- The async-default ABI guard passes **1240 Mach-O objects**, including 884 Core
  and 364 App objects: **zero weak records**, three local records.
- `./script/build_and_run.sh --build-only`, strict deep code-signature verification
  and `--verify-resources` pass. Compiled/package UUIDs match: Coincide
  `E1EAC92F-F086-3D82-A673-46F78F245F87`, CoincideEnvironment
  `7EA934C0-BA88-37F1-9FED-FCE4F63C13CE`, CoincideScriptHelper
  `CCF43E00-11D6-336D-A86C-1165C35C2E62`.

Evidence logs use `/tmp/coincide-usage-remote-lifecycle-*-20261023.log`, with the
successful test build in `build-verified` and serial checks in `focused`.
No installed app was replaced/opened, provider/authentication setup changed, real
model turn sent, or live SSH host mutated. These local checks do not establish
installed-provider usage acceptance, hosted GUI acceptance, a new complete Core
suite result or the Swift 6.3.3 compiler-workaround result. The next hosted run
must verify those applicable checks; full T3 parity remains unfinished.

### Reviewed remote cleanup scripts (2026-10-23)

The normal remote Settle path now requests native cleanup discovery without
execution. Separate script capability negotiation exposes a complete-command
review, opaque approval, Stop/Skip/Retry and bounded output. CoincideEnvironment
serves as its own managed helper through the existing FD/process-group protocol.
File, Git, terminal, worktree, checkpoint and history admission observes retained
native job leases, including shared Git directories and descendants after parent
exit. Stop/Resume acknowledgements join exact cleanup outside host admission.
Rootless recovery permits Stop/Skip/output while refusing Approve/Retry. An
asynchronous setup job still permits its own conversation's native input path;
foreign conversations remain excluded until drain.

Verification on local Apple Swift 6.4:

- Final `swift build --build-tests` passes. The ABI guard inspects **1252 objects**
  (896 Core, 369 App), with **zero weak async-default records** and three local
  records.
- The complete **374-declaration UI unit suite passes in 80.523 seconds**,
  including complete-command/SHA approval gates, stale host/attempt/root replies,
  explicit output polling, accepted-control joins and offscreen light/dark views.
- Final affected-Core selection passes **157 declarations in 89.336 seconds**,
  including expanded parameter cases. It covers native embedded-helper execution,
  prepare-before-start, one-shot start, stale configuration refusal, UTF-8 output,
  live descendant cleanup, approved remote discovery/run/output, original receipt
  recovery after lost replies, interruption without replay, fresh Retry review,
  missing-folder recovery and private-incarnation refusal. Existing setup,
  settlement, managed helper, remote file/Git/PTY/worktree/checkpoint/history/PR
  controls run in the same selection.
- The new real-helper lease regression refuses workspace file saves and Git
  writes in both the target and source sibling worktrees sharing a common Git
  directory; metadata, output and Stop remain reachable. The exact two recorded
  process IDs are gone after Stop, and fresh file/Git writes then succeed. The
  asynchronous-setup broker regression separately proves owner input admission,
  foreign input refusal and admission after exact drain.
- The initial selected run had four issues in three fixture declarations.
  Corrections compare full command bytes to the immutable native normalized
  plan, select exact thread IDs after inserting a sibling, and wait for host
  native-thread/turn adoption before capturing checkpoint configuration. Original
  assertions/deadlines remain; all affected Core declarations pass in the final
  selection. The UI suite predates only the final Core input-scope adjustment,
  which has the additional broker regression. A new single full aggregate is
  not claimed.
- Build-only packaging, strict deep code signing and native math-resource
  rendering pass. Compiled and bundled UUIDs match: Coincide
  `155647EF-1B56-3BB9-A5E1-FB28F0964256`, CoincideEnvironment
  `9ACAEFD8-6258-3E5D-B64B-F3ED9E7FA541`, CoincideScriptHelper
  `62062C43-BEB1-3209-94AC-EF7416E2F854`.

Logs use `/tmp/coincide-reviewed-remote-scripts-*-20261023.log`; final test build
is `build-final`, final Core run `core-recheck`, and whole UI evidence `focused`.
The previous push's hosted Swift 6.3.3 build passes; its complete test job is
still running at this check. This batch has no new hosted interaction result.
No installed app was replaced/opened, actual provider turn sent, authentication
changed or real SSH host modified. Remote setup/standalone scripts, persistent
host behavior, native GUI interaction for this new workflow, installed-provider
acceptance and broader T3 parity remain unfinished.

### Hosted remote-script workflow and OpenCode uncertainty ordering (2026-10-23)

The hosted native suite now has **28 workflows**, selected exactly once across
four seven-test shards. The new workflow connects to the real bundled
CoincideEnvironment over private local stdio, discovers a separate worktree's
settle script, loads a command beyond the 8 KiB preview, cancels without running,
then explicitly approves once, checks real output and stops the exact recorded
three-process tree. It preserves the unsent draft, empty transcript/run history,
source checkout and local workspace; it does not claim provider-history coverage.

The local transport is DEBUG-only and requires the exact UI-testing bundle,
both explicit fixture flags, a physical private owner-0700 root and a fixed
connection configuration. It pins/revalidates the bundled helper identity,
uses private homes/configuration and fixed `/usr/bin/false` provider/GitHub
executables, and passes no account credentials. Ordinary launches keep SSH.
The seed helper uses production JSON-RPC registration/worktree/draft operations,
not direct native-plan or snapshot injection. It rejects aliased/symlinked paths
and foreign helpers. No new local GUI execution was performed.

Separately, [hosted run 39984676572](https://github.com/apoorvdarshan/coincide/actions/runs/39984676572)
passed Swift 6.3.3 compilation but failed its complete test job: 2302 declarations
completed with two issues in the ambiguous-root/dropped-no-root OpenCode v2
uncertain-command case. Its native UI shards were skipped; the aggregate native
UI failure is not evidence that a GUI scenario ran and failed. Safe retained
local diagnostics reproduce both cases: usage was present, one queued input was
held, no runtime remained and no engine error occurred, but the record ended as
`startFailed` instead of `connectionLost`. The generic failed-send effect could
overtake the native reader after its usage event and before closure committed.

The provider-start catch now waits for that exact native OpenCode v2 reader only
when the thrown error is typed `uncertainDelivery`, then rethrows the original
error. Usage remains before closure; no successful dispatch, fallback or retry
is fabricated. Regression assertions retain the original end-reason, FIFO,
restart and no-fallback requirements and additionally require recorded usage.

Verification:

- `swift build --build-tests` passes. The exact two-case failure reproduces
  before the correction (16.274 seconds) and passes after it (0.380 seconds).
- Broader selected regression run passes **40 declarations**: 11 UI in
  0.347 seconds and 29 Core in 4.077 seconds, including command HTTP ownership,
  usage, restart, remote script helper and test-connection guards.
- All **75 Python checks pass in 2.631 seconds**, including exact native
  discovery/count/shard validation. The native runner's final
  `--build-for-testing` succeeds with its new bundled seed resource, without
  launching any app.
- An actual final packaged-helper seed smoke passes: native registration,
  verified reused worktree, exact unsent draft, no transcript/run input, no
  cleanup execution, clean helper exit and unchanged source bytes. Its private
  synthetic fixture is removed afterward. This is protocol evidence, not GUI
  interaction evidence.
- Final ABI guard passes **1255 objects** (899 Core, 372 App), zero weak
  async-default records and three local records. Build-only packaging, strict
  deep signatures and native math resources pass. Compiled/package UUIDs match:
  Coincide `37A97D65-E985-302D-9C35-DBF0263CD3BF`, CoincideEnvironment
  `224230E4-4489-3F17-B161-90A3B683E24E`, CoincideScriptHelper
  `93FFCE49-AECE-3D3D-A10C-9A1EA6BE1DF4`.

Local logs use `/tmp/coincide-native-remote-script-ui-*-20261023.log` and
`/tmp/coincide-opencode-ordering-*-20261023.log`. Run 39989401534 for the previous
commit is still testing at this check and does not include the ordering fix.
The next exact-head CI must verify the full suite and the new 28th native
interaction. No installed app was replaced/opened, real SSH host changed,
vendor model request made or authentication migrated. Full T3 parity remains
unfinished.

### Native rich Markdown integration (2026-10-23)

Integrated the clean `claude/markdown-ext` feature commits `5bfc6b3` and
`e89561b` through a three-way merge onto current main, preserving the intervening
Claude profile/lifecycle/settings, usage, remote script and uncertainty-ordering
changes. No other Claude worktree or its uncommitted changes was edited.
The app now renders native safe HTML, footnotes, Codex directives, code metadata,
language/wrap/copy controls, table text/CSV/TSV exports, richer lexical coloring
and supported native flowchart/sequence diagrams. No WebKit, JavaScript, external
image fetch or added dependency is used.

Main's `mathEnabled` parsing/view APIs, public formula/source/copy metadata,
`NativeMath.render`, existing canonical `renderMathInMarkdown` default-off
preference and settings accessibility ID remain. New wrapping preferences do not
introduce a second enabled-by-default math key. Source replacement shows an inert
literal fallback until the matching parsed document is ready, rather than old
blocks/actions. Internal markers are selected outside the authored scalar set.
Incomplete or unsafe disclosures remain literal; HTML construction has limits
before intermediate/tree growth (1 MiB source, 32768 tokens, depth 32, 8192
nodes), with whole-block literal fallback. Existing quoted-task source proofs,
private-use Unicode and link containment protections remain covered.

Local verification on Apple Swift 6.4:

- Final `swift build --build-tests` passes; ABI guard reports **1274 objects**,
  zero weak async-default records and three local records (899 Core, 372 App).
- The complete **73-test Markdown suite passes in 1.435 seconds**, including
  deep/wide/unfinished HTML, implied closing tags, inert assets/unsafe links,
  formula source/copy metadata, footnotes, diagrams and preserved main coverage.
  Two relevant UI declarations pass in 1.160 seconds and one Core declaration
  in 0.001 seconds.
- The complete **378-declaration UI unit suite passes in 80.263 seconds**.
- Initial integration exposed 14 behavior issues, then one existing flow-math
  precedence regression. Production corrections preserve all expected cases:
  hard-break alert rejection, nested/footnote/inline display math, shell/currency
  exclusions, GFM cell serialization, disclosure newlines and ownership of code
  text inside an already-open display flow. No test cases or expected behaviors
  were removed to pass the merge.
- Build-only packaging, strict deep code signing and actual native math-resource
  rendering pass. Compiled/package UUIDs match: Coincide
  `EAC5D0A1-D771-3A94-888B-E3AA826D5A87`, CoincideEnvironment
  `224230E4-4489-3F17-B161-90A3B683E24E`, CoincideScriptHelper
  `93FFCE49-AECE-3D3D-A10C-9A1EA6BE1DF4`.

Logs use `/tmp/coincide-markdown-integration-*-20261023.log`; final build is
`build-verified`, final Markdown selection `tests-verified`, whole UI `ui`.
Hosted run 39993961762 passed compilation and is still testing at this check.
There is no new exact-head hosted/native interaction result for this merge.
The optional shell callback remains unwired in the product, and remote Markdown
never executes through a local terminal. Broader diagram grammars, directive
actions, media and full T3 parity remain unfinished. No installed app, account,
provider session, live SSH host or other session's working tree was changed.


### Native terminal workspace integration (2026-10-23)

Integrated immutable `claude/terminal` commit `85b20ff` onto `6f6fd0a`, preserving
main's provider profiles, math/wrap preferences, guarded native UI helper,
lifecycle controls, usage and reviewed remote scripts. Other worktrees and their
uncommitted changes remain untouched.

The product adds per-conversation split groups, drawer sizing/visibility,
terminal focus/menu commands, font/color controls, file/web links, runtime root
variables, advisory activity and bounded inert styled-history restoration.
Fresh shells require original conversation birth/project/preparation/path and
physical folder identity, plus current readiness. Automatic and manual restart
share the same checks. Legacy proof-free and changed-checkout output stays
readable without being rebound; mixed old/new checkout panes retain separate
metadata through save and cold restore. Saved script commands never replay.

Idle closure is explicitly opt-in and defaults off. A supported native prompt,
unchanged input/output, exact process incarnation and physical executable,
foreground ownership and absence of children/owned session descendants must
agree. Native keyboard/text/paste/pointer input invalidates the prior prompt;
input queued before the first prompt cannot use that initial prompt as an idle
receipt. A native reset initializes the fresh emulator before process/output
attachment. Captured physical images cover protected direct `/bin/sh`, its
validated system selector and Apple's missing-selector Bash default; process
names do not authorize closure. Unknown evidence leaves shells open. No shell
configuration is changed.

Local verification on Apple Swift 6.4:

- Final `swift build --build-tests` passes in 14.73 seconds. ABI guard scans
  **1298 Mach-O objects**, with **zero weak async-default records** and three
  local records (909 Core, 381 App).
- Final full **37-declaration Terminal suite passes in 17.405 seconds**. The
  **31 selected UI/store declarations pass in 26.488 seconds**, covering local
  restore/split/activity/settlement behavior, original checkout fences, inert
  replay, remote terminal ownership and the previously timed-out script view.
- Earlier in this integration, the complete **73-declaration Markdown suite
  passes in 1.431 seconds** and four terminal link/environment Core declarations
  pass in 0.003 seconds. The initial whole UI run has 388 declarations with two
  idle-close failures; those paths pass after the native initialization and
  executable-identity fixes. A new whole-UI/full-Core aggregate is not claimed.
- Build-only packaging, strict deep signatures and actual native math resource
  rendering pass. Compiled/package UUIDs match: Coincide
  `1E8AD893-614C-3477-A187-B7408B842FF1`, CoincideEnvironment
  `C44AFCE2-0A87-36EE-A80F-6E4533B1B5F2`, CoincideScriptHelper
  `51F71B2C-0937-3204-847C-8C2172430C0C`.

Hosted run `39997298835` failed Swift 6.3 type-checking at the Mermaid sequence
column-gap expression; this integration separates its explicitly typed CGFloat
steps. Hosted `39993961762` verifies both OpenCode uncertain-loss modes, but its
2323-declaration run has one offscreen script-view timeout (150.607 seconds under
an unchanged 60-second limit). That declaration passes locally; bounded fixed
phase/elapsed diagnostics now distinguish reads, hydration, each appearance's
banner/sheet layout and shutdown in the next CI run without logging content,
paths, identities or credentials. No timeout extension, assertion reduction,
CI aggregate success or native GUI interaction success is claimed; GUI shards
were skipped behind the failed test gate.

Final logs use `/tmp/coincide-terminal-integration-portable-{build,tests,abi,package}-20261023.log`.
The installed app was not replaced/opened. No account, provider session, live SSH
host or shell configuration was changed. Live process reattachment, broader
remote/script controls, complete terminal compatibility/accessibility and full
T3 parity remain unfinished.


### Native keyboard and command palette integration (2026-10-24)

Merged immutable `claude/keyboard-palette` commit `2498fd3` onto `ea6497f`.
The intervening terminal splits, appearance, inert restoration, original checkout
identity, prompt/process idle proof, math preferences, provider profiles, usage,
remote scripts and guarded native UI helper remain. No other worktree or its
uncommitted changes was edited.

The app adds a native palette, thread/project search, Find in Thread, navigation
history, closed inspector reopening, jump hints and editable shortcuts with live
reload. The pinned `chat.new` command opens the project chooser when multiple
groups exist; `chat.newLocal` uses current context. Private config parsing has
1 MiB/depth/entry limits, strict UTF-8 and bounded shortcut/condition parsers.
Descriptor-relative no-follow file access, private locking, exact revision checks
and fsynced 0600 replacement protect editing; malformed or unsafe targets are
not rewritten.

Dispatch requires the exact registered key window and respects sheets, marked
text and input ownership. Replacing a window's controller retires its old
callbacks; a stale registry entry cannot retire a controller moved elsewhere.
Retained palette actions check their captured source before activation. Stop
passes exact run/runtime IDs into the existing atomic Engine guard. Native and
app monitors share one bounded event decision, so terminal new/close/split cannot
run twice. Custom rules replace mutation defaults and update context-menu labels;
Find/Clear/navigation keep their native fallback when applicable. Pending terminal
focus respects the original responder/window and never starts a saved shell.

Local verification on Apple Swift 6.4:

- Final `swift build --build-tests` passes in 7.13 seconds. The ABI guard reports
  **1336 Mach-O objects**, **zero weak async-default records** and three local
  records (941 Core, 411 App).
- The complete **411-declaration UI/store suite passes in 96.000 seconds**,
  including original native views and the added keyboard/window/modal/palette
  cases. The six focused keyboard/chooser declarations pass in 3.587 seconds.
- **18 keyboard Core declarations pass in 0.471 seconds**, including malformed,
  oversized, deep and non-UTF8 config; symlink, hardlink and FIFO refusal; exact
  raw revision checks and multiple-binding/default semantics.
- The full **39-declaration Terminal suite passes in 17.691 seconds**, retaining
  styled output, process/input ownership, idle-proof and original workspace tests
  while adding focus and changed-checkout coverage.
- Initial offscreen keyboard tests used real `NSWindow.makeKey`, which did not
  establish a key window in the headless unit host. Test-only windows now model
  one exclusive key owner without app activation or ordering windows onscreen;
  production checks and actual responder/sheet assertions remain. Remap tests
  now edit the original rule through the real replacement API rather than adding
  a second shortcut. No assertions, deadlines or existing cases were removed.
- Build-only packaging, strict deep signatures and native math-resource rendering
  pass. Compiled/package UUIDs match: Coincide
  `B88ABCEA-236C-37E5-88B1-29BD13BB062B`, CoincideEnvironment
  `C8B941F5-A860-3542-A1F8-A39363FD3A14`, CoincideScriptHelper
  `281F024A-AE7E-304B-9BDC-82727D74D521`.

Logs use `/tmp/coincide-keyboard-integration-*`; final UI/Core/build/ABI/package
logs use the `20261024` suffix. Hosted terminal-batch run `40001722482` passes
Swift 6.3 compilation and is still testing at this check. There is no exact-head
hosted/native GUI success claim for this keyboard merge. No installed app was
replaced/opened, authentication migrated, provider model request sent, live SSH
host changed or shell configuration edited. Remaining command surfaces and
complete installed/remote/provider/T3 acceptance remain unfinished.


## 2026-10-24: Git workflows and durable pull request actions

Integrated immutable Git-actions commit `bf43f7dd80cd3d6a7c70cac4ac9a308903585603`
with the current keyboard, terminal and provider ownership controls. The batch adds
structured diffs, branch selection, reviewed commit/push/create workflows,
source-control settings and scoped background synchronization. A clean default
branch that is ahead uses pure Push without creating an empty commit.

PR state actions now consume their original review UUID in the workspace journal
before dispatch. Exact duplicate admissions return the original receipt; changed
payloads cannot reuse that UUID. Accepted-but-undispatched work fails after restart;
dispatched work with no confirmed result remains unconfirmed and is never replayed.
Inspection records current GitHub state without attributing it to this attempt;
explicit acknowledgement permits a new review. Native repository identity and
original conversation ownership are checked before dispatch. Provider input and
ordinary drafts remain available while remote PR state work runs. Reviews also
pin the base commit and byte-exact base/head branch names, including NFC/NFD cases.

Local verification on Apple Swift 6.4:

- Final `swift build --build-tests` passes in **24.32 seconds**. The ABI guard
  reports **1378 Mach-O objects**, module coverage counters of 982 Core and 435 App,
  **zero weak async-default records** and six local records.
- The complete **432-declaration UI/store suite passes in 109.408 seconds**.
  The final focused **36 Core declarations pass in 19.811 seconds**, including
  native GitHub-action fixture commands, original-receipt deduplication,
  lost-response/interrupted-process restart recovery and exact child drainage.
  An earlier broader **172 Core declarations passed in 175.468 seconds** before
  the final generic command-runner drainage change.
- Both generic and streaming command runners await their exact owned process and
  readers on success, cancellation, timeout, output overflow and input failure.
  Four private TERM-held process modes verify that completion cannot publish
  before explicit release and that the exact PID is gone afterward. This does
  not claim descendant termination. The background-fetch fixture explicitly
  releases its separate upload-pack helper and verifies its cleanup.
- The initial UI run exposed two incorrect test expectations: treating the
  upload helper as the directly owned process, and matching old warning wording.
  Final assertions retain lease ownership, durable unknown-state and no-replay
  checks; no deadlines or existing declarations were removed.
- Hosted terminal run `40001722482` isolated its one timeout to laying out the
  complete 5001-line command in a selectable SwiftUI Text (about 79/77 seconds
  for light/dark sheet sizing). The bounded native text viewport retains the full
  exact command, selection/copy and approval gates. Its existing offscreen test
  now passes locally in **0.058 seconds**, including complete-byte checks. Hosted
  acceptance of this fix remains pending.
- Native UI runner build-for-testing and offline launcher verification pass;
  no native GUI tests were run locally. Build-only packaging, strict deep code
  signatures and native math-resource rendering pass. Compiled/package UUIDs
  match: Coincide `92A6065F-07F2-301B-9A34-A37E6131019B`, CoincideEnvironment
  `0AF32C96-20E6-38C1-82F9-FDE5D30E09BB`, CoincideScriptHelper
  `9773A341-554E-38AE-8FF2-66DE44F21CEC`.

Logs use `/tmp/coincide-git-actions-*-20261024.log`. Staged secret scanning passes.
The preceding keyboard CI run passed compilation at its last check; this Git
integration has no exact-commit hosted/native GUI success claim yet. No installed
app was replaced/opened, live GitHub mutation or model request sent, authentication
migrated, live SSH host changed or shell configuration edited. Complete T3 parity,
remaining desktop/script/transcript work and installed/provider/remote acceptance
remain unfinished. See [source-control behavior and limits](SOURCE_CONTROL.md).


## 2026-10-24: Desktop lifecycle, setup and links

Integrated immutable desktop-shell commit `e4ca12c` while preserving current
window-owned keybindings, terminal workspaces, provider profiles, math settings
and the guarded native remote-test transport. Desktop features include bounded
login-shell capture, protected quit, running-work confirmation, activity control,
local foreground banners, draft-only prompt/folder links and a command-line shim,
profile-scoped first-run readiness, searchable notices and bundle version/icon data.
Idle sleep prevention defaults to Never; App Nap protection follows active work.

Important integration checks:

- A startup wait returns at its budget without joining the still-running shell
  capture. Disable/quit cancels and joins owned work and fences late publication.
  Bounded status/environment probes reserve their independently spawned group
  until leader reaping; existing ProcessChannel exact-child ownership is unchanged.
- Deep-link confirmation uses exact composer CAS, including attachment references,
  original conversation birth and workspace. Cancellation before queued admission
  refuses the write. Provider/model configuration is initialized before registration,
  with no late edits or automatic send. Encoded path validation rejects trailing
  separators that Foundation's decoded URL.path silently drops.
- Setup captures configured Codex binary/home or Claude namespace. Managed checks
  hold an installation lease. Owned accounts use already verified in-memory vault
  overview; checks start no authentication or ambient CLI fallback. Profile revisions
  invalidate both readiness and retained Copy/Settings actions. Custom/managed runtime
  problems route to Settings rather than an unrelated vendor install command.
- Quit routing shares exact-event decisions with the current dispatcher and blocks
  native Command-Q fallthrough in modal, IME and stale-window scopes. Banner actions
  recheck original thread ownership; display/announcements require a registered key
  local workspace window. Injected tests create no real monitor, HUD or power assertion.
- CLI-shim tests preserve dangling symlinks, hardlinks and foreign files. No actual
  command installation or shell configuration change was performed.

Verification on Apple Swift 6.4:

- Final `swift build --build-tests` passes in **22.93 seconds**. The ABI guard reports
  **1418 Mach-O objects**, module coverage counters of 1018 Core and 459 App,
  **zero weak async-default records** and six local records.
- The final focused selection passes **64 UI/store declarations in 15.419 seconds**,
  **65 Core declarations in 2.096 seconds** and **1 Terminal declaration in 0.065 seconds**.
  It includes desktop/setup/link/quit/banner/power cases and affected keyboard/composer
  regressions. The earlier expanded **453 UI declarations** run had one new private-vault
  fixture failure; the other 452 passed. The final focused run covers that corrected
  fixture. No exact-current-tree full UI-suite success is claimed.
- Fixture fixes resolve the existing macOS temporary parent before appending private
  paths, retain O_NOFOLLOW vault checks and compare readiness to the original registered
  project path. A Swift Testing mutable-call macro was evaluated before its assertion.
  All existing declarations and deadlines remain.
- **75 native CI configuration/offline-harness tests pass in 2.532 seconds**. Version,
  icon and bundled-notice changes now select CI; unrelated narrative docs still skip
  native UI work. Synthetic bundles fail validation if URL handlers remain.
- Build-only packaging, strict deep signatures and native math-resource rendering pass.
  Actual bundle version/icon/URL scheme and every shipped notice are verified. Font
  license copies match their resolved SwiftMath sources. The generated icon was inspected;
  no app was installed/opened. Compiled/package UUIDs match: Coincide
  `8AB5C8ED-47D9-3201-A8F1-063F2A74D0CC`, CoincideEnvironment
  `B3C729AE-7946-3C92-80AB-F84F8D292A6E`, CoincideScriptHelper
  `F91AA44E-501A-3A7D-B9E4-CBB2D5ED9AF9`.

Logs use `/tmp/coincide-desktop-shell-*-20261024.log`. Staged secret scanning passes.
The preceding Git-actions hosted build passed and its tests were still running at the
last check. This desktop merge has no exact-commit hosted/native GUI or live provider,
URL-handler, install, shell-startup or power-assertion acceptance claim. No user account,
credential, real SSH host, installed app or shell configuration was changed. Complete
T3 parity, remaining transcript/project-script features and live/hosted acceptance remain
unfinished. See [desktop behavior and limits](DESKTOP_SHELL.md).


## 2026-10-24: Hosted protocol failures and status reconciliation

Hosted Git-actions run `40010287048` compiled successfully and completed 2500 tests
across eight suites in 1403.512 seconds with two issues: the Muse flood expectation
and OpenCode v1 steering's status boundary. The remote 5001-line review-sheet test
passed in 0.102 seconds. Native GUI shards were skipped after Core failures; their
aggregate failure is not a GUI-test result.

- Muse's old stimulus assumed 5000 ignored status notifications would overflow a
  128-slot transport buffer. A consumer keeping up correctly avoids overflow, so
  the expectation depended on scheduling. The fixture now acknowledges each of
  64 valid pending approvals before emitting the 65th, deterministically reaching
  the Session's explicit limit. Failure, exact 64 presentations, no fabricated
  completion and no reuse remain asserted. The separate deliberately unopened
  consumer test still proves actual transport-buffer overflow. Production Muse
  behavior and all deadlines are unchanged.
- A controlled OpenCode v1 held-busy-response regression failed before the fix in
  5.045 seconds: a later native idle could be overwritten by an older status read.
  Each owned run now versions idle/busy/retry observations. Stale reads cannot
  retire newer idle evidence or finish work after newer activity; reconciliation
  preserves current run/input/admission ownership. Held idle/busy/retry tests prove
  one completion and two total prompts without replay. Early-idle fixtures omit a
  later busy notification when their purpose is to require status reconciliation;
  original assertions and deadlines remain.

Final local verification: `swift build --build-tests` passes in 18.89 seconds;
ABI coverage reports 1418 Mach-O objects, 1018 Core/459 App coverage counters,
zero weak async-default records and six local records. The complete affected
selection passes **137 Core declarations in 14.578 seconds** and **7 UI/store
 declarations in 2.784 seconds**. Build-only packaging, strict deep signatures and
native math rendering pass. Compiled/package UUIDs match: Coincide
`EB0CB1C9-D84A-33AD-B5E7-7E8084BA0894`, CoincideEnvironment
`AE35FE90-82B2-31F6-A4B7-33A1DA7DD96D`, CoincideScriptHelper
`F8192742-18E2-3948-94EC-C9132D3530C1`.

Logs use `/tmp/coincide-protocol-ci-*-20261024.log`. Staged secret scanning passes.
No live provider/model request or installed-app launch was performed. Hosted
success for this follow-up and full native GUI/provider/T3 acceptance remain
unproven; the overall app goal remains active.


## 2026-10-24: parallel Work starting checkpoint

Integrated scratch conversations and their plan/history adapters, Codex plan
controls, first-send worktree defaults, remote composer/steering/queue/thread
actions, JSONC-preserving shortcut edits, and transcript provenance fixes.
Physical scratch ownership is checked again before rewind/history work. Remote
composer metadata now respects its private store's 16 MiB limit, and only the
two closed attachment-preserving composer compositions receive a larger native
command-batch bound. Other remote commands retain the existing two-action limit.

Final local `swift build --build-tests` passes in 24.46 seconds. The affected
selection exercised 181 Core and 28 native store/UI test declarations. Its only
remaining failures were three fixture assumptions: two filesystem/Unicode path
normalization cases and an archive-state expectation. Those fixture-only fixes
were followed by complete affected-declaration reruns: 2 Core declarations
(including all eight changed-source arguments) passed in 0.047 seconds and
2 UI declarations passed in 0.112 seconds. All 209 selected declarations thus
have passing evidence across the unchanged passing selection and corrected
reruns; this was not a new all-green full-suite invocation.

The final async-default ABI guard covers 1,567 Mach-O objects, with 1,165 Core
and 540 App coverage counters, six local default records and zero weak default
records. Diff whitespace checks and Python fixture parsing pass. The selection
includes physical scratch-folder replacement, omitted composer references,
original command receipt reuse, worktree recovery, and process/stream draining.

Evidence logs use `/tmp/coincide-cloud-baseline-`: `build11-20261024.log`,
`focused3-20261024.log`, `final-fixtures-20261024.log`, and
`abi-verified-20261024.log`. This checkpoint does not establish full hosted CI,
packaging, installed-provider, live SSH, or interactive native UI acceptance.
The eight independent feature briefs in `CLOUD_TASKS.md` are a handoff for
ChatGPT Work or a dot coordinator, not a claim that those tasks have started or
that full T3 parity is complete.

## 2026-10-24: native chat UI and Coincide-owned conversations

User direction supersedes the earlier T3 parity work: focus on Codex/Claude,
local development, the supplied ChatGPT layout, and CLI control. Automated
tests, provider smoke prompts, and hosted CI were explicitly deferred for this
pass. No test suite or model inference was run for these changes.

The updated native app builds, packages, signs and opens successfully through
`script/build_and_run.sh --verify`. The combined context/import build completed
in 39.36 seconds; the final incremental packaging build took 10.21 seconds.
Logs are `/tmp/coincide-context-copy-final.log` and
`/tmp/coincide-final-package.log`. Existing unrelated compiler warnings remain.

Live local CLI inspection loaded seven Codex and thirteen Claude catalog rows
without catalog errors. This verifies discovery, not authentication or inference.
The CLI captured the revised chat, unified model popover and Models settings at
`/tmp/coincide-final-chat.png`, `/tmp/coincide-final-picker.png` and
`/tmp/coincide-final-settings.png`; all three were visually inspected. Provider
marks, nested project chats, a single sidebar selection, the centered composer,
and native settings/model visibility controls are present. The reference was
inspected in the user's Chrome with explicit permission, then returned to its
original General settings page. No ChatGPT desktop installation was needed.

An existing imported conversation was switched Codex → Claude → Codex via
`script/coincide model`, without sending a prompt. Its Coincide UUID and all six
saved visible messages were unchanged (message payload hashes compared before
and after), the original model was restored, and its original native session
binding was cleared. One portable context transfer remains pending for the next
authored message. The selected empty chat was restored afterward.
The saved six-message copy, detached binding and single pending transfer were
read back successfully after rebuilding and restarting the app.

New imports now save independent copies; older imports detach at their next
submission, with old source-bound queues and recovered provider-start effects
blocked. Imported histories retain the existing bounded import policy (at most
200 messages per conversation). Context delivery is budgeted public text, not
private reasoning or attachment-byte replay. First-reply context delivery,
fresh-import execution, and the earlier Codex app-tool readiness failure are
not established as fixed by these build/catalog/navigation checks. Those need
the deferred provider runtime validation; the app is not claimed fully tested.


## 2026-10-24: embedded Settings and native navigation review

Removed the separate SwiftUI Settings scene. The app menu, Command-comma,
rail, model picker, welcome review action, command palette, and local CLI now
route to Settings inside the existing main window. All eight supported pages
use shared native cards, rows, menus, and typography; runtime paths and shortcut
conditions are in advanced disclosures. Home returns to the selected chat,
New Chat consistently creates a chat, and notification/link selections leave
Settings. Existing saved file-operation holds expose their guarded recovery
controls without restoring the removed inspector.

The installed ChatGPT desktop General page was inspected directly. Coincide's
General, Appearance, Notifications, Agents (Codex and Claude), Models,
Conversations, Keyboard, and About pages were visually inspected with CLI PNGs
and native window snapshots. Catalog discovery returned seven Codex and thirteen
Claude models. The app-menu Settings command and an actual foreground
Command-comma both opened embedded Settings in the same main window. Clicking
Home retained the selected empty chat and all nine saved chats. A conversation
URL returned from Settings to that same chat without sending a prompt.

That URL check also exposed SwiftUI creating an extra main window. The scene now
prefers handling external events in an existing window, and presentation prefers
the current window. These final routing changes compiled successfully but were
not re-exercised after the user requested no interruption on the external display.
The active app was left closed; subsequent work was build-only. Future visual
checks for this task must stay entirely on the built-in Mac display, including
relaunch placement, rather than relying on macOS's active-screen restoration.

A sampled quit hang showed NSApplication termination inside the shortcut's task,
while shutdown joins that same task. The product quit callback now dispatches
termination after the shortcut task returns. This correction was compiled; the
quit interaction itself was not rerun. The already-quitting idle development
process was stopped without reopening it. Saved conversation files were not
modified for these checks.

Native packaging/signing/launch checks passed before the final build-only pass
(logs: `/tmp/coincide-settings-navigation-build.log`,
`/tmp/coincide-settings-navigation-release-check.log`, and
`/tmp/coincide-settings-window-routing-build.log`). The final build-only log is
`/tmp/coincide-inline-settings-build-only.log`. Visual captures use the local
`/tmp/coincide-inline-` prefix. Automated tests, provider smoke prompts, and hosted
CI remain deferred by explicit user direction. This evidence establishes native
build and inspected navigation/layout behavior, not complete provider execution
or pixel-for-pixel parity with every ChatGPT feature.

## 2026-10-24: final native UI pass on the built-in display

Development launches now support explicit built-in-display placement and
background presentation. The local CLI can move the main window to that display
and reports its display, full-frame containment and visible main-window count.
These options do not change normal launches or saved display preferences.

The live pass inspected the chat, existing two-message transcript, unified model
picker, all eight Settings pages, new-project and import dialogs, and the
shortcut editor. Layouts were inspected at 1412×811 and 1000×700 points. Every
main-window checkpoint remained on the Built-in Retina Display. The model
picker's Settings button and the app-menu Settings action opened embedded
Settings. Home preserved the selected conversation and its two messages; chat
search filtered its title correctly. A conversation URL reused the existing
main window (one before and after), confirming the prior routing correction.
The app-menu Quit action exited cleanly; the shortcut-specific quit path was
not exercised in this background pass.

The review found and corrected wrapped composer sizing (now measured by the
native text layout), empty/cramped shortcut editing, setting-keyword search,
and the Claude model card's link to the wrong agent settings. Selecting a
different saved project in an unstarted, unbound chat now reassigns that chat
atomically, retaining its UUID, draft, attachments and model. History-bearing
or busy chats cannot be reassigned. The saved workspace has only one project,
so cross-project reassignment was reviewed and compiled rather than exercised
against user data. No projects, imported chats, provider turns or saved
shortcuts were created during this pass.

The final native build completed in 39.46 seconds and bundle signature
verification passed (`/tmp/coincide-ui-final-polish-build.log`). After relaunch,
a temporary unsent paragraph grew the composer through native soft wrapping;
it was cleared and the original empty draft restored. The shortcut editor
showed its full-width field, “No shortcut,” and disabled Save with no spurious
warning. Typed Settings searches for “math” and “Claude” showed the relevant
pages. The app was left on the built-in display with the original empty chat,
one project, nine saved chats and no running turns. Capture files use the local
`/tmp/coincide-ui-final-` prefix.

Automated tests, hosted CI and provider execution checks remain deferred by
explicit user direction. Visual inspection and a successful native build do
not establish full runtime/provider validation or exact ChatGPT feature parity.
