import { table } from "../../layout.mjs";

const HOME = "https://www.conductor.build";
const DOCS = "https://www.conductor.build/docs";
const FAQ = "https://www.conductor.build/docs/faq";
const WORKSPACES = "https://www.conductor.build/docs/concepts/workspaces-and-branches";
const HARNESSES = "https://www.conductor.build/docs/reference/harnesses";
const CLAUDE = "https://www.conductor.build/docs/reference/harnesses/claude-code";

export default {
  path: "/compare/conductor",
  title: "Coincide vs Conductor for parallel coding agents",
  description: "Coincide and Conductor both run coding agents on your Mac. Compare agents, workspaces, sign-in, mid-thread switching and data, using Conductor’s docs.",
  name: "vs Conductor",
  summary: "Two Mac apps for running agents in parallel: workspaces per task, or threads that can change agents.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs Conductor",
  lede: "Conductor and Coincide are both Mac apps for running several coding agents at once, on your own machine, with your own subscriptions. They organize the work differently. Here’s a side-by-side based on each one’s documentation.",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/features/worktrees", "/features/switch-agents", "/agents", "/compare/t3-code", "/compare/codex-app"],
  body: (s) => `
<p>Conductor’s <a href="${DOCS}">documentation</a> says it “lets you run Claude Code, Codex, Cursor, and OpenCode in parallel,” giving each task its own workspace, branch, files, terminal, diff and review path, and its <a href="${FAQ}">FAQ</a> says it “always runs on your Mac.” Coincide also runs agents in parallel on your Mac, organized as threads in projects. Facts about Conductor below come from those pages and the others linked.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "Conductor", "Coincide"], [
  ["Platform", "Mac (“Run parallel coding agents on your Mac”)", "macOS 26 or later, Apple silicon and Intel"],
  ["Agents", "Claude Code, Codex, Cursor and OpenCode (<a href=\"" + DOCS + "\">docs</a>)", "Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity"],
  ["Unit of work", "A workspace per task, with its own branch, made with Git worktrees (<a href=\"" + WORKSPACES + "\">docs</a>)", "A thread per conversation; a worktree when you want one, under <code>~/.coincide/worktrees</code>"],
  ["Agent binaries", "“Conductor comes with Claude Code preinstalled” and can use a system copy instead (<a href=\"" + CLAUDE + "\">docs</a>); Cursor sessions use Cursor Agent through the Cursor API", "The CLIs you install and sign in to; Antigravity’s runtime is downloaded from Google when you set it up"],
  ["Sign-in", "Credentials already on your Mac, or keys you set in Settings (<a href=\"" + FAQ + "\">FAQ</a>)", "Each CLI’s own sign-in, or API keys stored in your Keychain"],
  ["Price", "The FAQ calls Conductor “an amazing free tool” and says the team plans to charge for future collaboration features", "Free; open source under the MIT license"],
  ["App data", "<code>~/Library/Application Support/com.conductor.app</code> and <code>~/conductor</code>", "<code>~/Library/Application Support/Coincide</code>"],
])}

<h2 id="organizing">Workspaces or threads</h2>
<p>Conductor starts from the task: each workspace is an isolated checkout on its own branch, and when the work is ready you review the diff, open a pull request, merge and archive the workspace. Coincide starts from the conversation. A ${s.link("/features/projects-and-threads", "thread")} can work directly in your checkout or in its own ${s.link("/features/worktrees", "worktree")}, and Coincide also has chats that don’t belong to any project. Both show diffs and support pull requests; Coincide adds ${s.link("/features/git", "per-turn checkpoints")} so you can revert a single turn.</p>

<h2 id="switching">Changing agents</h2>
<p>Coincide can ${s.link("/features/switch-agents", "switch agents inside one thread")}: each agent keeps its own native session, and the one you switch to gets a recap of the turns it missed, then continues in the same folder. That’s useful when one agent gets stuck, or when you want a second opinion on the same work.</p>

<h2 id="agents">Agents and how they’re run</h2>
<p>Conductor’s <a href="${HARNESSES}">harness docs</a> say its Claude Code and Codex come bundled, so you don’t install them separately. Coincide doesn’t bundle agent CLIs: it uses the ones on your Mac, with the sign-ins you already have, and tells you in Settings when one is missing or signed out. It also supports two agents Conductor’s docs don’t list, ${s.link("/agents/grok-build", "Grok Build")} and ${s.link("/agents/antigravity", "Antigravity")}. Each ${s.link("/agents", "agent page")} explains how Coincide drives that agent and what it can and can’t do there.</p>
<p>Both tools leave billing with your providers. Conductor’s <a href="${CLAUDE}">Claude Code docs</a> warn that an <code>ANTHROPIC_API_KEY</code> set in Conductor or in the shell that launches it may be used instead of your Claude subscription.</p>

<h2 id="more">Beyond running agents</h2>
<p>Coincide also includes tools that aren’t about parallel coding as such: a ${s.link("/features/browser", "browser per thread")} that agents can drive, ${s.link("/features/computer-use", "Computer Use")} for other Mac apps, ${s.link("/features/scheduled-tasks", "scheduled tasks")}, ${s.link("/features/bots", "bots")}, ${s.link("/features/dictation", "dictation")} and a ${s.link("/features/background-agents", "background agent host")} that keeps turns running after you quit. Conductor’s docs cover areas of their own, such as checks, agent modes and an API with an MCP server.</p>

<h2 id="conductor-better">When Conductor is the better choice</h2>
<ul>
  <li>You think in tasks, each with its own branch and pull request, and want that structure built in.</li>
  <li>You want Claude Code and Codex to come with the app rather than install them yourself.</li>
  <li>You use Conductor’s own features, such as its API and MCP server.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You want to change agents within one conversation, or use Grok Build or Antigravity.</li>
  <li>You want chats and bots alongside project work, or browser, Computer Use and schedules around your agents.</li>
  <li>You want an open-source app you can read and build yourself.</li>
</ul>

<p class="note">Checked on November 1, 2026 against <a href="${HOME}">conductor.build</a>, Conductor’s <a href="${DOCS}">docs</a>, <a href="${FAQ}">FAQ</a>, <a href="${WORKSPACES}">workspaces</a>, <a href="${HARNESSES}">harnesses</a> and <a href="${CLAUDE}">Claude Code</a> pages; products change, so check their sites. Conductor is a trademark of its owner; Coincide isn’t affiliated with or endorsed by Conductor.</p>
`,
};
