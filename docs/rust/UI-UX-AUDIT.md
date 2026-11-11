# Swift / Rust UI and interaction audit

Started 2026-11-09 against the actual Swift app and Rust 0.1.33, following the
user's full-app parity request. This is an open acceptance record, not a claim
that the port is complete. Existing unit tests and older checklist checkmarks
are not screen or interaction acceptance.

## Requirements recovered from the conversation

The user explicitly asked for all screens and interactions, including responsive
typing in long imported chats; model/account discovery for every provider;
buttons with menus attached to their anchors; sidebar heading/alignment parity;
Swift's compact grouped work, reasoning and questions; and complete navigation,
settings and panel behavior. The microphone was an example, not the scope.

## Confirmed defects addressed in this work

- The macOS reply font asked for `New York`, which `NSFont(name:size:)` cannot
  resolve. AppKit's actual serif is `.AppleSystemUIFontSerif` / `.NewYork-Regular`.
  Register the installed system font with GPUI and use its real family.
- Render the colored agent rail and header logo beside work/replies.
- Replace large reply-action labels with accessible compact icons. Only the last
  visible reply in each turn has its signature; retain full-text copy and fork.
  Restore the reply timestamp.
- Plan each encountered turn once per render pass, instead of rescanning and
  allocating its full group plan for every virtual list row.
- Replace the toolbar's expanding action strip with a right-anchored menu.
- Replace stacked General Settings choice buttons with right-aligned anchored
  pickers and captions, preserving their existing save handlers.
- Retain the previously uncommitted work-group summary/disclosure changes.

The default sidebar width is already 288 points in both implementations.
Differences observed between the live windows can also come from their saved
widths; no default-width change was made.

## Acceptance matrix — still open

| Area | Required comparison / interaction |
| --- | --- |
| Window and navigation | Titlebar/chrome, rail icons, sidebar width/resize, selected/hover/focus states, narrow window, projectless and empty state |
| Sidebar | Bots/Pinned/Projects/Chats headings, avatars, truncation, elapsed times, drag/reorder, context menus, archive/snooze, selection and undo |
| Composer | Typing/paste/IME on long history, draft restore, attach/remove, mentions/slash, multiline resizing, send/stop/steer/queue, disabled states |
| Models/accounts | Every provider, loading/error/retry, cached reopening, current account/model, account switches and anchor placement |
| Transcript | Rail continuity, provider changes, grouped and individual tools, reasoning, live/finished/failed turns, questions, approvals, plans, tables/code/media |
| Transcript interactions | Full/partial selection and copy, links, code copy, find/reveal, fork, rewind/edit, follow-tail and scroll preservation |
| General Settings | Compact row layout, appearance/themes, font controls, message side, shortcuts, tooltips and persistence |
| Other Settings | Models, Usage, Instructions, Archive, Keyboard, Voice, Browser, Computer Use, Appshots, media, all provider pages, About |
| Overlays/dialogs | Anchor geometry, dismissal by Escape/outside click, keyboard traversal, clipping and restored focus |
| Terminal | Bottom/right layout, tabs/splits, resize, scroll/selection/copy, input and shell integration |
| Git/diff | Branch/status, changed files, staged/unstaged diffs, commit, worktrees, error and loading states |
| Pull requests | Lists/filters, detail/review, comments, checkout and merge controls |
| Browser | Address, navigation, tabs, loading/error, downloads, dialogs, permission/human handoff and embedded layout |
| Schedules | List/filter, editor, approval, busy-thread behavior, time zones and restart persistence |
| Bots/import | Editor/avatar/personality, create/open, session preview/import, progress/errors and cancellation |
| Usage | Composer usage/context controls, limits/reset labels, charts/history, empty/error states |
| Accessibility | Content controls appear after accessibility activation; initial snapshots showed only chrome. Audit initial exposure, dropdown trigger actions and transcript text with VoiceOver; full acceptance remains open |
| Platforms | macOS native comparison first; corresponding Windows/Linux rendering and native interaction still require new runs |

## Evidence

Native screenshots of Swift/Rust transcript and General Settings were inspected.
The initial installed bundle was confirmed as 0.1.33; no active Rust turn was
running. `NSFont` probing confirmed the missing family lookup. The changes before
the final Settings picker adjustment passed 815 desktop tests; the subsequent
suite with the final-reply regression passed 816 (26 ignored). Final native
screenshots and interaction outcomes must be recorded below as they are run.

## Wider native audit findings

Navigation through General, Models, Usage, Instructions, Archive, Keyboard,
Voice, Browser, Computer Use, Appshots, Historical images and provider Overview
was exercised in the isolated snapshot. Initial About activation did not change
the page, so About is not accepted. Screenshots and accessibility reads are in
the review directory recorded by `reports/ui-review-location.txt` (scratch).

