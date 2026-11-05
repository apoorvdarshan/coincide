# Windows instruction Git synchronization

The Windows workflow keeps the original instruction master and its links in place and
tracks a separate Markdown copy in a chosen repository. It follows the Mac copy/agreed
digest model in `CoincideKit/Instructions/InstructionCopies.swift` and the isolated-file
commit/history checks in `InstructionSync.swift`. Git divergence stops for review;
Windows never force-pushes, resets, stashes, rebases, or clears an existing destination.
macOS iCloud integration is separate.

`InstructionsPanel::create(locations)` remains a sync-inert read-only preview. Root
enables the product controls explicitly with `create(locations, syncDataDir, runner)`;
the optional runner defaults to native Git/gh discovery on first explicit operation.
Construction never starts a CLI, authenticates, contacts a remote, or edits an
instruction file. Selecting an existing configured link can read local Git status on
a worker. Existing instruction discovery and preview APIs remain compatible.

`git_sync()` returns the optional `InstructionGitPanel`. Its native controls support
linking an existing repository, preparing a new local repository, cloning an existing
remote, creating a **private** GitHub repository for an explicit `owner/name`, status,
local-to-Git and Git-to-local review, isolated copy commits, fetch, fast-forward pull,
push, pause/resume automatic synchronization, and unlink. A read-only concrete review
shows text, paths and effects. A fresh unchecked consent box and separate Approve
button are required. Cancellation changes no files. Review permits are single-use;
new reviews replace older permits. Source/copy hashes and identities, root/Git/common
folder identities, HEAD, upstream, outgoing paths, remote destination and settings
must still match at execution. Scope changes and panel close cancel pending work.

`instruction_git::Service(dataDir, runner)` provides the non-UI contract:

- `bindings()`, `reload()`, `status(bindingID)` inspect scoped saved metadata and Git.
- `attach(source, repo, copy)` and `setup(source, destination, copy, kind, address)`
  prepare immutable review objects without copying, committing or contacting a remote.
- `preview(bindingID, Action, automaticPush)` prepares a concrete existing-link action.
- `apply(review, cancel)` consumes it before mutation; `discard(review)`/`discard_all()`
  cancel. `unlink` and pause work even when repository/source folders are unavailable.
- `tick(monotonicMilliseconds, cancel, permittedBinding)` runs only approved automatic
  policies; a denied busy-workspace permit defers work without an automatic resume or
  policy change. Calls are serialized; no lock is held while waiting for user approval.

`InstructionGitPanel` exposes `set_mutation_guard(path -> bool)`, `mutating()`,
`repository_root()`, `mutation_target()`, and `mutation_targets()` for Root's existing
same-repository leases. Targets include both the repository and resolved source parent,
covering copy writes and automatic fetch/reference writes. Root should retain the pane
or its coordinator and call its `tick(GetTickCount64())` from the app-level timer,
including while the pane is hidden. No provider/model API participates in sync. Root
owns main/timer/guard wiring, test routes and resource catalog updates.

Automatic sync defaults off and requires its own explicit review. It checks at most
once per minute and fetches at most every five minutes, following the inspected Mac
cadence. Automatic push is a separate off-by-default checkbox. Approved local changes
can update and commit the Git copy, then push permitted instruction-only history.
Incoming text, two-sided changes, Git conflicts, unavailable files, failed network/auth
or uncertain actions pause the binding for explicit review/resume. Incoming Git text
never silently overwrites the local master. Wake/relaunch performs one current check;
there is no accumulated backlog. Opt-in timer execution requires Root's integration.

Commits use a temporary index and plumbing with UTF-8, excluding unrelated staged
entries, clean filters and hooks. Built-in text/EOL attributes normalize only the Git
blob's CRLF pairs, preserving original source and working-copy bytes. Custom clean/
smudge filters and working-tree encodings are refused before status inspects content.
The real index is updated only for the selected copy.
Before push, every path in outgoing commit history must be a configured instruction
copy in the same repository; reverted unrelated changes still refuse. Secret-shaped
material in the copy or outgoing patch blocks commit/push. This conservative check is
not a general secret-scanning guarantee. Push uses the named reviewed remote and
explicit branch, without force, tags or submodule recursion. Separate/multiple push
destinations, credential-bearing URLs/query strings, custom transport helpers, and an
upstream belonging to another remote require manual configuration review.

Overwriting instruction content preserves its existing file identity and every link
to that file. An exclusive byte-range lock prevents ordinary readers from observing a
partial write and refuses a target already locked by another reader. Hardlinked files,
reparse escapes and changed link targets are refused.
Before overwrite, a durable backup is retained in `syncDataDir/instruction-backups`;
it is never staged in the instruction repository. A failed write attempts restoration
and retains the backup. A power/storage failure during a write can still require
explicit recovery from that backup; the code does not claim a cross-filesystem atomic
transaction. Unlink removes metadata only. No repository, master, copy or backup is
deleted by the product workflow.

Private GitHub creation requires an explicit named owner, `--private`, available
existing gh authentication, and a subsequent nonsecret identity/privacy verification.
It does not sign in, unlock a vault, create an account, install a tool, or push during
creation. A failed/uncertain create retains the local folder and asks for status review
before retrying. Push is a separate concrete approval. Missing Git/gh, author identity,
auth/access denial, network failures, unavailable repositories and conflicts produce
bounded status text; raw CLI stderr/credential material is never shown or persisted.

Settings are versioned bounded JSON, off by default, with unknown fields retained and
atomic replacement plus a stale-writer check. Duplicate source/copy identities, malformed
paths, oversized input and unsupported formats fail without rewriting the original.
The app stores paths, agreed digests and explicit policies, not tokens or remote secrets.

Validation uses owned temporary trees, synthetic instruction files, copied/injected
metadata, native local Git and an isolated bare remote. Private GitHub/auth responses
are injected. The initialized native UI fixture exercises review/consent/cancel/stale
source, background execution and mutation-guard behavior in a hidden host. No actual
owner instruction master, synced copy, symlink, vault, live remote or account is read,
edited, linked, authenticated or synchronized during development validation. Source
readiness, initialized UI execution and Root app integration are reported separately.

Current source checkpoint: 72 native console checks passed under MSVC C++20 `/W4 /WX
/utf-8`. The panel, existing instruction view and initialized UI fixture compile in
both main-style GetObject-active and early-undef header orders. Actual initialized
hidden UI fixture execution remains Root-owned and pending at this handoff; compilation
is not reported as a passed UI run. Fixtures isolate Git's global/system configuration
and author metadata and never invoke a live GitHub authentication command.
