# Remote environments

Coincide has native macOS remote workspaces: a Swift host, an SSH
stdio client and a separate **Remote → Remote Workspaces…** window. It supports
saved connections, environment identity confirmation, existing remote projects,
Codex/Claude conversations, streamed snapshots, questions/approvals, queued input
and exact-run Stop. The Files/Changes inspector adds remote text editing and
source control. A separate terminal panel opens and controls host PTYs without
starting a local shell. Blank conversations can prepare or reuse remote Git
worktrees. Full T3 remote parity remains unfinished.

The client owns the SSH process and the host it launches. **Disconnecting,
closing the remote window or quitting stops that host's active work.** Saved
conversations remain in its SQLite database; uncertain or interrupted work is
not automatically repeated. This version is not a persistent remote daemon.

## Setup and behavior

1. Build Coincide on the remote Mac. The package produces `CoincideEnvironment`;
   app packaging also includes it at
   `Coincide.app/Contents/Helpers/CoincideEnvironment`. Select an absolute path to
   that preinstalled helper. Automatic installation/update is not implemented.
2. Install and sign into Codex or Claude on that Mac using their existing CLI
   setup. The host captures that remote executable and home for new threads.
   Local accounts, API keys and provider configuration are not transferred.
3. Configure SSH access and verify its host key yourself in Terminal. Coincide
   invokes `/usr/bin/ssh` with batch mode, strict host-key checking, no TTY,
   no forwarding and no local command. It cannot prompt for a password or accept
   a new host key. Saved SSH aliases and key-based access work with this route;
   a literal IPv6 destination is not yet accepted by the connection form.
4. Choose **Add SSH Connection…**, enter its target and optional port, the helper
   path and an absolute private data directory on the remote Mac. Inspect the
   descriptor, then explicitly confirm its environment UUID. Future connections
   must return that identity. Discovery does not open the workspace database or
   start a provider, although it creates/reads the private environment identity.
5. Add an existing remote folder and create a Codex or Claude conversation. Paths
   displayed in this window belong to that machine. Remote file links are not
   resolved against this Mac, and remote state never enters the local workspace
   store. New conversations offer Automatic or Disabled run checkpoints. Older
   helpers and callers that omit the policy keep checkpoints disabled; changing
   the setting affects future accepted runs and preserves captured run policies.

Connection metadata, per-environment drafts and unconfirmed requests are stored
in private files under the local app's `RemoteEnvironments` directory. Each
command's UUID and full payload are saved before transmission. If a reply is
lost, **Check Result** asks for its durable receipt; it never resends the command.
A missing receipt leaves the request unresolved. **Dismiss Unconfirmed Request**
retains a private local record and requires explicit confirmation. Check the
remote conversation before deciding to send any new input.

Drafts remain editable while disconnected. An acknowledged submit clears only
the unchanged text it sent, preserving newer typing. Quit drains pending draft
writes and asks before discarding text if saving fails. Remote file buffers and
commit drafts survive inspector hiding, conversation changes and disconnects in
the running app; Quit asks before discarding them. Unsaved editor/commit buffers
are not crash-persisted.

## Conversation lifecycle and automatic settlement

Updated helpers advertise `supportsWorkspaceLifecycleControls`. The remote
window exposes Snooze/Wake, per-conversation automatic-settlement opt-out,
explicit Resume and **Remote Automatic Settlement…** for that environment's
inactivity/terminal-PR policy. Policy Apply compares the reviewed policy and
refuses stale changes from another window. Snooze and Wake change attention
only; they never send input, resume a queue or run a script. Explicit Resume
releases a settlement generation after its managed jobs drain and can then run
authored queued messages.

**Settle without Cleanup Script…** is an explicit opt-out from cleanup-script
review and execution. It retains history, drafts, files and terminal tabs.
Updated helpers separately advertise `supportsReviewedSettleScripts` for the
normal reviewed cleanup workflow below. Older lifecycle-only helpers continue to
offer the explicit skip choice without claiming script execution support.

The helper initially keeps automatic sweeps disabled. A compatible client first
negotiates lifecycle controls on its snapshot/subscription or projection-open
request; only then can that owned helper enable the native sweep service.
Older clients and omitted negotiation keep sweeps disabled, so an older client
cannot gain an automatically settled conversation without reachable Resume UI.
Negotiation is positive-only within one owned helper lifetime: a later omitted
or false flag does not revoke an earlier successful compatible-client handshake.
Closing that helper resets activation; a reconnect negotiates again.
Automatic settlement follows the host's current policy and native busy/ownership
guards, retains history and never runs setup, cleanup scripts or input. The
service stops and drains with the owned stdio host; it is not a persistent daemon.

