import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/git",
  title: "Diffs, per-turn checkpoints and rewind · Coincide",
  description: "Review every agent turn in Coincide’s diff panel, revert files to before any turn with Git checkpoints, and fork or rewind a conversation.",
  name: "Diffs and checkpoints",
  summary: "See what each turn changed, put files back the way they were before it, and fork or rewind the conversation.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Diffs, checkpoints, fork and rewind",
  lede: "Coincide snapshots your working tree around every agent turn, so you can see exactly what a turn changed and undo it, whichever agent did the work. Git does the bookkeeping; your branches, index and stash are left alone.",
  related: ["/features/worktrees", "/features/pull-requests", "/features/transcript", "/features/switch-agents"],
  body: (s) => `
<h2>The diff panel</h2>
<p>View › Show Diff (${kbd("⌘", "D")}) opens the diff beside the conversation, for the thread’s folder: its project checkout or its ${s.link("/features/worktrees", "worktree")}. Its menu chooses what to show:</p>
${table(["Scope", "What it shows"], [
  ["Uncommitted Changes", "Everything in the working tree that differs from the last commit, untracked files included"],
  ["Branch Changes", "Everything the current branch changed since it left its base branch"],
  ["Latest Turn", "What the agent’s most recent turn changed, updating while the turn is still running"],
  ["Turn 1, Turn 2, …", "Any earlier turn of the thread, with its time and the number of files it touched"],
])}
<p>The diff options switch between <strong>Unified Diff</strong> and <strong>Side-by-Side Diff</strong>, ignore whitespace, and collapse or expand every file. A file list shows each file as added, modified, deleted, renamed or untracked; from a file you can open it, copy its path or reveal it in Finder.</p>
<p>To ask for a change, select lines and choose <strong>Comment on Selected Lines…</strong>. Your comment goes to the composer as a card with those lines, so the agent knows exactly what you mean.</p>

<h2>Checkpoints</h2>
<p>With Settings › General › Git › “Create checkpoints” on (the default), Coincide snapshots the working tree before each turn and again when it ends. Each snapshot is a Git commit built in a temporary index and kept alive by a hidden ref under <code>refs/coincide/checkpoints/</code>. It never touches your index, branches or stash, and isn’t on any of your branches.</p>
<p>Checkpoints are what make per-turn diffs possible, for every agent. They need the folder to be a Git repository; for a folder that isn’t one, the diff panel offers Initialize Git.</p>

<h2>Reverting a turn</h2>
<p>On one of your earlier messages, choose <strong>Edit from here</strong>. Coincide asks “Edit from here?” and offers:</p>
<ul>
  <li><strong>Revert and Keep Changes</strong>: the conversation is rewound to before that message, which comes back to the composer for you to edit and send again. Files stay as they are.</li>
  <li><strong>Revert Files Too</strong>: the same, and the working tree is also put back the way it was before that turn, undoing every edit since.</li>
</ul>
<p>Revert Files Too is only offered when it’s safe. Restoring rewrites the whole folder, so Coincide refuses while another thread is working in the same folder, or has worked there since that turn. The checkpoints of the reverted turns are discarded, since that history no longer exists.</p>

<h2>Forking a conversation</h2>
<p>To try another direction without losing this one, choose <strong>Fork from this response</strong> on any reply, or <strong>Fork Thread</strong> in the sidebar for the conversation up to its latest finished turn. The fork is a new thread in the same project with the conversation so far, and opens with the cursor in its composer. A divider in each thread links to the other.</p>
<p>A fork, like a rewind, starts the agents’ native sessions afresh: the next agent gets a recap of the conversation it carries on, as when you ${s.link("/features/switch-agents", "switch agents")}. A fork shares the folder with its original unless you move it to a worktree, so both see the same files.</p>

<h2>Committing</h2>
<p>From the diff panel you can also commit, push, pull and open a pull request, with commit messages and descriptions an agent writes from your changes. That’s covered in ${s.link("/features/pull-requests")}.</p>

<h2>Things to know</h2>
<ul>
  <li>Checkpoints cover the thread’s folder. Changes an agent makes elsewhere on your Mac aren’t restored.</li>
  <li>Turning checkpoints off stops new snapshots; the turn scopes then say “Turn checkpoints are off”.</li>
  <li>Undoing an archive, move or delete in the sidebar never changes files. To undo an agent’s edits, revert a turn.</li>
</ul>
`,
};