Additional fixes: remove duplicate Pull Requests toolbar control; set the
Settings body to the same 13-point base size; use a compact overflow menu for
shortcut reset/removal; stop the Usage provider/period filters squeezing their
label into individual letters; avoid duplicate Models page headings; remove
implementation-audit text from the model button tooltip.

The first review executable used Cargo's empty default feature set. This makes
Apple Speech unavailable and disables native microphone/notification/computer
use backends even though their source exists. Native acceptance and the subsequent
review builds enabled `native-microphone,native-notifications,
native-computer-use`. Enabling a backend does not constitute a microphone,
notification permission or desktop-control runtime acceptance test.

Remaining observed gaps include browser settings that expose migration-oriented
controls and text, the Instructions page's nested editor/long setup section,
macOS titlebar integration, initial accessibility exposure, and a complete pass
through panels, resizing, scrolling, loading/error states and the other OSes.

Normal desktop builds now enable those three native features by default; a
minimal build must explicitly request `--no-default-features`. This prevents
ordinary `cargo build` from silently producing the reduced preview again.

## Latest verification

The native-feature suite passed 817 tests (26 ignored). The final release
executable was launched from a separate signed review bundle using a SQLite
backup of Rust data; the installed 0.1.33 bundle and original databases were not
replaced. The review is not a public release.

The 27,072-item conversation opens and renders. An initial combined foreground
click/type attempt unexpectedly targeted a new conversation; this attempt is
not counted as successful. After explicitly selecting the large conversation
and focusing its composer, the `typing check` draft appeared and persisted in
that exact thread without adding transcript items. This is a scoped input
check, not a latency benchmark or a blanket performance claim.

Repeated Settings restarts exposed 32-point growth per reopen. The saved outer
frame was being passed back to macOS as a content rect. Settings and the main
window now save their content size on macOS; a repeated-restore regression was
added. Final native repeated-open dimensions still need verification.

In the large conversation, native clicks expanded the finished-turn header and
then its work group. The expanded individual tool/reasoning rows were inspected
in a fresh screenshot. The latest regression suite passes 818 tests (26 ignored).

## Final batch status

- `cargo test -p coincide-desktop --bin coincide-rust --locked`: 818 passed,
  26 ignored, zero failed, with the default native features enabled.
- `cargo build --release -p coincide-desktop --bin coincide-rust --locked`:
  passed. `git diff --check`: passed.
- Settings closed through Done, reopened at 860 × 833, closed and reopened again
  at 860 × 833. The old progressive 32-point growth did not recur.
- Browser, PR workspace and Scheduled screens were rendered and inspected.
  Their current UI still contains broad parity gaps: multi-row browser text
  controls, the PR workspace's repository/ledger setup surface, and scheduling
  layout. Terminal and Search did not produce a verified new surface in this
  route sequence and are not accepted. An archive confirmation appeared during
  navigation; no archive was confirmed. This needs an isolated interaction
  check, not a successful-action claim.
- The installed Rust app remains 0.1.33. Changes are in the isolated parity-batch
  worktree, uncommitted; the review app uses a separate copy of its database.
  No full-app UI/UX completion or Windows/Linux native acceptance is claimed.

## Substantial surface rebuild (next batch)

- Browser: a scrollable tab strip with per-tab close, compact navigation and
  address row, native back/forward availability, and icon controls for Agent
  Control, bookmarks/history, saved-login fill and reload. Existing dialog,
  login and passkey banners remain above the page. The bookmark library now
  also lists the bound profile's recent history through the existing controller.
- Pull requests: use the existing `github.pr.availability` worker to discover
  the selected folder's repository, preserving exact thread/root checks and
  rejecting late replies. Manual repository selection remains in an explicit
  settings control. The local GitHub-action ledger is presented when actions
  are relevant, not as the first screen above every read-only PR list.
- Workspace: compact view chooser replaces four competing permanent tab buttons;
  Changes, Local Git, Pull Requests and Review comments remain reachable.
- Instructions: project/global selector, master and agent-file sidebar, a
  full-height editor, and pinned Save/Reload/status. Setup, linking, copy and Git
  sync controls remain in a sidebar disclosure. Existing dirty-file and native
  write custody checks still govern every file switch and save.

Native verification and the final test result for this batch follow below.

## Native verification of the substantial rebuild

The release executable was run in the separate signed review app against the
existing isolated database backup. In the native macOS UI:

- The browser opened with compact tab/address rows. Entering an HTTPS address
  loaded the actual page; Back became enabled. The bookmarks/history library
  opened and completed its read. An invalid address followed by a valid one
  exposed a stale browser error in the composer; successful browser requests
  now clear that stale error. The library's routine refresh text and large
  reload button were replaced with a compact refresh control.
- Instructions opened as a full-height split editor. Selecting `.claude/CLAUDE.md`
  changed the file header and selection while preserving the editor viewport.
  No instruction file was edited or saved during this visual check.