Explicit actions carry opaque host-held capture claims and retain the original
command UUID and exact payload before transmission. The host rechecks current
conversation/project incarnations, configuration and lifecycle state; physical
settle/resume actions also require the bound remote root and current admission.
Metadata Wake remains available independently of a missing checkout. A lost
reply uses the existing Check Result receipt workflow and never resends the
action. Fresh control metadata can update while an older transcript view stays
pinned. Installed-provider, live SSH and hosted native interaction acceptance for
these controls remain unverified.

### Reviewed remote cleanup scripts

**Settle… → Settle and Review Script** requests native cleanup discovery. It
never approves execution. The native rules select the declared settle role only
for a ready, separate conversation worktree; a shared checkout does not gain a
cleanup command. **Review Settle Script…** loads the full name and command from
the captured `t3.json` before enabling **Run Settle Script**. The review also shows the
remote shell, working directory, project root and background behavior.

The helper retains the complete native plan and private conversation/project
incarnations. The client sends only an opaque claim, digest and exact generation
and run IDs. Commands larger than the 8 KiB preview use immutable content pages
of at most 128 KiB, with a 256 KiB response bound; full UTF-8 and digest checks
precede approval. File revisions, shell/workspace identities and current scope
are checked again by native execution. The client cannot supply an executable,
environment or replacement native plan.

Approval and Retry exclude conflicting file/Git/terminal work. The managed job
continues to hold its workspace, project root and Git coordination scope while
its command or managed descendants remain alive, including after the command's
parent exits. **Stop Settle Script**, **Stop Background Jobs**, **Skip Settle
Script** and explicit Resume retain their original command receipt and join the
exact native drain outside the short host admission lane. Stop/Skip and output
remain available when the checkout disappears; Approve/Retry require its bound
physical root. Manual terminal tabs are not closed automatically.

Output is read only after its disclosure opens. It uses bounded complete text
replacements from the native 64 KiB/500-line tail, with monotonic sequence,
truncation and closed markers. The UI distinguishes not started, retained and
not retained. An owned helper restart interrupts the old attempt, invalidates
its host-bound claims/output references and never replays approval. Historical
output is not persisted across helpers; Retry requires a newly discovered,
reviewed command. Closing a presentation cancels and joins reads/polls while
accepted commands remain owned by the environment's pending journal.

The environment binary also serves as its own managed script helper using the
existing native helper protocol and process-group cleanup. No extra executable
needs provisioning. Remote setup-script and arbitrary project-script controls,
persistent hosts and installed/live SSH acceptance remain separate parity work.
See VALIDATION.md for the exact local and hosted checks performed.

## Remote run checkpoints

The remote conversation header controls automatic checkpoints for future runs.
**Remote Checkpoints…** shows saved baseline and post-run observations, including
older post-run attempts. Refresh explicitly obtains host-derived restore
eligibility; a remote path is never checked against this Mac's filesystem.
A failed or interrupted post-run capture holds the queue. **Retry Current
Workspace** records a later observation; **Continue Without Snapshot** explicitly
releases the held run without inventing a successful checkpoint. Both decisions
bind the exact run and attempt and can release queued provider work.

A run diff binds its exact baseline and current post-run observation and returns
a bounded patch. File restoration requires an isolated conversation worktree,
a ready observation and the native ownership checks. First review the current
manifest and preview, then explicitly choose **Restore Files**. The sealed full
manifest stays on the host; the command carries only its review ID and digest.
Restoration can replace/delete tracked and nonignored files and update staging;
branch/HEAD, ignored files, conversation history and drafts retain the native
restoration guarantees. Shared checkouts and conflicting work are refused.
Remote editor changes and live PTYs are checked again before admission.

Accepted restoration and its original command receipt commit together. A lost
reply is resolved using that exact UUID; no restoration is automatically
repeated. An unconfirmed restoration offers inspect-only recovery or explicit
**Keep Current Files**. The latter is a metadata acknowledgement and remains
available when the original folder is missing. Unused reviews release their
owned scratch; accepted or uncertain recovery evidence is preserved. Reviews
expire when the owned helper restarts. Old runs with no checkpoint receipt do
not acquire file restoration support retroactively.

This exposes existing native run-checkpoint workflows remotely. Checkpoint range
diffs and portable history/merge-back remain unfinished. Offline peers and local
Git fixtures do not establish real SSH, installed-provider or remote sign-in
acceptance.

## Remote conversation history

Updated helpers advertise `supportsRemoteHistory`. The recorded-run sheet offers
**Fork After Run** and **Rewind Before Run** for exact native boundaries. Review
creation reads the native provider and does not perform the history mutation.
The review shows retained/removed counts, a paged immutable transcript prefix,
the target settings and provider-specific boundary behavior. Fork opens the
reserved resulting conversation after the host confirms it. Rewind offers
**Keep Changes** and a separately reviewed **Restore Files** choice when a
verified isolated checkpoint is available. Combined rewind retains the provider
outcome separately from the subsequent file stage.

