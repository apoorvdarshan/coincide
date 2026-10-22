# Coincide

A native Swift macOS coding app, with [T3 Code](https://github.com/pingdotgg/t3code)
as the functionality reference and the ChatGPT macOS app as the interface reference.

## Status

In development. Full T3 Code feature parity is **not complete**. See
[porting status](docs/PORTING.md) for implemented behavior, gaps, and verification.

Liquid Glass is the default for custom native chrome on macOS 26+, alongside
system sidebars, toolbars, menus and sheets. Older macOS versions use native
materials, and Reduce Transparency uses opaque surfaces. The complete
[provider integration inventory](docs/PROVIDER_PARITY.md) tracks what is working
and what still needs implementation and verification.

## Build and run

Requires macOS 14+, a Swift 6.2+ toolchain, and Xcode Command Line Tools. Codex
conversations require an installed, authenticated `codex` CLI; Claude conversations
use the installed, authenticated `claude` CLI.
Native OpenCode conversations use the matching installed OpenCode 1 or 2 CLI
through separate HTTP adapters. Choose **Server Generation** before the first
message. Both adapters have offline-fixture verification; installed conversation
verification and complete OpenCode parity remain unfinished.
ACP v1 agents can use other installed CLIs, such as `opencode acp`.

```sh
./script/build_and_run.sh
```

The script uses an existing Apple Development signing identity when available,
so macOS can retain file-access consent across local rebuilds. Set
`COINCIDE_SIGN_IDENTITY=-` to use ad-hoc signing, or set it to a specific identity.
CI uses ad-hoc signing. Local signing does not notarize or publish the app.

Add a project folder, start a thread, and send a message. Coincide connects directly
to the selected provider's native CLI protocol. Each conversation owns its
provider connection; provider-specific account setup is described below.
Choose the provider in a new conversation's header. Review requested commands and file
changes in the conversation. Use the inspector to browse/edit files or inspect,
stage, and commit Git changes. The branch menu creates/switches local branches or
tracks fetched remote branches. Fetch, fast-forward Pull, and explicit single-branch
Push use your existing Git credentials. A folder without Git can initialize a
repository; staging and unstaging also work before its first commit. A new thread
can choose a Git worktree before its first message.

Use **Refresh Models** in the header menu to load Codex's advertised models and
reasoning options. Reasoning preferences are saved separately for each model;
**Model Default** clears that model's override. **CLI Default Model** reads the
current checkout's CLI configuration and captures its concrete default model,
keeping any saved reasoning preference for it. These choices apply to future
turns. Active and queued turns retain the settings they already captured.

For native OpenCode, **Refresh Models** reads the current workspace's models,
variants and primary agents. These choices apply to future inputs; queued turns
retain their captured model, variant, agent and permissions. Approval controls
distinguish once, conversation-only and workspace-wide grants. Direct steering
and native OpenCode history are still unfinished.

**Settings → Providers → Add Grok** saves its native ACP profile. Its composer
offers **Ask**, **Auto**, and **Always approve**; active and queued inputs retain
their captured launch policy. Questions submit exact selected choices and notes
together. The integration can use the CLI's existing sign-in, with offline
protocol verification so far; installed Grok execution remains unverified.

Pi conversations use an installed, authenticated Pi 0.80.5+ CLI over its native
RPC protocol. **Refresh Models** loads provider/model and advertised thinking
choices. Inputs retain their captured settings and tool approval policy; native
confirm, select, input and editor requests appear in the conversation. Existing
sessions resume from their native session files. Offline protocol checks pass;
installed Pi execution, steering, history mutation and usage remain unfinished.

Muse conversations use the installed CLI's native MSP protocol. Select a model
and reasoning level after refreshing its catalog. Ask and Always approve require
the host to confirm the matching permission profile before any prompt is sent;
older hosts without that proof are unsupported. Scoped approvals and questions
retain the native choices, rule previews and written notes. Offline protocol and
Engine checks cover queueing and exact-turn Stop; installed Muse execution,
steering, broader recovery, setup/auth and usage remain unfinished.

Antigravity uses its paired `agy_acp_server.par` and `localharness_external`
runtime. In **Settings → Providers → Antigravity**, choose the pair and explicitly
check account access with Google account, Gemini Enterprise, Gemini API key or
Agent Platform. Google sign-in opens only when you choose its button. API keys
stay in Keychain; account changes pause affected conversations and keep queued
inputs for review. Models and native permission choices apply to future inputs.
The initial integration uses offline peers for verification; managed installation,
usage, broader recovery and installed account/model execution remain unfinished.

**Settings → Providers → Codex Account** reads the existing CLI sign-in, plan,
and available allowance windows. Email stays hidden until revealed. Refresh
checks account identity before and after reading usage; switching accounts clears
old allowance bars, while failed usage checks mark retained information as stale.
Account observations stay in memory. Percentages and reset times never grant
permission to send, and the account panel does not change the CLI sign-in.

While a turn runs, Return queues the next message by default. Command-Return uses
the alternate **Steer** action when the live provider supports it. The delivery
menu offers both actions, and Settings changes which one is the default. Steer
sends to the current run with its captured model and permissions. Codex uses the
reviewed 0.163.x native active-turn contract; Claude can interrupt its current
tools, and steering is unavailable while foreground agents retain ownership. A queued
message also has a Steer action when its captured settings match the active run.

If delivery is unconfirmed, the input stays in the conversation and is not
automatically repeated. **Continue Without Repeating** releases the delivery
hold; a paused queue still needs **Resume Queue**. Direct steering does not
change the running model or implement an interrupt-and-restart workflow.

Save or discard file edits and close that conversation's terminal tabs in every
window before changing its checkout. Running commands remain open until you close them.
Choose **Choose Worktree…** from the conversation's workspace menu. Create a new
branch from a locally available base ref/commit, check out an existing branch,
or explicitly use a registered branch worktree from the same repository. Messages wait
while setup runs and retain their chosen provider, model, permissions, and
attachments. Cancel and application restart pause the queue. Retry first checks
saved completion evidence; unproven folders and branches are preserved. To change
a failed setup, remove queued messages and choose another worktree. Coincide
does not reset branches, delete worktrees, or fetch a missing base automatically.

For a new checkout, choose **None** (the default), **Top level**, or **Recursive**
submodule initialization. Initialization may download repositories through your
Git configuration; queued messages wait for the selected step to finish. A normal
initialization failure leaves a usable checkout with a visible warning. Cancellation
keeps the queue paused. Registered-worktree reuse preserves its existing submodules.

**Review checkout setup script** is enabled when choosing a worktree. For a separate
checkout, Coincide finds the first `runOnWorktreeCreate` script in its `t3.json`, then
waits for you to review its exact command and choose **Run Setup** or **Continue
Without Setup**. Files and Terminal remain available during review. Blocking
scripts release queued messages only after exit status 0; asynchronous scripts
release them once startup is confirmed. Output and exit status appear in the
conversation. **Stop Setup**, **Stop Background Jobs**, and **Review Again** manage
the app-owned job across windows. Retry requires a fresh review; interrupted jobs
never run automatically after restart. Turn off the checkbox to skip discovery.

Use **Run Script…** in the toolbar to choose a script declared in the current
checkout's `t3.json`. Review its command and checkout, then run it in a dedicated
native terminal tab. Scripts receive `T3CODE_PROJECT_ROOT` and, for a separate
checkout, `T3CODE_WORKTREE_PATH`. Changing the configuration requires reloading
the list. This manual action can run any declared script. Preview flags do not
yet trigger their own workflows. Output and exit status stay in the terminal, and
closing a running script asks before stopping it.

Choose **Settle Conversation…** from the workspace menu, conversation context
menu, or Thread menu when the conversation is idle and its queue is empty.
Managed setup jobs stop before settle-script discovery; existing terminal tabs
stay open. The confirmation offers **Review settle script** by default. In a proven
separate worktree, Coincide finds the first `runOnSettle` role and waits for exact
command review before execution. The conversation stays settled after script exit.
Choose **Resume**, or send a new message, to stop its owned settle jobs and
continue. Captured messages wait for cleanup, and unsent drafts stay available.
Each new settlement requires a fresh review; interrupted scripts never replay
after restart. Resume before changing the conversation's checkout.

Choose **Run History…** from the conversation's workspace menu to inspect
recorded turns, their captured provider/model/permissions and workspace, and
their observed outcomes. History survives restart and retains adapter session
and turn references. Agent-initiated work is labeled separately. Older messages
remain available without invented turn boundaries.

For verified runs in new paginated Codex conversations using the reviewed
0.163.x app-server profile, the run's **Conversation** menu offers **Fork After
This Run…** and **Rewind Before This Run…**. Review the selected input, exact
boundary, settings and checkout before confirming. Fork creates a separate
conversation through the selected completed run, using that run's captured
settings; the source conversation and draft stay unchanged. Rewind removes the
selected run and later messages from the current conversation while retaining
their run audit. Its current draft, provider, model, permissions and agent options
stay unchanged. **Recall Prompt** explicitly appends the original input and
attachments to the latest draft once, rather than replacing existing edits.

Both actions leave workspace files and staging unchanged. While a history change
is pending, provider work and configuration changes wait; drafting, pinning and
conversation selection remain available. An unconfirmed rewind stays paused for
**Inspect Provider State**, which reads the outcome without repeating the action.
Lost acknowledgments and restart never automatically replay a history mutation.
Claude, ACP and older histories without verified boundaries do not offer these
conversation actions.

**Save Run Checkpoints** in the workspace menu is enabled for future messages by
default. Each accepted message keeps its captured setting. Coincide attempts a
workspace snapshot before starting the provider, then saves another after a
completed or interrupted run before advancing queued messages. A missing or
failed before-run snapshot is visible and does not prevent provider work. A
failed after-run snapshot holds the queue for **Retry Current Workspace** or
**Continue Without Snapshot**. Retry records a later observation; it does not
repeat the provider's work or recreate the earlier filesystem state.

Run History shows checkpoint status and **Workspace Changes…** when both
observations are available. Changes can include your edits and other tools'
work. Capturing leaves HEAD, branches, staging and checkout files unchanged.
Temporary indexes and private Git staging files are removed only when they still
match their saved ownership proof; snapshot refs, plans and receipts are retained.
Restart inspects saved completion evidence without replaying captures or provider
work, and keeps queues paused. Unused Git filter settings, including global Git
LFS setup, do not block snapshots. Files requiring executable clean/process filters
and non-cone sparse layouts are currently unsupported.

Ready observations offer **Restore Files…** in an isolated conversation worktree,
including a retained earlier after-run observation. Review the affected paths and
changes before confirming. Restoration replaces the workspace with that exact
observation, removes new nonignored files, and clears staging against the current
HEAD. Ignored files and nested repositories are preserved according to Git's
restore/clean rules; HEAD and branches do not move. Your current draft, settings
and conversation history remain. This file action is available independently of
the provider. Codex rewinds also offer **Revert and Keep Changes** or
**Revert Files Too…**. The latter reviews the previous visible run's saved
after-run files, or the original first run's pre-provider baseline. It requires
the same isolated-worktree checks. After all requested stages succeed, the
original prompt and attachments append to your latest draft without sending it.
Provider history changes first; a later file failure is shown as a partial
result and keeps work paused for inspection or explicit **Keep Current Files…**.
Neither stage is automatically repeated after interruption.

Other conversations sharing the checkout, active work, unsaved editors and open
workspace terminals prevent restoration. Coincide drains its owned provider
connections before writing and refreshes clean editors afterward. Restart never
repeats a restore: uncertain outcomes hold workspace writes for read-only
**Inspect Restore State** or explicit **Keep Current Files…**. Original displaced
bytes remain in private recovery storage after a started restore. Canceling an
unused review removes only its verified temporary data. Current review limits
are 100,000 filesystem entries and 512 MiB of regular-file bytes, including
ignored files; executable checkout filters and unsupported layouts are rejected.

The **Changes** inspector also opens a native **Pull Requests…** browser for
GitHub repositories. It uses your installed `gh` CLI and existing sign-in. Search
open, closed or merged requests, inspect their description/checks, or review a new
request's repository, published head, exact base, title, body and draft state.
Push the branch through the existing Git controls first. An existing open request
is reused. Creation is saved before its single dispatch; reopening the app never
resends it. An uncertain result holds the checkout for **Inspect Creation State**
or explicit acknowledgment.

Choose **Open in Conversation…** in a PR's detail to review a local checkout or
separate worktree, the exact requested commit and destination, and the new
conversation's captured agent settings. Separate worktrees are the default.
Local checkout requires no tracked edits. Existing registered worktrees retain
local commits and changes; an off-head result shows the actual branch and commit
with a warning in both the result and the new conversation. Only a clean,
provably lossless update advances an existing checkout; a proven rewritten remote
head also retains the earlier commit in a private recovery ref.

Separate worktrees allow provider turns, queues, unsaved editors and terminals
in the source checkout to continue. Multiple different PR destinations can prepare
in the background; their individual progress and recovery controls remain available
in the PR browser. Git mutations sharing a repository serialize. Local checkout
requires finishing active work, saving editor changes and closing terminals in
every window using its files. Closed tabs and windows retain ownership until their
processes and output have drained.

A busy registered worktree opens through a separately reviewed read-only inspection.
It does not fetch, reset, alter tracking, initialize submodules or run setup; its
provider, terminal and unsaved editor work continues. The conversation records the
actual observed HEAD and shows when it differs from the requested PR commit. If a
checkout becomes busy after a refresh review, review again before accepting it.
A confirmed checkout creates an empty conversation, preserves the source history
and latest draft, and sends no prompt. New or moved worktrees can discover a setup
script for explicit review. An unchanged reused worktree does not rerun setup.
Stop and restart never repeat the checkout. An uncertain write holds only the affected checkout for
**Inspect Checkout State** or **Keep Current Files…**; acknowledging an unknown
result creates no conversation. Failed/interrupted read-only inspections leave no
write hold. Clean editors and source control in the affected checkout refresh afterward.

Other PR hosts, automatic content generation, combined commit/push/create,
reviews and stacks remain pending.

The inspector's **Files** tab lists hidden files and empty folders, labels ignored
entries, and searches workspace paths using Git ignore rules. Open or create a
UTF-8 file, edit it, and save. Files over 1 MiB open as read-only previews. Binary
and invalid UTF-8 files are rejected. External updates refresh clean buffers;
unsaved edits stay in memory until saved or explicitly discarded. Hiding the
inspector or changing conversations retains them, and quitting asks before
discarding unsaved files. Save checks the original file revision before replacing
it; concurrent external writers can still race the final check, so this is not
cross-process locking.

Switch file search to **Contents** to search text across the workspace. **Aa**,
**Word**, and `.*` control case, whole words, and regular expressions. Results
show matching lines and highlight occurrences; choosing one opens its file at
the match. Partial results and unsupported expressions are shown explicitly.

Use **Open With…** on workspace files or search results, the editor's external-app
button, or a checkout's menu to open saved files in an installed editor. General
settings keep the preferred editor. Automatic chooses an inspected installed
editor, then the default macOS application when none is available. **Reveal in
Finder** is available separately. File links still open inside Coincide; external
actions retain unsaved native buffers and open the version on disk. Supported
editors receive a selected result's line; Unicode column conversion is not claimed.

Use **@** beside the composer to search for a workspace file or folder and insert
a relative link into that conversation's draft. References do not copy file
contents or attach files automatically.

Use **File → New Project** (⇧⌘N), or the sidebar's project menu, to create a
project in `~/Library/Application Support/Coincide/Projects/`. Coincide makes a
new folder, initializes Git using your configured default branch (or `main`),
adds a starter README and icon, and opens its first conversation. Existing names
receive a numeric suffix. If Git cannot make the initial commit, the project
stays ready and a notice explains how to commit its staged starter files.

Choose **Clone Repository** from the sidebar's project menu or **File → Clone
Repository** (⇧⌘O). Choose a new destination folder and keep writing while Git
downloads in the background. Submitted messages wait for the checkout, then run
in order. Progress, stalls, cancellation, and Retry appear in the conversation.
Cancelling or restarting holds queued messages for **Resume Queue**. Retry uses a
fresh staging folder and preserves earlier attempts; it does not resume a partial
network transfer. Existing destination folders are never overwritten. Git uses
your existing credentials and SSH setup without opening an interactive prompt.

In **Settings → Providers → ACP Agents**, save an agent name, executable, and
arguments (one per line), then choose it in a new conversation's header.
Arguments are passed literally. Model discovery supports the agent's config
options and older model lists; mode and other select options appear after session
setup. Permission buttons preserve the choices the agent supplies. ACP agents
enforce their own sandbox and use their own sign-in. Editing or removing a saved
agent leaves existing conversations' saved invocations intact. **Use ACP v2
(experimental)** enables the current v2 draft with v1 fallback on the same
connection. V2 supports typed configuration, user-message identity, foreground
state updates, and independent background permissions/results. Rejected or
unconfirmed submissions remain visible and are never automatically resent.
Managed registry installs, client-side filesystem/terminal delegation, and native
agent authentication flows are still pending.

**Add Cursor** and **Add Copilot** save explicit vendor profiles using `agent acp`
and `copilot --acp --stdio`. **Check Connection** reads initialization on its own
temporary connection; it does not sign in, start a conversation, or prove model
access. Existing CLI credentials remain with the CLI. Cursor questions support
single and multiple selections by option ID, plus Skip. Plans require explicit
Accept or Decline; todo, task and image notifications appear as activity without
running client tools or opening provider-supplied image paths. Copilot's raw-event
bridge keeps child output and background completion attached to the original
run. These extensions also work with the experimental v2 adapter and its v1
fallback. Full SDK equivalence, native authentication, usage and all-provider
parity remain unfinished; see [provider evidence](docs/PROVIDER_PARITY.md).

Send another message during a turn to queue it. Each queued message keeps its
chosen model and permissions, and can be edited or removed before it starts.
**Stop** interrupts the current turn and holds the queue. Use **Resume Queue** to
continue; restarting the app also holds unfinished work rather than resending it.

Click a project heading to collapse or expand it; its selected conversation stays
visible. Checkouts with the same Git repository appear together by default.
The sidebar menu and General settings offer **Repository**, **Repository and
Folder**, and **Separate Checkouts**, with individual overrides in each checkout's
context menu. Local folders without a remote stay separate. Forks retain their
own identity even when an upstream remote is configured.

Grouped projects list each checkout's conversations and offer explicit paths for
new threads, renaming, removal, and revealing files. The **New conversations**
picker chooses the checkout for future conversations; existing conversations
keep their workspace, draft, and agent. The last selected conversation reopens
when Coincide restarts.

Use **Rename Group…** to rename all checkouts together. **Remove Group…** shows
every checkout path and removes the whole group's active and archived
conversations in one operation. Cancel leaves the group unchanged.

Right-click a single project heading to rename it while keeping its folder path.
The sidebar sort menu offers **Last user message** (including queued
messages), **Created at** (the newest conversation in each project), and **Manual**.
Activity includes all conversations in a group. Manual mode supports dragging
groups and Move Up/Down controls, preserving other checkouts' relative order.
Switching sort or grouping modes preserves your saved manual order. Archived
conversations do not determine project activity or creation ranking.

Right-click a project heading and choose **Remove Project** to remove its active
and archived conversations from the workspace and stop their agents, clone, and
terminals in every open window. To remove only one checkout from a group, choose
its physical path under **Checkouts**; sibling checkouts stay open. The
confirmation includes the checkout paths and any unsaved file edits.
Coincide does not delete checkout, worktree, staging, or attachment files. Git may
clean up unfinished files when an active clone is stopped. Conversation data
remains in local recovery history; removal is not secure
erasure. If new conversations or unsaved editors appear during confirmation,
review the removal again.

Use **+** in the composer to attach files, or paste/drop local files and images.
Attachments stay with drafts, queued turns, and sent messages across restarts.
Image previews include copy, save, and open controls. Codex and Claude receive
supported images directly and other files as paths to private local copies.
The limit is 100 files per message, 10 MiB per normalized image and 80 MiB of
images per message, or 50 MiB per other file. HEIC, TIFF, and oversized images
are converted or resized natively; original files are preserved.

Responses render native Markdown headings, lists, task lists, quotes, tables, and
code blocks with copy controls and basic syntax coloring. Workspace file links
open the native editor at the referenced line. Web links use the default browser;
embedded HTML stays inert. Closed display equations on their own lines (`$$` or
`\[` delimiters) and fenced `math` blocks render through native CoreText, with
LaTeX copying and readable source fallback. Inline equations and media previews
are pending.

Open **Terminal** in the toolbar (⌥⌘T) for a native terminal in the conversation's
workspace. Create multiple tabs, resize the panel, or hide it while commands keep
running. Terminals stay attached to their conversation while the window is open;
closing a tab or quitting the app ends its local processes.

The app uses SwiftUI/AppKit and a Swift core; it does not launch Electron or a T3
Code server. Workspace data stays in `~/Library/Application Support/Coincide/`.
Worktree folders are preserved when conversations are archived.

## Tests

```sh
swift test --no-parallel
```

Tests cover process streaming/failure/cancellation, protocol framing and request
correlation, deterministic Codex and Claude approval conversations, journal replay,
ACP streaming/permissions/images/config options/resume and native agent settings,
atomic commit failures, accepted/rejected command deduplication, queued execution,
approval responsiveness, Stop, stale provider events, lease loss, migration/restart,
attachment import/integrity/conversion, native paste cancellation,
file conflicts/path containment, and real local Git/remotes, branch tracking,
divergence, conflicts, hooks, cancellation, background cloning, queue gating,
clone retry/recovery, and worktree operations. See the porting
document for live checks and their limitations.

The native macOS GUI CI job tests an isolated app copy through real windows,
menus, and keyboard input. Its harness and result requirements are documented in
[desktop UI tests](UITests/macOS/README.md).

The terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with its
[MIT notice](docs/SwiftTerm-LICENSE.txt) bundled in the development app.
Markdown parsing uses [Swift Markdown](https://github.com/swiftlang/swift-markdown)
and [Swift cmark](https://github.com/swiftlang/swift-cmark); their licenses and
notices are also bundled.
Native equations use [SwiftMath](https://github.com/mgriebling/SwiftMath), with its
[MIT license](docs/SwiftMath-LICENSE.txt) and original font notices bundled.

T3 Code is copyright © 2026 T3 Tools Inc.; its [MIT license](docs/T3-CODE-LICENSE.txt)
is preserved here. Coincide is an independent project.