- Pull Requests discovered `apoorvdarshan/coincide` automatically. Its initial
  empty state matched the open-PR result. The anchored filter menu switched to
  Merged, loaded 30 rows, and selecting #360 opened its details. No GitHub write,
  checkout, merge, review submission or action-ledger initialization was run.
- Native inspection revealed that PR rows and browser tabs had labels but no
  accessible button role. Both now explicitly expose their button role.
- The generic inspector close control is now an accessible compact icon.

Final regression run: 820 passed, 26 ignored, zero failed. The build and final
native check are recorded in the scratch reports alongside this audit. These
results accept this batch's tested macOS surfaces; they do not close the broader
acceptance matrix or claim native Windows/Linux verification.

## Installed result

Rust 0.1.34 (build 44) was signed, accepted by Apple notarization, stapled,
verified by Gatekeeper, and installed in `~/Applications/Coincide Rust.app`.
The restarted app responds on its original control socket. Its executable
matches the signed artifact byte for byte. The previous 0.1.33 bundle is retained
as `~/Applications/.Coincide-Rust-0.1.33-rollback-4e3281b6`. The original data store
was retained; native UI experiments used the separate review snapshot.

The final native build exposed selectable browser tabs and PR rows to
accessibility; selecting #360 through its accessibility action opened details.
Creating and closing a tab was verified. Invalid HTTPS input displayed its error,
and a subsequent successful navigation cleared that error from the composer.
The compact bookmark refresh button and library were inspected again.

The wider acceptance matrix remains open. No claim of complete Swift parity,
native Windows/Linux acceptance, or end-to-end testing of every provider is made.

## Full-app continuation — 2026-11-09

Further source comparison and native inspection found functional gaps beyond
cosmetic spacing. This continuation implements:

- Unified macOS main-window chrome, correct titlebar frame migration, and native
  drag/double-click behavior. The reopened main window measured 1470 × 837.
- Sidebar heading action order and status precedence: pending approvals remain
  visible on bots and collapsed sections, ahead of ordinary running activity.
- A centered, scrollable schedule editor with native calendar/time controls,
  target selection, recurrence menus, focus handling, and a pinned action row.
  The Add menu offers current-thread and new-thread-per-run tasks. Schedule
  deletion now asks for confirmation; project rows without a past run open Edit.
- Visible provider account management, compact switches and pickers in Models,
  Voice, Browser, Computer Use, Appshots, provider pages and update settings.
  Models now support row keyboard selection and contextual preference actions.
- Browser private-session defaults that survive relaunch, retain explicit
  thread choices, and pin active native views to their actual profile. Browser
  settings can edit the default Agent Control setting without changing explicit
  per-thread overrides. Saved bookmarks can be removed from Settings.
- Browser metadata reads wait through brief engine contention and observe
  cancellation while waiting; opening Settings no longer turns a transient
  snapshot lock into an immediate permanent refresh error.
- Shared dropdown triggers expose native accessibility activation and keyboard
  focus. The prior component's mouse-down-only trigger had no AXPress action.
- Scrollable terminal tabs and a route fix for opening a bottom terminal from
  the global Scheduled screen. Selecting a conversation leaves that global view.

The native schedule fixture was saved through the editor, read back through the
isolated instance's API, and deleted through the row menu. Readback confirmed
`threadID: null`, the selected project, and `awaitingApproval: true`; it never ran.
This run exposed the absent delete confirmation and hidden terminal route above,
which were then fixed. Updated screenshots also exposed caption overflow in
Browser and the Models filter occupying two rows; both layouts were corrected.

Review binaries use the separate snapshot recorded in the scratch reports.
One intermediate launch omitted the snapshot environment and opened the normal
Rust data directory; it was closed without exercising any controls. Subsequent
launches explicitly bind `COINCIDE_RUST_DATA_DIR` and verify the opened SQLite
path before interaction. Do not describe that launch as an isolated-data run.

This record does not equate implemented controls or passing unit tests with
complete Swift parity. In particular, browser data clearing, all password-manager
capabilities, every transcript/media state, and native Windows/Linux acceptance
still require separate verification or implementation. Final results for this
continuation are recorded below after the reviewed binary is exercised.

### Native interaction checks from the updated review build

- All 18 Settings pages opened and were captured. Provider pages now actually
  show the existing account controls. Browser captions wrap without pushing
  switches outside the window; its bookmark/history reads complete normally.
- AXPress opened the Models provider picker and the schedule Add/target menus.
  Selecting OpenCode changed the model filter. A model row's context menu showed
  its copy/default/favorite/hide actions. No provider authentication was changed.
- Schedule deletion displayed the native confirmation sheet. Cancel retained the
  fixture; confirming Delete removed it. Creating a project task from a
  projectless conversation exposed an invalid default target; the default and
  Save enablement were corrected.