Only opaque review identities/digests authorize an accepted command. Complete
Codex/Claude/OpenCode/Pi evidence, native inventories and restore manifests stay
on the host. A separate history lease pins display pages and content; those
values never become native proofs. Responses retain the 256 KiB envelope budget,
128 KiB exact byte chunks, immutable cursor positions and SHA-256 verification.
History leases and their prepared native evidence have an independent eight-
lease/128 MiB limit; explicit release, eviction and host restart invalidate them.
The UI retains 512 message/path rows and a 1 MiB text display window, with clear
loaded ranges. Complete typed action documents have the same explicit 32 MiB
client hydration limit as other remote controls.

Acceptance and its original remote command receipt commit atomically through
the native Engine. Check Result after a lost reply only looks up that UUID and
payload; it never starts a second fork, rewind, file restore or provider input.
Discard/close release unused prepared scratch, while acceptance fences preserve
accepted and uncertain recovery evidence until the native workflow resolves it.
File restoration rechecks remote jobs/PTys and this Mac's retained remote editor
buffers and terminal tabs before admission.

Recovery controls preserve each provider's actual behavior: inspect an uncertain
provider result; inspect or explicitly keep current files; inspect a reserved
Claude fork or a terminal run that consumed saved context; verify and keep an
OpenCode v1/Pi original; review and clear the exact OpenCode v2 maintenance state;
and inspect a Pi fresh-session consumer. Pi history questions and cancellation
bind their exact worker/session/request; responding returns after its durable
marker so cancellation remains reachable while native I/O runs. There is no
generic provider-history acknowledgement or generic Codex/Claude cancellation.

Recalled input is merged into the latest private local text with a durable
merge-once marker, keyed to the original confirmed command and history operation,
before the pending command is cleared. A lost reply/restart cannot append it
twice. Later local text and imported attachments survive; original recalled
attachment references remain on the host. Oversized drafts, changed saved local
data or unavailable storage fail explicitly and retain the pending recovery.

Remote conversation creation still supports Codex and Claude. The closed
recovery adapter also handles existing host-owned OpenCode/Pi histories; that
does not add remote creation/authentication for those providers. Broader
checkpoint ranges and live two-Mac/provider acceptance remain separate gaps.

## Reviewed context transfers

Updated helpers advertise `supportsContextTransfers`. Fork and provider handoff
accept a latest-stable run with a ready after-run checkpoint, an explicit recorded
terminal run, or the exact current ready after-run checkpoint. The reviewed
source prefix stays fixed. Creation saves an intent and its original command
receipt without sending a provider turn. The next explicit target input owns
delivery; its authored text, attachments and the private local draft remain
separate from historical material.

Compatible verified Codex/Claude sources use their native fork primitives.
Other routes select whole archived items within a conservative byte budget,
preserve chronology, and record included and omitted item identities. Provider
handoff switches the provider on the same app conversation; returning to a saved
provider session adds a delta. Merge Back requires the actual parent lineage and
same project, and transfers child context rather than merging Git or files.
Cross-provider remote destinations use host-captured Codex/Claude profiles;
clients cannot supply executables, homes, credentials or native session IDs.
Imported opaque model selections can be retained or cleared; a display string
alone cannot select a different native OpenCode/Pi/Muse model remotely.

Full native proof and the immutable archive remain host-owned. Independent
eight-view/128 MiB leases expose bounded metadata, message pages and exact
128 KiB content chunks within a 256 KiB response envelope. Full target identity,
query-bound cursors and final SHA-256 verification apply. The provider context
reader is limited to archives captured by its exact active input; a remote
context-only MCP server exposes only that reader. Private reasoning, pending
approvals, native session internals and attachment bytes are not replayed or
available through it.

A lost outer reply is reconciled through the original command UUID. Unknown
delivery is retained as uncertain and blocks replay. Use Fresh Context requires
the exact saved delivery and transfer identities, preserves the audit and draft,
and permits a later explicit fresh input without resending the prior input or
historical material. Disconnect discards unused review display leases and resets
physical root bindings; it never repeats an accepted transfer or provider input.

## Bounded remote views

Updated helpers advertise `supportsBoundedProjections`. The remote window then
uses typed catalog, current-control, transcript, run and operation pages instead
of transmitting a complete native workspace. Older helpers retain the existing
fully validated snapshot path. A projected connection never silently falls back
to that legacy snapshot transport.

Each projected response reserves its JSON-RPC envelope within 256 KiB. Large
text and complete configuration, draft, attachment-reference and question
objects use SHA-256-bound content references with 128 KiB byte chunks. Controls
hydrate their complete typed documents before use; clipped previews never
become provider input or approval choices. Action-document hydration has a
32 MiB client limit and fails explicitly above it. The local draft limit remains
120,000 UTF-16 units: an oversized imported host draft is marked host-only until
the user explicitly copies/replaces it locally, and cannot create a pending
submit while local preservation would fail.

