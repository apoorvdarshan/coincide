import { table } from "../../layout.mjs";

export default {
  path: "/features/pull-requests",
  title: "Commits, pushes and pull requests · Coincide",
  description: "Commit, push and open pull or merge requests on GitHub, GitLab, Azure DevOps, Forgejo or Bitbucket from Coincide, with agent-written messages.",
  name: "Commits and pull requests",
  summary: "Commit, push and open pull requests on five Git hosts with agent-written messages; review GitHub PRs beside the chat.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Commits, pushes and pull requests",
  lede: "When an agent’s work is ready, ship it from the diff panel: one action can create a branch, commit, push and open the pull request, with the message and description written by the thread’s own agent. For GitHub, a pull request workspace sits beside the conversation.",
  related: ["/features/git", "/features/worktrees", "/features/composer", "/features/approvals"],
  body: (s) => `
<h2>The Git actions button</h2>
<p>At the foot of the ${s.link("/features/git", "diff panel")} a bar shows the branch, how it stands against its upstream, and a Git action button: a primary action for the current state plus a menu with <strong>Commit…</strong>, <strong>Push</strong>, <strong>Pull</strong> and <strong>Create Pull Request</strong> (Create Merge Request on GitLab). Actions run in sequence, so one click can commit, push and open the request. Pushing to, or opening a request from, the default branch asks first.</p>

<h2>Committing</h2>
<p>The commit sheet lists the changed files to include and a message field. Leave the message empty and the thread’s agent writes one from the changes you’re committing. <strong>Use a Feature Branch</strong> creates a branch named after the change and commits there, which is handy when you’re on <code>main</code>.</p>
<p>The agent writes commit messages and pull request descriptions in a separate read-only session: it runs in plan mode and every approval is declined, so it can’t change anything. For a pull request it also gets a summary of the thread that made the change. If no agent is ready or it doesn’t answer in time, Coincide falls back to a plain summary of the changed files or commits.</p>

<h2>Pull and merge requests on five hosts</h2>
<p>Coincide reads the repository’s remote to tell which host it’s on, then uses that host’s own command-line tool with your existing sign-in. Nothing goes through a Coincide server.</p>
${table(["Host", "How the request is opened"], [
  ["GitHub (and GitHub Enterprise)", "GitHub CLI, <code>gh</code>"],
  ["GitLab", "GitLab CLI, <code>glab</code>, as a merge request"],
  ["Azure DevOps", "Azure CLI, <code>az</code>, with its <code>azure-devops</code> extension"],
  ["Forgejo and Codeberg", "Gitea CLI, <code>tea</code>, which signs in to Forgejo servers"],
  ["Bitbucket", "On the web: Coincide opens Bitbucket’s page for creating the pull request"],
])}
<p>If an existing request already covers the branch, Coincide finds it instead of opening another. Without the host’s CLI signed in, hosts other than GitHub open their web page for creating the request. Coincide runs these tools so they never prompt and never install or update anything.</p>

<h2>The GitHub pull request workspace</h2>
<p>View › Show Pull Requests opens a panel beside the conversation, sharing the inspector with the diff, for the thread’s repository on GitHub. It lists <strong>Open Pull Requests</strong>, <strong>My Pull Requests</strong> or <strong>Review Requested</strong>, and for one pull request shows its description, reviews and checks with their status. From there you can:</p>
<ul>
  <li><strong>Review…</strong>: approve, comment or request changes with a message. The review is attached to the exact revision you looked at.</li>
  <li><strong>Merge…</strong>: create a merge commit, squash and merge, or rebase and merge, as the repository allows. Coincide merges the revision you reviewed, so commits pushed after you looked aren’t merged by surprise. The branch stays, local and remote.</li>
  <li><strong>Mark Ready for Review</strong> for a draft.</li>
  <li><strong>Check Out in New Thread</strong>: creates a worktree on the pull request’s branch and opens a thread in it, so an agent can work on the PR without touching your checkout. It uses <code>gh pr checkout</code>, which also handles branches from forks.</li>
  <li><strong>Mention in Message</strong>, or type <code>#</code> in the composer, to link a pull request in what you send.</li>
</ul>

<h2>What you need</h2>
<ul>
  <li>The host’s CLI installed and signed in, for example <code>gh auth login</code>. The pull request workspace needs <code>gh</code> and a repository on GitHub; for other hosts it says the repository is elsewhere.</li>
  <li>A remote to push to. Without one, only Commit is available.</li>
  <li>Committing works in any Git repository, including a thread’s ${s.link("/features/worktrees", "worktree")}.</li>
</ul>
`,
};
