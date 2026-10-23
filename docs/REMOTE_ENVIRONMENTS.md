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

This exposes existing native run-checkpoint workflows remotely. Remote provider
history/fork/rewind, checkpoint range diffs, portable history/merge-back and
large-history pagination remain unfinished. Offline peers and local Git fixtures
do not establish real SSH, installed-provider or remote sign-in acceptance.

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
remote feature. Persistent process reattachment, remote project-script controls,
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
cross-app-restart rollback attestation. Oversized workspaces require a future
paginated projection protocol.

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
   receipt-capacity management and crash recovery for unsaved editor buffers.
   Preserve the current separation between local and remote paths/services.
3. Add persistent-host ownership, signed helper provisioning/update and bounded
   paginated projections with explicit incomplete-history state. Ordered journal
   catch-up needs a gap-free handoff and explicit resynchronization; coalesced
   complete snapshots must never be reinterpreted as a lossless delta stream.
   Complete native provider-history proofs can already exceed the 16 MiB remote
   frame limit. Broad remote history therefore needs a negotiated bounded
   projection with paged transcript/operation summaries and host-owned complete
   proofs; paging just the review RPC cannot fix the following full snapshot.
   Removing mandatory evidence from a value called `WorkspaceSnapshot` is not a
   valid projection migration.
4. Add native HTTPS/LAN transport, pairing, scoped authorization, revocation,
   Keychain-backed client credentials and saved route/environment controls on the
   same service boundary. Proposed files: `EnvironmentHTTPServer.swift`,
   `EnvironmentAuthorization.swift`, `EnvironmentCredentialStore.swift` and
   `EnvironmentRegistry.swift`, plus native connection/settings views. The
   existing private MCP listener is loopback-only and closes each response; it
   is not a remote listener. General bounded HTTP client machinery may be shared
   without weakening provider-specific origin or credential rules.
5. Complete persistent terminal reattachment, remote script controls, styled cold
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