Catalog, thread and current-control views have separate immutable bindings.
Bindings pin environment, owned-host generation, view, sequence and a projected
manifest fingerprint. Pages/cursors also bind their query, position and total;
content binds its exact reference and byte offset. Duplicate reads are stable.
An older thread view stays coherent while current controls refresh at a newer
sequence. Small coalesced sequence notifications invalidate latest state; they
are hints, not a lossless journal replay. A fresh open enforces the previously
observed sequence floor, including catalog-only sessions and command receipts.

The host cache retains at most eight views and 128 MiB of encoded display data
and content. Release, LRU/byte-budget eviction, close and host restart invalidate
old views explicitly. A stale cursor requires refresh; it never restarts a
provider or replays input. Projection responses exclude complete native provider-history inventories,
persisted operation reviews and sealed restore manifests. Existing explicit
review endpoints still return their bounded review values; only host-cached
proof and native admission authorize writes. Projection summaries are not
converted into native workspace/thread/history evidence.

The UI retains 512 rows per collection and shows loaded ranges/incomplete
history. Catalog Refresh returns to the first window. Load Earlier pauses
following; Follow Latest opens a current transcript view. A message can load
beyond one page through a UTF-8-safe 1 MiB display window; earlier text can be
restarted and full-content verification is shown only after the final hash.
Only loaded text is displayed/copied. Operation audit pages are read-only;
current recovery heads retain their existing exact-command actions.

Current control availability is computed from the complete host state, never
from absence in a partially loaded catalog. It is an eligibility hint, not a
writer lease. Existing host file/Git/PTY admission remains authoritative, and the
client rechecks retained buffers and terminals before mutations. Exact captured
run/runtime/request identities remain usable during streaming invalidations;
older-history browsing does not freeze Stop, questions or queue controls.

This is bounded display transport and browsing. Provider-history actions use the
separate reviewed workflows above. Broader history/checkpoint ranges,
durable paged journal catch-up and persistent-host transport remain
separate unfinished parity work.

### Typed usage display

Current-control and recorded-run projections can carry typed provider usage.
Small values remain inline; larger values use the same bounded SHA-256-bound
content documents and chunks as other display data. The client validates the
complete type and captured provider/run ownership before displaying it. Older
helpers that omit these optional fields remain supported.

Main-agent token counts are separate from Claude query-session totals and
latest context/rate-limit status. Cache reads/writes are included in input and
reasoning is included in output, so display does not double-count either.
Missing observations remain unknown; no capacity, cost or historical execution
is inferred from a model name. Passive old-session meters are cleared on context
handoff while immutable accounting stays with its original run. Paging telemetry
does not grant provider-history or file-write authority and never launches a
provider. Typed OpenCode history accounting does not enable OpenCode conversation
creation on the current Codex/Claude remote surface. Live-provider and real SSH
usage acceptance remain unverified.

## Remote Files and Changes

The inspector browses directories, searches paths or text (including regular
expressions), reads UTF-8 files and creates/saves text files up to 2,000,000
bytes. Saves require the exact host-issued revision. An external change, a
replaced workspace root or a stale revision prevents overwriting the file.
Paths are interpreted only on the host; symlink escapes and Git metadata are
refused. Opaque revision tokens expire when the helper restarts or its bounded
revision cache evicts them. Save checks the unchanged remote base and obtains a
fresh revision without discarding the retained editor text; a changed base
requires explicit review/reload.

Changes shows status, staged/unstaged diffs, local/remote branches and remotes.
Controls initialize a repository, stage/unstage paths, commit, create/switch
branches, fetch, pull clean fast-forward changes and explicitly push one branch.
Git uses the host's existing noninteractive credentials. It does not prompt for
new authentication. Branch changes and pulls require saving or discarding dirty
editor buffers first. Pull-request actions and worktree removal remain unfinished.

Each mutation has an exact UUID and payload recorded privately on both sides.
The host acknowledges durable admission promptly and runs the operation as owned
work, leaving conversation Stop available. Check Result polls the original
record; it never repeats the operation. A lost response, cancellation after work
begins, or an interrupted host can leave an uncertain result. Inspect files or
Git status before explicitly dismissing it. Cancel joins the owned Git process;
this does not prove every arbitrary hook or descendant has exited. Completed
saves and commits preserve any newer text typed while they were running.

The current host journal retains up to 256 operation records or 64 MiB and
refuses further mutations at capacity. It does not silently delete receipt
history or replay interrupted operations. Capacity/recovery management remains a
follow-up; deleting the journal is not a safe retry procedure.

## Remote worktrees

Before a conversation's first message, **Choose Worktree…** can create a branch
from an explicit local base, check out an existing local branch, or reuse a
registered checkout. Inventory comes from the host, and new destinations belong
to its managed worktree directory. Source directory identity and the exact
conversation configuration/preparation are rechecked before admission. Local
filesystem paths are never substituted for remote ones.