- Terminal opened from Scheduled, started in the isolated fixture checkout, and
  executed a `printf` marker, confirmed from the actual grid screenshot. This
  exposed the old diagnostic footer, incorrect placement above the composer,
  and disappearance when the app became inactive. Those were replaced with a
  compact actions menu, a true bottom drawer, and retained inactive presentation.
- The isolated Git fixture loaded `sample.txt` as modified with two additions
  and one removal. No commit or remote operation was performed through the UI.
- Reopening revealed a smaller, separate window-frame bug: the drawable view's
  insets were being persisted. Frame saving now reads the actual AppKit content
  rectangle. The native AppKit probe confirmed ordinary and unified windows use
  different frame/content relationships; final repeated-open validation follows.

The composer comparison also found that Rust had neither the context ring nor
plan-limit bars. They now render from already-reported data: the latest request
snapshot for the current conversation/provider/account, and the currently scoped
Codex or default Claude limits. Selection changes and turn completion trigger an
owned background saved-usage read; streaming deltas do not rescan history. The
popover shows reported input/output/cache/cost values and every limit window.
Missing data stays absent, and billed turn totals are never used as a context
snapshot. A synthetic 50% snapshot is used only in the isolated review database
for visual verification; it is not a measurement of actual usage.

### Latest verification

- Desktop suite: 827 passed, 26 ignored. Core suite, with native process-guard
  tests run without a GUI instance and serially: 1,165 passed, 9 ignored.
  The zombie-process fixture now waits for SIGKILL to take effect before asking
  the installer guard to prove the process stopped; live-process checks remain.
- Native Settings was resized, allowed to settle, closed and reopened twice.
  All three observations were 900 × 702 at (200, 80), with no size drift.
- The isolated 50% context ring appeared. AXPress opened its details showing
  100.0k/200.0k input/context, 200 output tokens, 5.0k cached input and $0.0123.
  Those numbers are synthetic fixture values, not real spend or usage.
- The bottom terminal now renders below the composer with its compact header;
  the large history/copy diagnostic footer is gone. The same snapshot showed
  the fixture's tracked and untracked file diffs correctly.
- Composer labels now follow Swift's compaction order instead of wrapping the
  controls into extra rows. The empty-chat layout uses the available chat area,
  the registered reply font, and no microphone when dictation is disabled.

The final native run confirmed that the bottom terminal stays open on relaunch,
starts/restores a real PTY, and retains its saved 120-point drawer height. After
scrolling the sidebar to expose the target, selecting another conversation and
returning restored each conversation’s terminal. An offscreen AXPress initially
did not select the row; that attempt is not counted as a successful interaction.
The narrow and wide layouts both kept the composer controls on one line.

The context button’s accessible label now also reports output, cached input and
cost, using the same snapshot as its details. An explicit plain-terminal request
made before window activation remains pending until the workspace mounts.

Final desktop regression run: 827 passed, 26 ignored, no failures. The release
build of the desktop, CLI and store binaries passed. The final reviewed source
commit is `e1ca101f71cf946578ffc53f7f9126c6ef2d3945`.

One background API-quit run exposed a shutdown dependency on rendering a final
frame. Offscreen/minimized windows may never draw it. Shutdown now depends on
saved drafts and joined owners, without requiring visual acknowledgement; all
actual drain gates remain. The final review window was explicitly minimized,
verified absent from the visible screen, and then exited through the API in
0.97 seconds without forced termination. About was also opened successfully
after scrolling its sidebar item into view. The synthetic usage record was
removed from the isolated review database after visual verification.

The broader matrix remains open, including the remaining import and
password-manager capabilities, exhaustive transcript and media states,
provider-specific end-to-end runs, and native Windows/Linux acceptance. The
browser Clear Browsing Data flow is implemented; its native site-data callbacks
still need Windows and Linux acceptance and a real-profile run.
A production bundle does not turn those unchecked rows into completed parity.


### Installed 0.1.35 checkpoint

Version 0.1.35 (build 45), from `e1ca101f71cf946578ffc53f7f9126c6ef2d3945`, was signed with Developer ID,
accepted by Apple notarization, stapled and validated by Gatekeeper, and installed
in `~/Applications/Coincide Rust.app`. The installed executable matches the
signed artifact byte for byte (SHA-256 `2c8dc43f35d1d6fefd2cec6cd28b0c64d44dc9670483fe0f610ea4e2bbb224f0`).
The app opened its original Rust SQLite database and answered through its
original control socket with zero pending persistence and no running/starting
turns. The previous 0.1.34 bundle remains at
`/Users/apoorvdarshan/Applications/.Coincide-Rust-0.1.34-rollback-1794235557998615000`. No review snapshot or synthetic usage data was installed.

This is a verified checkpoint of the 50-file continuation, not closure of the
full parity matrix.

### Browsing data clearing

