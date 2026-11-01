import { table } from "../../layout.mjs";

const APP = "https://learn.chatgpt.com/docs/app";
const NEWS = "https://learn.chatgpt.com/docs/whats-new";
const MODES = "https://learn.chatgpt.com/docs/environments/modes";
const WORKTREES = "https://learn.chatgpt.com/docs/environments/git-worktrees";
const REVIEW = "https://learn.chatgpt.com/docs/code-review?surface=app";
const CLI = "https://github.com/openai/codex";

export default {
  path: "/compare/codex-app",
  title: "Coincide vs Codex in the ChatGPT desktop app",
  description: "Coincide and Codex in the ChatGPT desktop app compared: agents, platforms, local and worktree chats, plans and open source, from OpenAI’s own docs.",
  name: "vs Codex app",
  summary: "OpenAI’s Codex workspace inside the ChatGPT app, or Codex as one of six agents in an open-source Mac app.",
  type: "Article",
  eyebrow: "Compare",
  h1: "Coincide vs the Codex app",
  lede: "OpenAI’s Codex app now lives inside the ChatGPT desktop app, as a dedicated Codex view. Coincide runs Codex through the Codex CLI, next to five other agents. Here’s what each one does, according to its own documentation.",
  updated: "2026-11-01",
  published: "2026-11-01",
  related: ["/agents/codex", "/features/worktrees", "/features/switch-agents", "/compare/claude-desktop", "/docs/import-cli-sessions"],
  body: (s) => `
<p>OpenAI launched the Codex app for macOS in February 2026 and for Windows in March. According to OpenAI’s <a href="${NEWS}">What’s new page</a>, “On July 9, the Codex app merged into the ChatGPT desktop app for macOS and Windows,” where Codex keeps “its dedicated coding experience alongside ChatGPT’s Chat and Work.” This page compares that Codex experience with Coincide. Facts about OpenAI’s app come from its <a href="${APP}">app page</a> and the Codex docs linked below.</p>

<h2 id="at-a-glance">At a glance</h2>
${table(["", "Codex in the ChatGPT desktop app", "Coincide"], [
  ["Made by", "OpenAI", "Apoorv Darshan; open source under the MIT license"],
  ["Platforms", "macOS and Windows (OpenAI’s <a href=\"" + APP + "\">app page</a> also offers a Linux download)", "macOS 26 or later, Apple silicon and Intel"],
  ["Agents", "Codex", "Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity"],
  ["Sign-in", "Your ChatGPT account; “available globally on every ChatGPT plan, including Free”", "For Codex: the Codex CLI’s ChatGPT sign-in or an OpenAI API key"],
  ["Where chats run", "<a href=\"" + MODES + "\">Local, Worktree or Cloud</a>; Local and Worktree run on your computer", "On your Mac"],
  ["Worktrees", "In <code>$CODEX_HOME/worktrees</code>, detached HEAD, most recent 15 kept by default", "Per thread, on a new branch, under <code>~/.coincide/worktrees</code>"],
  ["Source code", "The <a href=\"" + CLI + "\">Codex CLI</a> is open source (Apache-2.0)", "The whole app, MIT"],
])}

<h2 id="agents">Codex only, or Codex among others</h2>
<p>OpenAI’s app is built around Codex. Coincide treats Codex as one of six agents: its models sit in ${s.link("/features/model-picker", "one picker")} with the others’, and a thread can ${s.link("/features/switch-agents", "switch from Codex to another agent")} and back, each keeping its own native session. When Coincide runs Codex, it starts <code>codex app-server</code> with your existing sign-in, so Codex’s plan mode, steering of a running turn, approvals and rate limits all come from Codex itself. ${s.link("/agents/codex", "Codex in Coincide")} has the specifics, including the CLI versions it supports.</p>

<h2 id="worktrees">Worktrees and parallel work</h2>
<p>In OpenAI’s app, you choose a mode when you start a Codex chat: Local works in your project directory, Worktree isolates changes in a Git worktree, and Cloud starts a remote task. OpenAI’s <a href="${WORKTREES}">worktree docs</a> say Codex creates worktrees in <code>$CODEX_HOME/worktrees</code>, checks them out in a detached HEAD state rather than on a branch, and keeps your most recent 15 by default. Coincide’s ${s.link("/features/worktrees", "worktrees")} are per thread: each one starts on a new branch, so you can commit, push and open a pull request from it. Coincide doesn’t run cloud tasks.</p>

<h2 id="review">Reviewing changes</h2>
<p>OpenAI’s <a href="${REVIEW}">review pane</a> lets you attach inline comments to lines in the diff, stage or revert parts of the work, and commit or push; <code>/review</code> asks Codex for prioritized findings. In Coincide, ${s.link("/features/git", "diffs")} cover uncommitted changes, the branch and each turn, checkpoints revert a turn, and ${s.link("/features/pull-requests", "pull requests")} work on GitHub, GitLab, Bitbucket, Azure DevOps and Forgejo/Codeberg, with a GitHub PR workspace for checks and reviews.</p>

<h2 id="automation">Schedules, browser and the desktop</h2>
<p>OpenAI’s app page says you can “create a standalone scheduled task or schedule a task inside an existing chat” and “use the browser, desktop apps, and plugins.” Coincide has ${s.link("/features/scheduled-tasks", "scheduled tasks")} that send a message into a thread, or start a new one, while Coincide is open; a ${s.link("/features/browser", "browser in every thread")} that agents can drive when you allow it; and ${s.link("/features/computer-use", "Computer Use")}, off by default, for operating other Mac apps. These work the same whichever agent the thread uses.</p>

<h2 id="history">Bringing Codex history along</h2>
<p>Coincide can import conversations from the Codex CLI. <strong>File › Import CLI Session…</strong> lists local Codex and Claude Code histories, and an imported thread keeps its Codex session ID, so the next turn continues the same native session. See ${s.link("/docs/import-cli-sessions", "Importing CLI sessions")}.</p>

<h2 id="codex-better">When Codex in the ChatGPT app is the better choice</h2>
<ul>
  <li>Codex is your only agent and you want OpenAI’s own app, with ChatGPT’s Chat and Work next to it.</li>
  <li>You want cloud tasks, or to follow Codex chats from the ChatGPT mobile app.</li>
  <li>You use Windows, or a Mac older than macOS 26.</li>
</ul>

<h2 id="coincide-better">When Coincide is the better choice</h2>
<ul>
  <li>You use Codex together with Claude Code, Cursor, Grok Build, OpenCode or Antigravity, and want them in one window and one picker.</li>
  <li>You want to hand a thread from one agent to another without re-explaining the task.</li>
  <li>You want an open-source app that runs your agents only on your Mac.</li>
</ul>

<p class="note">Checked on November 1, 2026 against OpenAI’s <a href="${APP}">app page</a>, <a href="${NEWS}">What’s new</a>, <a href="${MODES}">environment modes</a>, <a href="${WORKTREES}">worktrees</a> and <a href="${REVIEW}">code review</a> docs, and the <a href="${CLI}">Codex repository</a>; products change, so check their sites. ChatGPT and Codex are trademarks of OpenAI; Coincide isn’t affiliated with or endorsed by OpenAI.</p>
`,
};
