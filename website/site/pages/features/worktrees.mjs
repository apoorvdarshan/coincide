import { code } from "../../layout.mjs";

export default {
  path: "/features/worktrees",
  title: "Git worktrees for parallel agent threads · Coincide",
  description: "Give each Coincide thread its own Git worktree and branch, so several coding agents can work on one repository at once without touching each other’s files.",
  name: "Worktrees",
  summary: "Run each thread in its own Git worktree and branch, so parallel agents never edit the same checkout.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "A worktree for every thread",
  lede: "Two agents editing the same checkout will trip over each other. A Git worktree gives a thread its own folder and branch from the same repository, so you can run several agents on one project at the same time and merge what works.",
  related: ["/features/git", "/features/pull-requests", "/features/terminal", "/features/projects-and-threads"],
  body: (s) => `
<h2>Starting a thread in a new worktree</h2>
<p>Under the composer of a new project thread is a strip that says where the thread runs and on which branch. Before you send the first message:</p>
<ol>
  <li>Click the workspace button (it says <strong>Current checkout</strong>) and choose <strong>New Worktree</strong>.</li>
  <li>Optionally click the branch button (“From main”, say) to pick the branch the worktree starts from. By default it’s the repository’s default branch, or the checked-out branch if there’s no default.</li>
  <li>Send your message. The first turn already runs in the worktree.</li>
</ol>
<p>Coincide creates the worktree right away on a temporary branch such as <code>coincide/1a2b3c4d</code>, then renames the branch after what your first message asks for. Settings › General › “Worktree branch prefix” changes the <code>coincide/</code> prefix, or removes it.</p>
<p>You can also choose <strong>Previous Worktree</strong> to put a new thread in the worktree another thread of the project used most recently, or <strong>Current Checkout</strong> to go back. Once the thread has sent a message, its folder is fixed.</p>

<h2>Where worktrees live</h2>
<p>Worktrees Coincide creates go in <code>~/.coincide/worktrees</code> (or a <code>worktrees</code> folder inside <code>COINCIDE_DATA_DIR</code> when that’s set), in a folder named after the repository and branch. The folder is readable only by your Mac user, since it holds checkouts of possibly private repositories. They’re ordinary Git worktrees, so <code>git worktree list</code> in the project shows them.</p>

<h2>Working in a worktree</h2>
<ul>
  <li>Agents, the ${s.link("/features/terminal", "terminal")}, ${s.link("/features/command-palette", "Go to File and Search in Project")} and the ${s.link("/features/git", "diff panel")} all use the thread’s worktree.</li>
  <li><strong>Setup scripts.</strong> A project script marked “Run when a thread gets a new worktree” runs in the new worktree’s terminal, for steps like installing dependencies or copying <code>.env</code>. Scripts get <code>COINCIDE_PROJECT_ROOT</code> and <code>COINCIDE_WORKTREE_PATH</code>; the T3 Code names (<code>T3CODE_PROJECT_ROOT</code>, <code>T3CODE_WORKTREE_PATH</code>) are set too, and scripts in a project’s <code>t3.json</code> can be imported.</li>
  <li>Reveal in Finder and Copy Path in the workspace menu take you to the folder.</li>
  <li>When the work is done, commit, push and open a pull request from the diff panel; see ${s.link("/features/pull-requests")}.</li>
  <li>The GitHub pull request workspace can check out a pull request into a worktree of its own and open a thread there.</li>
</ul>

<h2>Cleaning up</h2>
<p>Coincide removes a worktree it created only when the thread never sent a message, for example when you switch back to the checkout or delete the new thread, and only if the worktree has no changes and its temporary branch has no commits. A worktree that a thread used stays on disk, with its branch, so nothing you or an agent did is lost. Remove it with Git when you’re done:</p>
${code(`git worktree list
git worktree remove ~/.coincide/worktrees/<folder>
git branch -d coincide/<branch>   # after merging`)}

<h2>Things to know</h2>
<ul>
  <li>Git checks a branch out in only one folder at a time, so a branch that’s checked out in the project folder or another worktree can’t be used for a new one.</li>
  <li>Threads in a worktree stay with their project; they can’t be moved to another project.</li>
  <li>A worktree has its own working files. Ignored files from the main checkout, such as <code>node_modules</code> or <code>.env</code>, aren’t there until a setup script or the agent creates them.</li>
  <li>Worktrees need the project to be a Git repository.</li>
</ul>
`,
};