Settings › Browser now matches Swift's "Browsing data" row: it reports the
history item count, keeps bookmarks, and confirms before clearing. The
confirmation offers Clear Everything, Clear Cookies and Site Data, Clear
History, and Cancel with the same warning as Swift. The request is bound to the
current thread and profile revision; history uses an immediate SQLite
transaction with a stale-revision check, and site data is removed through the
native WebKit/WebView2/WebKitGTK owner before open pages reload. A failed or
partial native callback is reported instead of claiming success. Store,
profile-scope, revision, bookmark-preservation and API tests pass. The
site-data callback path has not been run against a disposable real profile;
Windows/Linux native acceptance remains open.

### Installed 0.1.36 checkpoint

Version 0.1.36 (build 46), from `109392c3`, was signed with Developer ID,
accepted by Apple notarization (`d9836882-df31-41a3-90dd-9d31e1adc741`),
stapled and installed. The browser's Browsing data row, history count and
confirmation prompt were verified in the installed app. The group work-log
line was verified in the transcript: "Ran 1 command" while collapsed, with
nested Thought/command/Thought rows after expanding, and the live "Working for"
and "Thinking…" rows while a turn runs. No browsing data was deleted during the
check; the destructive confirmation was dismissed.

## Full Swift → Rust UI pass — 2026-11-09 (0.1.40)

A second complete pass walked every Swift UI area against its Rust counterpart
at `0779a890`, area by area. This is a code-level comparison; screen and
interaction acceptance still has to be recorded per item, and Windows/Linux
native acceptance remains open. Items below are what is still missing or
simpler in Rust; everything not listed matched in code.

### Composer

- Non-image paste/drop and file attachment cards are absent; the attach picker
  is images-only (`composer_attachments.rs`).
- Placeholder states beyond default and plan text are missing (no thread,
  provider unavailable, missing worktree, pending approval/question).
- Attachment strip has no preview/QuickLook and no "this model cannot read
  images" warning.
- Send is not blocked for a preparing worktree or missing folder, and a pending
  approval is not declined before sending.
- Usage-limit warning banner and "Resume at reset" are absent; limits are
  menu-only (`composer_meters.rs`).
- No agent-switch handoff banner, no question "Dismiss/Skip", no history recall
  with Up/Down, no Shift-Tab Plan toggle, no inline mention tint.
- Mode facet requires an Apply inside the popover; Swift toggles Plan directly.

### Transcript

- Approval and plan rows fall through to the generic message card (labelled
  `approval`/`plan` with a 180-character excerpt) instead of Swift's kind,
  warning accent, resolution and checklist progress.
- Errors collapse at 180 characters instead of a full red card.
- No fork dividers ("Forked from conversation" / "Conversation fork").
- Agent rail is a flat 1px line: no per-agent gradient, message rings or live
  dot; bot conversations show a generic glyph rather than the bot avatar.
- User messages lose Steer/Scheduled marks, long-message folding and the
  hover-only edit/copy/time row.
- No "Thought for 4s", no animated spinner/shimmer for running groups.
- Media is images-only: no video, audio or sandboxed interactive HTML; every
  fenced code block now carries Swift's per-block copy control.
- Every finished turn gets a "Turn ended" notice row (Swift shows only
  "Interrupted"), and background-task lines are missing from the live row.
- Welcome/empty state is a headline plus "Using X": no agent chips, setup
  hints, "Check Again", "Agent Settings" or "Locate Folder".

### Window, sidebar, navigation

- No macOS unified/customizable toolbar: no Show/Customize Toolbar, and the
  thread actions are a fixed strip inside the chat column.
- Archiving, snoozing or deleting the open thread leaves it open; Swift opens a
  neighbour.
- Only one-shot Undo: no Redo for archive/settle/move/delete, and review flows
  are inline panes rather than sheets.
- Bot and Chats conversations have no proxy icon/Open In/Reveal/Copy Path.
- Empty Chats header and "No chats yet"/"Only pinned threads" notes missing; a
  Rust-only project filter row changes the header layout.
- Bot/project drag reorders even when the sidebar is sorted by Name/Activity.
- Frame restore uses a separate key without native window/Space restoration.

### Settings and About

- General lost default model/effort, resume-after-limit, agent thread titles,
  schedule approval, idle timeout, background agents, checkpoints and branch
  prefix; Keep Awake is a stub, not the 24/7/lid/battery/display controls.
- Coincide Remote panel exists but is not mounted, so pairing is unreachable.
- Usage lacks display mode, refresh interval, outside-CoA usage, menu-bar usage
  and browser sign-in controls.
- Keyboard settings lack search, conflict summary, unusable-shortcut cleanup and
  the fixed-shortcut reference groups.
- Passwords lack saved-login management, CSV import and per-site agent grants.
- Computer Use lacks show-agent-cursor, driver version and Restart/Stop; its
  permission rows have no System Settings buttons.