New checkouts offer None, top-level or recursive submodule initialization.
Registered reuse preserves existing files and never initializes submodules.
Messages wait for readiness; the banner shows progress, cancellation and errors.
**Inspect Result** checks a saved attempt without creating a checkout or starting
queued input.
**Retry** uses native ownership evidence or a new destination, preserving earlier
folders and branches. A failed preparation can also be replaced with a new
explicit selection after queued messages are cleared. Unconfirmed commands use
the existing exact-payload receipt lookup and are never replayed automatically.

Save or discard retained edits and close relevant terminal tabs before changing
the checkout. The host also excludes active file mutations and terminals on the
source/reuse destination, and prevents new mutations or terminal opens while a
preparation owns that path. Cancellation and read-only inspection remain
available. This version does not discover or execute remote project setup
scripts; those controls, worktree removal, persistent-host recovery and real
two-Mac acceptance remain separate work.

## Remote terminals

Toggle the terminal panel, then choose **New Terminal** to start the remote
account's default login shell in the selected workspace. Merely showing the
panel, changing conversations, connecting or reconnecting never starts a shell.
Tabs and output remain in memory when hidden or when another conversation is
selected. Find and text-size controls use the native terminal renderer.

The host permits eight active terminals. Input is ordered, bounded and identified
by an incarnation and sequence. Duplicate input never executes twice; a lost or
unconfirmed response pauses further input. **Check Input Result** inspects metadata
without resending keystrokes. Raw input is never journaled or logged. The host
retains the last 512 KiB of output and reports expired output explicitly. The
client retains up to 256 KiB per tab; missed or restored output renders as inert
text, with no terminal replies, clipboard access, or link automation. Live output
uses SwiftTerm's terminal emulator. Remote paths never resolve against local files.

Closing a foreground command asks for confirmation and waits for the owned PTY
to drain. A live terminal prevents Files/Changes mutations of the same root;
conversation work can coexist. Disconnect closes the owned helper and its PTYs.
Retained tabs become read-only. An explicit Attach inspects the same incarnation;
a stopped helper reports its old sessions as lost and never recreates them.
New Terminal is the explicit way to launch another shell.

The private host journal stores open identities and lifecycle metadata only,
with a limit of 1,024 records or 8 MiB. At capacity it refuses new opens; identity
pruning remains future work. Terminal output and input are not persisted by this
remote feature. Persistent process reattachment, remote setup/standalone project-script controls,
styled cold restoration and real two-Mac acceptance remain unfinished.

## Remote attachments

The remote composer accepts file/image picks, paste and drop. Imports first make
private immutable copies on this Mac, with per-environment/conversation draft
manifests. Choosing a conversation or reconnecting never starts an upload.
Send uploads its captured copies, or Upload explicitly transfers a selected file.
Progress, cancellation and explicit status checks preserve the local draft.
Attachment-only messages and queued turns use the normal Engine readiness gate.

Transfers use exact UUID/content descriptors, SHA-256, indexed 256 KiB chunks and
bounded private staging. Duplicate exact chunks are idempotent; different bytes
under the same identity are refused. Finalization creates a host-owned native
attachment reference. The submit command carries only those reference IDs and
the exact visible host draft references. It atomically claims the attachments and
records the original command receipt with the message or queued turn. A lost
reply requires Check Result; it never automatically submits the command again.
Acknowledgment removes only the corresponding captured local mappings, preserving
newer imports and text. Older helpers omit the attachment capability and cannot
receive these commands. Legacy text sends on a current helper refuse hidden
host draft attachments.

History and draft previews resolve attachments within the captured remote
conversation. Downloads verify range metadata, length and final digest before
publishing a fresh local copy for preview, open, save or image copy. A remote
attachment UUID or file path is never used to find a local workspace file.
Disconnected transfers stop; retained verified copies remain available.

Limits preserve the native 100-file, 50 MiB per-file, 10 MiB per-image and 80 MiB
combined-image policies. Host staging reserves at most 512 MiB, finalized
unclaimed files at most 6 GiB, and two finalizations run concurrently. Upload
journals retain at most 8,192 identities/32 MiB. Cancellation cannot delete an
attachment already claimed by a message. Automatic reference-aware cleanup of
retained client copies and transfer identities remains unfinished; reaching a
limit refuses new work rather than silently deleting drafts or history.

## Remote GitHub pull requests

The remote toolbar opens a repository browser for the selected conversation.
It reads context, searches open/closed/merged PRs, resolves an exact URL/number,
and shows descriptions, checks and review summaries. Metadata uses the remote
Mac's installed, already signed-in GitHub CLI; browsing or selecting a
conversation never signs in, installs tools or starts a provider.

