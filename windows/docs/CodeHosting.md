# Native pull request workspace

`App/CodeHostingPanel.h` implements the Windows counterpart of the Mac
`PullRequestsViewController` and `PullRequestService`. Opening the panel constructs
native controls only. The owner must choose **Refresh** before Git discovery,
GitHub CLI discovery, account lookup, or network requests run.

```cpp
auto panel = coincide::CodeHostingPanel::create(
    projectDirectory,
    [](const std::filesystem::path& repository,
       const std::filesystem::path& target) { return may_mutate(repository, target); },
    [](const std::filesystem::path& createdWorktree) { /* open project/thread */ });
// Attach panel->view() to the owner's native visual tree.
// Call panel->close() before discarding the owner/window.
```

The guard is required for all mutations, including remote reviews and metadata
changes. It runs on the UI thread before confirmation and again afterward.
`repository_root()`, `common_directory()`, `mutating()`, and `mutation_target()`
expose the identities needed by the root's two-way agent/terminal/Git lease guard.
The mutation flag is set synchronously before starting the worker and retained
until worker/UI completion. A successful worktree callback runs after release so
the root can bind the new context. No guard means mutations are refused.

The optional fourth `Confirm` callback supplies an owner-native confirmation for
tests or a shared app dialog. Without it the panel uses a `ContentDialog` with
Cancel as default. The optional fifth `code_hosting::Runner` injects a complete
CLI transport. Both are trusted application callbacks; they are not tool or
website fields.

The panel provides Open/Mine/Review Requested, explicit refresh, native read-only
description/check/review metadata, immutable diff, editable review messages,
merge method choice, Mark Ready, and creation of a separate detached review
worktree. No HTML from PR bodies executes. Refresh invalidates action previews;
failed/cancelled reviews retain their draft. A successful action requires a new
selection or refresh before another write.

## Backend contract

`Runtime/CodeHosting.h` is synchronous and must run off the WinUI dispatcher:

- `Service(folder, Runner={})` is inert.
- `refresh(Filter::open, "origin", Cancel={}) -> Listing` verifies the selected
  local Git working tree/common directory, named remote and authenticated viewer.
  The resulting scope holds directory pins for its lifetime.
- `detail(number, Cancel={}) -> shared_ptr<const Detail>` loads the exact head
  and base, checks pinned to head OID, latest review decisions and description.
  It reads PR metadata again after checks/reviews to reject moving heads/bases.
- `diff(Detail, Cancel={}) -> string` asks for the literal immutable base/head
  comparison. It never substitutes a moving `pr diff` result.
- `plan(detail, Action, Review, body, Merge, target) -> Plan` captures the exact
  operation for direct native owner confirmation. The caller then holds the
  repository/runtime lease while calling `execute(plan, Cancel={}) -> Outcome`.

Every GitHub CLI command specifies the verified hostname/repository explicitly.
The backend clears inherited Git directory/index/object overrides and ambient
`GH_REPO`/`GH_HOST` in each child, disables prompts/pagers, and uses direct argv.
Generic `GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN` are removed because they
are not host bound. Generic public `GH_TOKEN`/`GITHUB_TOKEN` remain available
only for exact `github.com`; other hosts use gh's existing host-specific stored
credentials. A repository-selected hostname cannot receive a generic token.
Review JSON (including `commit_id`) travels on stdin; review text is never shell
text or command arguments. Errors do not echo raw authenticated CLI stderr.
No secrets, account profiles, repositories, or credentials are created.

Merge rechecks account/repository/head/base/current checks/review state and
allowed methods, then uses `--match-head-commit` without admin bypass, auto-merge,
force, or branch deletion. Readback distinguishes merged from merely requested.
The server remains authoritative for protected branch and required review rules.
Checks/reviews beyond the bounded first page make the preview incomplete and
disable merging. PR lists stop at 100 and disclose that limit. A failed or
interrupted write is never automatically retried.

Mark Ready is a metadata transition matching the Mac behavior. It needs direct
confirmation and fresh expected-head preflight. GitHub supplies no atomic head
precondition for it, so readback explicitly reports a changed head/base or an
unconfirmed transition. It does not claim atomic head pinning.

Review checkout fetches the literal reviewed commit from the verified remote,
without writing `FETCH_HEAD`, and creates a **new detached worktree**. The existing
branch, HEAD, index, working files, stash, and other worktrees remain unchanged.
Only a new absolute local destination in an existing parent is accepted; existing
folders, linked parents, device aliases and alternate streams are refused.
Physical directory ancestors are held with `FILE_LIST_DIRECTORY` and denied
delete sharing. After fetching, the new destination is created exclusively and
pinned before Git populates it. There is no force cleanup: if a command is
interrupted or post-verification fails, any created folder/worktree/files are
retained and the error asks for review.

Native children are owned jobs with bounded stdout, cancellable waits, and 45s
read/120s mutation deadlines. The selected user's installed Git/GitHub CLI and
their ordinary trusted transport/auth configuration are used; no new dependency
is installed and no credential is put in a URL query or command argument.

## Offline validation

`Tests/CodeHostingTests.h::code_hosting_tests(report)` uses only unique owned
temporary directories and a fully injected CLI runner. It tests scoped argv,
Unicode and multiline review stdin, identity changes, moving heads, pinned
checks/diffs, incomplete/unknown/failing checks, allowed merge methods,
`--match-head-commit`, honest readback, no automatic review retries, cancellation,
and detached worktree arguments without running Git or contacting any service.

`Tests/CodeHostingPanelTests.h::code_hosting_panel_tests(report, xamlRoot)` uses
native controls plus the same injected transport. It verifies opening is inert,
explicit refresh/selection, read-only previews, native confirmations, guards on
both sides of confirmation, mutation lease lifetime, draft preservation, moving
head refusal and worktree callbacks. This is offline synthetic acceptance;
actual sign-in, live PR writes, real repository checkout and network integration
remain deliberately untested while the owner is absent.