- Provider pages use Save/Discard instead of immediate writes and simplify the
  Cursor usage, Codex and Antigravity panes.
- About has no build number, and App Updates has no app-menu "Check for
  Updates…" or standard About panel.
- Settings search exposes 19 reveal rows against Swift's ~40.

### Panels and tools

- Browser import is largely missing: no Safari/Chrome/Firefox cookies, history
  or bookmarks, and no password CSV; only a Firefox cookie snapshot and JSON
  bookmark export.
- Browser page-load failures, per-tab loading state and the private-profile /
  "agent used this browser" status line are absent.
- Diff panel has no turn scopes and no "Comment on Selected Lines" → composer
  context.
- Terminal ⌘F find and ⇧⌘[ / ⇧⌘] tab cycling are present; find covers the
  visible page only (core never exposes raw scrollback to the UI).
- Saved-login fill detours through Settings instead of listing matching logins
  and one-time codes in place.
- Schedule approvals lost Swift's in-thread approval card.
- Browser keeps up to 128 tabs without Swift's memory-budget unloading.

### Menus, palette, bots, import

- Palette is missing bots/New Bot, Stop, Find in Thread, Pull Requests,
  Pin/Rename/Archive, appearance, Refresh Agents, Help links, and the model/
  effort/access/plan submenus.
- Bot editor cannot change an existing bot's agent, model, access mode or
  Plan/Build mode (rendered read-only).
- Menus lack Check for Updates, Reveal Imported Source, Paste and Match Style,
  Delete, all spelling/substitution/transformation/speech items, Dictate, Show/
  Customize Toolbar and the Go to Thread 1–9 items.
- Notifications use generic titles instead of the thread title and excerpt, and
  have no Remote/CloudKit routing.

### Known non-UI follow-ups from this pass

- Native Windows and Linux interaction acceptance still needs new runs.
- The macOS Linux/Windows smoke scripts now find the conversation window by its
  process instead of the old fixed title, matching Swift's thread-title window.

## Transcript code-block copy — 2026-11-10

Swift's reply cells give every fenced code block its own copy control in the
block's top-right corner, separate from the whole-message copy. Rust only had
message-level copy, so a code example inside a long answer had to be selected by
hand.

`transcript::code_copy_actions` is now installed on every native Markdown body
that the transcript draws, including the find-projected body and the tool-detail
body. The control copies the block's own source exactly (whitespace, tabs and
Unicode preserved), never the surrounding reply, and is disabled for an empty
block. Its element identity comes from the fence's parsed source offset, with a
content hash for custom nodes that have none, so repeated identical examples in
one document keep separate controls.

Unit coverage: verbatim payload, empty block, and stable/non-colliding identity
(`cargo test -p coincide-desktop --bin coincide-rust transcript::`).

## Bot conversations' folder — 2026-11-10

A bot conversation's folder is not in the user's project list: Swift gives every
bot its own folder (`Bot.workingDirectory`, home when unset) and resolves a
thread's folder as worktree, then the bot's folder, then the project. Rust asked
only for `worktreePath` or a project, so imported bot conversations with no
worktree showed **Folder Not Found** in Changes and Local Git, and their
terminal started in the home folder instead of the bot's.

`thread_folder::working_directory` now applies Swift's order for the panels, and
the terminal's start directory asks the bot's folder when no project matches.
A deleted bot and a bot without a folder both fall back to home, as in Swift; a
stored folder that no longer exists is still reported as missing rather than
silently replaced.

Unit coverage: worktree over bot over project resolution, a bot's folder, a
deleted bot's home fallback, and the terminal's bot-folder start.

## Composer prompt recall — 2026-11-10

Swift's composer recalls earlier prompts of the conversation with Up and Down.
Rust had no recall; both keys only moved the caret, so re-sending a long prompt
meant finding and copying it from the transcript.

`composer_history` follows Swift's `recallHistory`: Up in an empty composer
shows the newest prompt and walks toward the oldest; Down walks forward and ends
at the empty draft. It refuses whenever a recall does not apply, and the key
then keeps its native caret movement. The same guard list as Swift is used:

- A prompt walk starts only from an empty composer, and only while the text is
  still exactly the text that recall placed, so any edit ends the walk.
- Draft images or attached context block recall; so does a non-collapsed
  selection, or a caret that is not on the first (Up) or last (Down) line.
- The walk passes the oldest prompt without wrapping or clearing the text.
- Consecutive duplicates are recalled once, in the same order Swift uses.
- A conversation switch and every new prompt reset the walk.

Placement is not a native edit, so the draft is recorded through the same path a
typed change uses; otherwise a recalled prompt would not survive a thread
switch. Unit coverage: up/down walks, past-the-oldest consumption, empty
threads, and consecutive-duplicate skipping.
## Terminal find and tab cycling — 2026-11-10