Creation keeps a private local title/body/base/draft selection. Review captures
the published head, base and exact text on the host. Acceptance sends only its
host-issued review UUID and digest under the original durable command UUID.
Creation does not push or fork. The Push action opens the current remote Changes
inspector for a separate explicit Git push. A lost creation reply is recovered by
its saved receipt or Inspect; missing GitHub evidence never automatically repeats
creation. Explicit acknowledgment releases an unconfirmed operation's hold without
claiming it did not happen. There is no create-cancel primitive.

Open in Conversation reviews either switching the existing remote checkout or
using a separate managed/reused worktree, with explicit submodule choices. The
host selects the destination, captures provider/runtime/settings and publishes one
blank conversation only after proving completion. A busy reused worktree can be
inspected read-only, preserving local commits/edits and showing the actual head.
Separate worktrees preserve source conversation/file/terminal activity. Affected
PTY/file writers and shared Git mutations prevent conflicting mutations, and
retained local editor/commit drafts are checked again immediately before send.
Setup scripts are not run by remote PR checkout.

Checkout cancellation commits first, then drains the exact owned effect outside
the short command lane. Cancel receipt recovery likewise never blocks the serial
stdio request reader. PR recovery binds the exact registered checkout even while
its own operation holds it. Explicit acknowledgment and cancellation can use
metadata alone if that folder is missing. Inspect and acknowledgment operate on saved identities and
never fetch/checkout again automatically. Unaccepted reviews are private host
memory, capped at 64, and require fresh review after reconnect/restart; accepted
operations and original receipts remain durable. Client validation checks exact
scope, authored bytes, review digest and captured settings without resolving
remote paths on this Mac.

Only the helper's local launch accepts optional absolute `--github-executable`
and `--github-configuration-directory` arguments. These are not wire commands;
remote requests cannot choose executables, environments or credential stores.
CLI prompts, browser/editor launches and debug output remain disabled. No live
GitHub account or network mutation is exercised by the private acceptance tests.

Reviews/comments/replies, merge, labels/reviewers, reactions, rich diffs/viewed
files, PR stacks, other hosting providers and complete upstream PR parity remain
unfinished. Real two-Mac and hosted window acceptance are separate verification.

## Native service boundary

`CoincideEnvironment` owns a normal `WorkspaceEngine`, SQLite journal and runtime
lock. A closed command allow-list reaches the Engine's serial admission queue;
clients cannot supply internal Engine commands, arbitrary provider launch
arguments or authentication configuration. Captured configuration guards edits
and submission; exact run/runtime/request guards protect Stop and responses.
Accepted and rejected commands use the original UUID/payload fingerprint for
durable receipt lookup, including preparation failures.

The native JSON-RPC protocol is version **1**, independent of T3's protocol.
Conversation requests are bounded to 1 MiB. Workspace requests allow 14 MiB to
carry JSON-escaped 2 MB files; aggregate queued requests are bounded to 32 MiB.
Response frames are bounded to 16 MiB and in-flight requests to 32, with at most
eight owned read/cancel replies and eight mutation jobs. The descriptor's
optional Files/Git, pull-request, attachment and remote-terminal capabilities default to unsupported for
older helpers. Terminal byte polling is separate from workspace snapshots.
Subscription delivery coalesces complete snapshots with a monotonic
sequence; it is not a lossless event/delta replay stream. A sequence floor is
retained across reconnects within the running client/store. It is not a durable
cross-app-restart rollback attestation. Updated helpers also support the
bounded projection route described above; legacy snapshots keep their 16 MiB
frame limit and do not silently omit history.

Graceful disconnect asks the exact trusted host to drain its Engine before
joining the owned SSH process. EOF/signals also trigger host shutdown. Neither
this contract nor an SSH process exit proves every arbitrary provider-created
descendant on a remote machine has exited. Only one host can own a data directory
at a time. No LAN listener, relay, pairing credential or external daemon is
created by this feature.

## Pinned behavior to preserve

