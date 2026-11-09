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