SwiftTerm gives every terminal ⌘F find and the system's ⇧⌘[ / ⇧⌘] tab
cycling. Rust's native terminal had neither: ⌘F reached the app menu, where
Find is deliberately disabled in a terminal, and the only way between tabs was
clicking one.

- **⌘F** opens a find strip above the pane it belongs to, focused, matching the
  page already on screen. Matches are case-insensitive and reported in reading
  order; the strip shows the current match and the total, previous/next move
  between them with wrapping, and Return/⇧Return do the same from the field.
  Escape or Close dismisses it and returns focus to the shell. Each pane keeps
  its own query, as SwiftTerm's panel does, and the strip re-matches when the
  query or the visible page changes, so a busy shell never leaves a stale count
  or a highlight on the wrong cells.
- **⇧⌘[ / ⇧⌘]** move to the previous/next tab and stop at the ends, as the
  system's Show Previous/Next Tab does. The shell that loses focus keeps
  running and its pane keeps its layout.
- Find searches the visible page, not scrollback: core hands the UI one
  coherent page at a time and has no query for history.

Unit coverage (`cargo test -p coincide-desktop --bin coincide-rust
terminal_workspace::find`): trailing-blank trimming, wide-glyph columns,
case-insensitive matches with exact column bounds, every occurrence on a row,
empty and overlong queries, wrapping in both directions, and the match cap.

## Reply images — 2026-11-10

Swift's `TranscriptMedia` scans an assistant reply for media and draws a card
under it, so a reply whose whole answer is a screenshot shows the picture. Rust
drew the reply text only: `![shot](path)` stayed a link, and a generated image
listed in `attachments` kept the row visible but empty.

`transcript_media::images` now collects the local images a reply names — its
Markdown images, its image links, then its `attachments` — in the order it
mentions them, at most eight, one card per distinct file. Each card draws the
file at reply width with its name below, through the same image cache as the
Rust-ingested previews. Resolutions are cached per item and reply, because
resolving stats the file and rows redraw every frame; the cache clears when a
conversation opens.

Bounds, as Swift's loaders have them: only `png/jpg/jpeg/gif/webp/heic/avif/
bmp/tif/tiff`, only a regular file of at most 64 MiB, `file://`, `~/` and paths
relative to the thread's folder (a `..` that leaves the folder is refused), and
percent-escaped destinations decoded. Remote and `data:` URLs are never
collected: a reply is agent-written text, and fetching what it points at would
make the transcript a beacon.

Video, audio and interactive HTML still render as ordinary links: Rust has no
player yet, so they wait for that work rather than showing a frame that cannot
play.

Unit coverage (`cargo test -p coincide-desktop --bin coincide-rust
transcript_media::`): Markdown images and links in order, folder-relative
targets, attachments and de-duplication, missing files and other extensions,
remote/`data:` refusal, escaped spaces and `file://`, a titled destination, the
eight-image cap, and the `..` boundary.

## Reasoning effort for every provider, kept across launches — 2026-11-10

The composer's effort chip said "Reasoning effort is not connected for this
provider" for anything that was not Codex, even when the provider's own
discovered model list advertised effort levels: OpenCode reports low/high/max
for `deepseek-v4.1-flash`, and Swift lists exactly those. The capability was
also only offered when a model catalog job happened to be in memory, so after a
relaunch — or any restart — the menu fell back to "not connected" until someone
refreshed models by hand.

- Every provider now offers the efforts its own discovered list reported. Codex
  keeps its separate proof path, which binds effort and speed to a model list it
  read from the exact executable and account.
- The latest ready list per provider is saved as `model-catalog.json` and
  restored at launch, so a conversation opens with the menu it had before
  instead of waiting for a provider process to run again. A live refresh
  replaces the saved list as soon as it lands, and saving only happens when the
  catalog actually changed.
- A restored list is display metadata only: it carries no binding, no proof and
  `authenticationChecked: false`, so nothing can be sent on the strength of it.
  Codex lists are never restored at all, because their restore is proof-bound.

Unit coverage (`cargo test -p coincide-core --lib saved_catalog`): a saved list
answers effort choices without a live refresh, is written back unchanged, never
replaces a live catalog, and ignores unknown providers and empty lists. The
portable provider-resume test still passes.

## Quiet composer failures and a transcript that stays where you left it — 2026-11-10

Three lines the user never asked to read, and one scroll rule:

- The "A draft could not be saved yet. Keep this window open." bar above the
  transcript is gone. Saving still retries in the background, and quitting with
  an unsaved draft still stops and offers Retry save — the difference is that a
  transient save no longer paints a permanent warning into the conversation.
- A failed `agent.pending` poll no longer writes "Unable to load agent requests:
  App is busy processing another operation…" under the composer. A busy engine
  is a retry, not news.
