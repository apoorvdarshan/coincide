# Source control actions

This page describes Coincide's native source-control review and Git/GitHub actions.
It ports T3 Code's diff panel, Git quick actions, branch picker, pull request
actions, automatic fetch/pull and Source Control settings to native macOS controls.

## Reviewing changes

The **Changes** inspector shows **Unstaged**, **Staged** and **Branch** scopes.

- The rich diff viewer has a file tree (single-folder chains are compressed), unified
  or split rows, lexical token colors by file extension, line numbers, wrapping, hiding
  whitespace changes, per-file collapse (files over 400 changed lines start collapsed),
  Collapse/Expand All, Copy Path, Show in Files and Open in Editor.
- **Branch** compares the merge base of HEAD and a chosen base with the working tree.
  Committed branch work, uncommitted edits and untracked files are included; commits
  that exist only on the base are not. The base can be any local or remote-tracking
  branch and defaults to the remote's recorded HEAD (for example `origin/main`). It is
  never fetched implicitly. Output is bounded and marked when truncated.
- Run History's workspace changes use the same viewer. Their whitespace filter is not
  available yet because checkpoint diffs are read through the workspace engine.

## Commit, push and create a pull request

The inspector's primary button follows T3's rules: commit, commit and push, push and
create a PR, create a PR, or pull, with hints for diverged, detached or up-to-date
branches. The menu offers Commit…, Push… and Create PR… directly.

- One review sheet lists the files to commit (only checked files are committed; other
  staged changes stay staged), the message, the push destination and the PR base,
  title, description and draft state.
- On the default branch, the sheet asks before pushing and offers to move the work to
  a feature branch with a collision-free name derived from the commit subject.
- Steps run in order as one exclusive inspector operation: feature branch, stage,
  commit, push, then PR. Hook and Git output appears live (sanitized, URLs redacted)
  with elapsed time. Cancel stops at the next step; finished steps are kept.
- Pushes are explicit single-branch, non-force pushes that set the upstream for a new
  branch. PR creation reuses the durable reviewed engine path and proceeds only when
  GitHub's published head is exactly the commit this action pushed; otherwise the
  normal pull request review opens. An existing open PR is reported, not recreated.
- Commit messages are typed by the person. `GitCommitMessageGenerating` is the seam
  for AI-written messages; it only fills the field and never commits.

## Branches

The branch button in the inspector and in the conversation header opens a searchable
picker. Ranking is exact, prefix, path-component prefix, then substring; the current
and default branches are pinned. It can:

- switch local branches, track remote branches, and create a branch from the typed
  name;
- show branches checked out in other worktrees with their path, and open that checkout
  as a project instead of failing a switch;
- open a pull request by `#number` or URL in the Pull Requests sheet for checkout.

When choosing a worktree base, **Start from remote** is an explicit, visible step that
fetches only that remote branch before preparing the worktree from its fetched commit.

## Pull request actions

The pull request detail offers T3's actions for the current state and the viewer's
repository permission: merge (merge commit, squash or rebase, as the repository
allows), enable/disable auto-merge, mark ready or convert to draft, update branch
(merge or rebase, when behind), close/reopen, delete the head branch (closed or merged,
same-repository heads), create a revert PR (merged) and approve waiting fork workflows.

- Choosing an action reads fresh state and opens a confirmation bound to the head
  commit and base branch/commit. Performing re-reads those identities and refuses a
  stale review before writing.
- Merges use `gh pr merge --match-head-commit`; Coincide never passes `--admin` or
  `--delete-branch`, so local branches and checkouts are untouched. Branch deletion
  uses GitHub's compare-and-swap ref update against the reviewed commit. Update Branch
  supplies the expected head to GitHub GraphQL; revert uses the reviewed pull request
  ID after the fresh state check. Workflow approval re-checks the fork head before
  each run.
- The workspace journal consumes the original review UUID before dispatch. Exact
  duplicate acceptance returns its original receipt; changed payloads cannot reuse
  that UUID. The operation and any verified result remain available after reopening.
- A write whose result is unknown stays unconfirmed across restart and is never
  replayed. Inspection only reads GitHub's current state; it does not claim that this
  attempt caused that state. Explicit acknowledgement releases the hold for a new
  review without repeating the old intent. An accepted intent that had not reached
  dispatch before restart fails safely instead of starting later.
- **Remove agent credits when merging** (Settings → Source Control, off by default)
  removes recognized agent `Co-authored-by` trailers and "Generated with" footers from
  GitHub's default merge or squash message. The confirmation shows the exact message.
  Rebase merges and merge queues keep GitHub's own messages.

## Automatic fetch and pull

The selected conversation's checkout (and its project) is fetched from the branch's
upstream remote on a schedule (default every 30 seconds; Off, 1, 5 or 15 minutes).
Auto-pull is off by default, has a global default and per-project overrides, and only
fast-forwards a clean default branch that has an upstream, is behind and has no local
commits ahead. Busy, queued, held or edited checkouts are skipped. Failures back off
exponentially up to 15 minutes. At launch, projects with auto-pull enabled are pulled
once. Automatic sync runs only in the signed app, never in test hosts.

## Settings → Source Control

- Detected Git and GitHub CLI with versions. GitHub CLI 2.81 or newer reports
  structured sign-in status; older versions use a text fallback.
- Per-host GitHub accounts from `gh auth status`, including hosts used by registered
  projects, with **Rescan** and a copyable `gh auth login --hostname` command. Coincide
  never reads or stores CLI credentials and never passes `--show-token`.
- An optional GitHub token for github.com is saved only in this Mac's Keychain and is
  passed to GitHub CLI only as `GH_TOKEN` in its environment, never in arguments or logs.
  It takes precedence over the CLI's own sign-in for pull request reads and actions.
- Automatic fetch/pull and merge-credit preferences.

## Not yet included

- AI-generated commit messages, PR titles/bodies and branch names (seam only).
- Worktree removal, PR conversation/review/comments, PR diffs, stacks and other hosts.
- The saved token applies to github.com only; enterprise tokens use the CLI's sign-in.
- PR checkout fetches use their existing GitHub CLI environment and do not yet read the
  saved token.