The reference is T3 Code
[`680152e27b2a961686389ca69a1557cbb2c55f08`](https://github.com/pingdotgg/t3code/tree/680152e27b2a961686389ca69a1557cbb2c55f08).

- **Environment identity and capabilities.** A public descriptor identifies the
  environment, platform, server version, orchestration protocol and supported
  capabilities. Pinned T3 negotiates orchestration protocol 2. Optional capability
  fields gate behavior; a selectable route is not proof that its operations work.
  See [environment contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/environment.ts).
- **Pairing and authorization.** The client checks the expected environment ID
  before redeeming a one-time credential. Ordinary pairing grants expire after
  five minutes; token exchange produces scoped sessions. Access-management APIs
  list and revoke pairing links and clients. Native credentials must stay in
  headers/bodies and secret storage, outside workspace journals and URLs. See
  [onboarding](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/client-runtime/src/connection/onboarding.ts),
  [grants](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/auth/PairingGrantStore.ts)
  and [auth contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/auth.ts).
- **Projection and reconnect.** Shell/thread subscriptions resume after a known
  sequence. Bounded thread snapshots expose an opaque history cursor and an
  explicit incomplete-history flag; clients must not treat a window as the whole
  transcript. See [orchestration contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/orchestrationV2.ts).
- **SSH lifecycle.** T3 resolves native SSH targets, owns a loopback forwarding
  process, bounds startup/readiness and reuses saved accepted sessions before
  pairing again. Its lifecycle distinguishes managed from external servers.
  Existing host-key and authentication decisions remain with SSH. See
  [SSH transport](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/ssh/src/tunnel.ts)
  and [platform gateway](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/client-runtime/src/platform/capabilities.ts).
- **LAN and private routes.** Advertisement follows actual bound private IPv4
  interfaces, excludes loopback/link-local and unsuitable virtual interfaces, and
  publishes Tailscale HTTPS only after a probe. Reachability, source, status and
  client compatibility are distinct endpoint properties. See
  [direct endpoints](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/apps/server/src/environment/DirectEndpoints.ts)
  and [route contracts](https://github.com/pingdotgg/t3code/blob/680152e27b2a961686389ca69a1557cbb2c55f08/packages/contracts/src/remoteAccess.ts).

## Remaining implementation sequence

1. Verify a real SSH connection between two Macs, including installed-provider
   execution, interruption, disconnect and reconnect. Controlled local-process
   acceptance does not establish remote network or provider authentication.
2. Complete remote worktree setup/removal, remaining PR controls and media files,
   provider history, broader checkpoint diffs and provider setup/authentication; add workspace
   receipt-capacity management. Private local remote-editor recovery now retains exact
   environment/project/thread/root/path/revision ownership with explicit restore,
   copy and discard; broader real-host crash/reconnect acceptance remains pending.
   Preserve the current separation between local and remote paths/services.
3. Add persistent-host ownership, signed helper provisioning/update and bounded
   durable paginated catch-up beyond the current display views. Ordered journal
   catch-up needs a gap-free handoff and explicit resynchronization; coalesced
   complete snapshots must never be reinterpreted as a lossless delta stream.
   Complete native provider-history proofs remain host-owned behind the bounded
   projection. Broad remote history must preserve this separation and expose
   reviewed opaque intents/recovery; paging just a review RPC and returning a
   full native snapshot afterward would reintroduce the old frame limit.
4. Add native HTTPS/LAN transport, pairing, scoped authorization, revocation,
   Keychain-backed client credentials and saved route/environment controls on the
   same service boundary. Proposed files: `EnvironmentHTTPServer.swift`,
   `EnvironmentAuthorization.swift`, `EnvironmentCredentialStore.swift` and
   `EnvironmentRegistry.swift`, plus native connection/settings views. The
   existing private MCP listener is loopback-only and closes each response; it
   is not a remote listener. General bounded HTTP client machinery may be shared
   without weakening provider-specific origin or credential rules.
5. Complete persistent terminal reattachment, remote setup/standalone script controls, styled cold
   restoration and terminal-identity capacity management. Preserve the existing
   separation between the headless SwiftTerm `LocalProcess` driver and the
   display-only `TerminalView` adapter, bounded byte polling and inert replay.
   Add private-route discovery, relay
   behavior and Linux/Windows portability before calling remote parity complete.
   Current Core services depend on Darwin and Security.

## First-slice verification gate

Use two isolated native processes, the real wire codec and temporary SQLite to
verify submit/output, question ownership, exact-run Stop, a dropped response with
one provider execution, reconnect replay, persisted environment identity and
identity/protocol refusal. Test graceful host shutdown and owned-process drain;
preserve external processes and unresolved work. Subsequent pairing
checks must cover atomic single use, expiry, scope refusal, revocation and a wrong
machine refusing before credential consumption. Current tests and results are
recorded in [VALIDATION.md](VALIDATION.md); native form/window interaction runs
only in hosted GUI CI. No remote infrastructure or authentication has been
changed by the local implementation checks.

## Remote composer drafts

Updated helpers advertise `supportsRemoteComposerDraftSelection`. Both projected and legacy remote conversations use the native composer for large-paste folding (32 KiB UTF-8), Paste as Text, verified text-attachment expansion, and a private 20-entry prompt stash. Stash and pop change the draft only; they never start a provider. Host references are downloaded through captured attachment access and kept as verified private copies before a stash clears them. Remote paths are never resolved on this Mac.

Local draft mutations have original UUID receipts and exact text/reference CAS. Pending mutations retain their environment, helper, thread birth, project, raw workspace and configuration scope. Receipt checks do not repeat mutations. Model/configuration advances preserve the current local draft while invalidating old operations. Drafts from older helper sessions remain available for explicit copying into the current draft; missing private bytes refuse restoration and preserve the source.

Selected sends use the additive `submitComposerDraft` lane. It checks the host draft hash, native reference bytes, captured configuration and conversation/project birth before native input capture. Attachment order is explicit. Unselected host references remain in the host composer, and later local text/references are kept when an accepted receipt is reconciled. Old helper command payloads are unchanged; selected-reference sends fail closed without the capability.

Per environment, private composer metadata is limited to 16 MiB, 256 scoped draft records and 4,096 mutation receipts/copy references; immutable private copies have a 512 MiB aggregate budget. Limits refuse new writes and keep existing data. Uploads keep the existing bounded chunk protocol and explicit uncertain-result checks. Closing owns and drains reads and accepted local writes.

### Active steering and queued-input editing

Helpers advertising `supportsRemotePromptSteering` expose bounded, leased
steering reads (`remoteEnvironment.steering.read/page/content/release`). Queue
rows and delivery history are proof-free summaries; full text and attachment
metadata are immutable references with byte counts and SHA-256 digests. Views
are limited to eight and a shared 128 MiB of encoded metadata/content, including
reserved cursor metadata. Every response reserves JSON-RPC envelope space within
256 KiB. Cursor kind, offset, total, exact source binding and repeated reply
bytes are checked. A stale or evicted view must be refreshed.

The closed `promptSteering` command is separate from Submit. Composer steering
captures the original active run, runtime and settings on the host, then uses
the existing native `PromptSteeringOperation` effect. Promoting a queued input
retains its original identity, attachments and captured settings. The sole
outer command UUID owns the durable receipt; duplicate commands and receipt
inspection after reconnect never send another steer or provider turn. Native
proven-unsent handling remains native behavior. Unknown delivery is retained,
holds the queue, and offers explicit acknowledgment without replay. Metadata
reads and acknowledgment remain available when the physical checkout is gone.

Queued edits replace only the exact reviewed queue item through
`QueuedInputReplacement`. Its complete original digest, thread birth, project,
raw workspace path and settings are checked again at commit. Text and selected
ordered attachment references change together; the queued configuration,
context reservations and active unsent composer remain intact. Reserved native
follow-ups and already-captured context deliveries refuse in-place editing.
Both native and remote queue panels open independent editors. Remote reference
bytes are read only through the captured `AttachmentAccess`, copied privately
for stashes, and uploaded under the existing bounded attachment protocol.
Queued-editor upload caches are separate from the active composer's cache,
including after an uncertain write, helper restart and receipt acknowledgment.

The legacy remote renderer and bounded projected renderer mount the same
composer and queue controls. Older helpers make no steering RPC or Submit
fallback. Local composer writes and accepted host writes keep their original
receipts; cancellation joins owned reads and releases the original leases.
Remote queue removal/reordering and remote manual Plan/Default controls remain
separate work; these controls do not claim either capability.

### Remote metadata, archive browsing and Undo

`supportsRemoteThreadActions` advertises host-captured Pin/Unpin and
Archive/Unarchive, plus grouped conversation Undo. The remote sidebar can
include archived conversations using the existing bounded catalog query;
pinned conversations sort first with stable ordering within each group. An
archived conversation keeps its local draft, private attachment copies, upload
recovery, queue and transcript. Unarchiving and Undo never replay a prompt.

A helper-issued window lease owns immutable metadata captures. The host checks
its native thread incarnation, project/thread birth, exact raw paths and
configuration, run/runtime IDs, and expected metadata before committing the
normal native action. Stop an active turn before archiving, as required by the native action. Archive acknowledgment joins only the exact captured
runtime retirement; replaying an old receipt cannot drain a replacement.

Optional `undoOwner` request metadata is omitted for legacy requests. It assigns
only claims created from genuinely committed before/after decisions, including
manual remote lifecycle snooze and immediately settled actions, to the window
that initiated them. Native inverse payloads stay on the host. The client sees
only bounded group/claim IDs, an identity digest and a remaining lifetime. Five
seconds is enforced at the native Engine admission gate before its awaited
SQLite commit; an already admitted action may finish while SQLite waits.
Repeated original accepted UUIDs remain inspectable after expiry or helper
restart. A new request cannot reuse an expired, foreign or consumed group.

The notice consumes its exact current group before awaiting transport. The
shared keyboard dispatcher owns the event once and checks the original key
window, sheets, terminal focus and IME. An intervening text edit returns Cmd-Z
to native text Undo; the explicit notice can still undo applicable metadata.
Claims are ephemeral and do not survive helper restart. No client-authored
inverse, file restoration, Git operation or provider-input replay is implied.

`supportsRemoteQueueManagement` separately advertises removal and reordering.
Commands carry the original host capture and a digest of every queued input's
full native revision. The host derives the actual native order and invokes its
existing queue primitives; text/settings/reference changes refuse a stale
request even if the UUID order stayed the same. These metadata controls can
recover a queue without inventing physical checkout authority. Older helpers
perform no new read or mutation RPC for either capability.