- Scrolling no longer gets pulled back to the newest reply. gpui moves a list's
  scroll anchor to the start of any range that is spliced, and the live reply is
  spliced on every update, so a reader who had scrolled away was dragged along
  with it. Every transcript splice now captures the reader's position first and
  restores it when they are away from the tail; someone still at the bottom
  keeps following the newest reply, with the Jump to Latest pill appearing only
  once they leave.

Unit coverage: `transcript_scroll_tests` (the tail is followed only from the
tail, including the sub-pixel rounding case).

## No running chatter under the composer — 2026-11-10

The line under the composer narrated the turn: "Agent running · approval
required for changes" on send, "Agent turn ended." when it settled, and a blank
row with its own top margin whenever it had nothing to say. The turn header in
the transcript already says how long the agent has been working, so this was
repeated noise plus padding.

The routine messages are no longer written, and the row is only built when the
status has something to report, so a normal turn leaves no empty strip under the
composer. Status text that reports a failure the user can act on still appears
there.

## Composer attachments and controls during a turn — 2026-11-10

- Attached images now read as a strip, as Swift's composer shows them: a row of
  76 pt rounded thumbnails that wrap, each with its file name underneath and a
  small ✕ over its corner. The "2 image(s) attached" heading and the per-row
  "Remove" buttons are gone, so the draft keeps the space and the remove control
  sits on the picture it removes.
- A running turn no longer disables the composer's selection controls. Swift
  keeps the model, effort, speed, access and mode controls enabled whenever a
  conversation is open; a change made during a turn belongs to the next one.
  Rust refused every change while running ("Selection is locked while this
  conversation is running"), including from slash commands. Running is no longer
  treated as a lock: changes are staged in the selection draft and applied as
  soon as the turn ends. A provider switch still waits for the turn, which is
  the provider's own rule, and real locks (bots, imports) still refuse.
- A failed conversation-list poll no longer writes "Unable to load
  conversations…" under the composer; a busy engine is a retry.

Unit coverage: `cargo test -p coincide-desktop --bin coincide-rust
composer_selection` (68 tests) now pins the new contract — a running turn stages
a model, speed or mode change instead of refusing it, a genuine lock still
locks, and provider switches still wait.

## Message media at Swift's densities — 2026-11-10

A user's attached images were drawn at 240 × 180 with their file name under
each, which is not what Swift's cell shows: its attachments are a grid of small
104 × 78 thumbnails, and only a generated image on an assistant reply is a
large card. Rust now uses the same split — thumbnails for what the user sent,
a labelled card at reply width for what the agent produced — from the one
preview path both already shared.

## Clickable tool rows and a popover that switches facets — 2026-11-10

- A tool or reasoning row ("Run command", "Thought") only toggled from its title
  text or its chevron; the rest of the row looked clickable and did nothing. The
  whole header now toggles, with the chevron as an indicator rather than a
  second target, and the row keeps the "Expand"/"Collapse" role and label.
- The composer's popover dismiss layer covered the whole window, so the first
  click on another chip only closed the open popover: changing from the model
  chip to effort took two clicks. The dismiss layer now stops above the
  composer, so a chip click reaches the chip and switches facet in one click.
  The card itself keeps its anchor, because it is still positioned inside the
  full-size layer.

## A tool detail that scrolls itself — 2026-11-10

An expanded tool panel caps its height and clips what does not fit, so the
overflow needs its own scroll position. It had none: the panel was a clipped
box with `overflow_y_scroll` but no tracked handle, so a wheel over it moved the
transcript underneath instead and long command output could not be read at all.
Each expanded detail now keeps a `ScrollHandle` (cleared when a conversation
opens), so the wheel over the panel scrolls the panel and the transcript keeps
its place.

Nested scrolling now chains explicitly: while the panel can still move in the
wheel's direction it takes the event alone and the transcript stays put; at the
panel's top or bottom the event passes through, so the conversation keeps
scrolling where the reader expects.

## Sending feels instant and lands at the bottom — 2026-11-10

Two things made sending feel wrong. The draft stayed in the composer until the
engine had accepted the turn, so a short sentence sat there for about a second;
it now leaves the field immediately, and a refused send puts it back with the
error. And the new message could open somewhere above the newest row, because
the row splice restored the previous scroll offset; a send now follows the tail,
since the message the user just wrote is the newest thing in the conversation.

## Opening conversations while the engine is busy; a silent composer — 2026-11-10

- Switching conversations could fail outright with "Unable to open conversation:
  App is busy processing another operation". A busy engine is transient, so the
  target is now remembered and taken on the next tick instead of failing; the
  sidebar selection follows once the read succeeds. Nothing about opening a
  conversation should depend on a turn finishing.
- The composer's status row is gone entirely. It had already lost the routine
  running and turn-ended lines; what remained was transient noise such as a
  draft save that hit a busy engine, which now retries silently instead.
- A follow-up sent while a turn runs leaves the composer immediately, like a
  normal send, and only comes back if the engine actually withholds it (and
  never over text typed since).
