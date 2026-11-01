import { kbd, cmd } from "../../layout.mjs";

export default {
  path: "/docs/getting-started",
  title: "Getting started: install and run your first agent · Coincide",
  description: "Install Coincide, connect your first coding agent, add a project, start a thread, pick a model and choose between approvals and full access.",
  name: "Getting started",
  summary: "Install Coincide, connect an agent, add a project and run your first thread, in about ten minutes.",
  type: "TechArticle",
  eyebrow: "Guide",
  h1: "Getting started",
  lede: "Coincide runs the coding agents you already use. You bring at least one agent’s command-line tool and your sign-in; Coincide gives them one window, one model picker and threads you can hand from one agent to another. This guide takes you from download to a first finished turn.",
  related: ["/agents", "/features/projects-and-threads", "/features/model-picker", "/features/approvals", "/docs/keyboard-shortcuts"],
  body: (s) => `
<h2 id="install">1. Install Coincide</h2>
<p>Coincide runs on macOS 26 or later, on Apple silicon and Intel Macs. Download the DMG and drag Coincide to Applications, or install from Terminal:</p>
${cmd("brew install --cask apoorvdarshan/tap/coincide", "Copy the Homebrew command")}
${cmd("npx coincide-dev", "Copy the npx command")}
<p>Every release is signed with Developer ID and notarized by Apple. All the options, with system requirements, are on the ${s.link("/download", "download page")}.</p>

<h2 id="agent">2. Install and sign in to an agent</h2>
<p>Coincide doesn’t provide models. It starts each agent’s own tool with the sign-in or API key you already have, so your subscriptions keep working and nothing is routed through anyone else. Install at least one and sign in once in Terminal:</p>
<ul>
  <li>${s.link("/agents/claude-code", "Claude Code")}: <code>claude auth login</code></li>
  <li>${s.link("/agents/codex", "Codex")}: <code>codex login</code></li>
  <li>${s.link("/agents/cursor", "Cursor")}: <code>cursor-agent login</code></li>
  <li>${s.link("/agents/grok-build", "Grok Build")}: <code>grok login</code></li>
  <li>${s.link("/agents/opencode", "OpenCode")}: <code>opencode auth login</code></li>
  <li>${s.link("/agents/antigravity", "Antigravity")}: set up inside Coincide, in Settings › Antigravity (read its account-risk notice first)</li>
</ul>
<p>Each agent’s page in Settings (${kbd("⌘", ",")}, then the agent under Providers) shows its install and sign-in commands with a <strong>Run in Terminal</strong> button, and whether Coincide found it. If you installed an agent while Coincide was open, click <strong>Check Again</strong>. If the composer shows <strong>Set Up a Provider</strong>, no agent is ready yet; ${s.link("/docs/troubleshooting#not-found", "troubleshooting")} covers the usual causes.</p>

<h2 id="project">3. Add a project</h2>
<p>A project is a folder on your Mac, usually a git repository. Choose <strong>File › Add Project…</strong> (${kbd("⇧", "⌘", "O")}) and pick the folder, or open the ${s.link("/features/command-palette", "command palette")} with ${kbd("⌘", "K")} and type a path starting with <code>/</code> or <code>~</code>. The project appears in the sidebar.</p>
<p>Not everything needs a project. <strong>File › New Chat</strong> (${kbd("⇧", "⌘", "N")}) starts a chat with no folder of yours, for questions and research.</p>

<h2 id="thread">4. Start a thread</h2>
<p>With the project selected, press ${kbd("⌘", "N")} for a new thread. Before you type, look at the controls under the message field:</p>
<ul>
  <li><strong>Agent and model</strong> (${kbd("⇧", "⌘", "M")}): every installed, signed-in agent’s models in one menu, grouped by agent. Star the ones you use. See ${s.link("/features/model-picker")}.</li>
  <li><strong>Reasoning effort</strong> (${kbd("⇧", "⌘", "E")}), where the model offers levels.</li>
  <li><strong>Access</strong> (${kbd("⇧", "⌘", "A")}): <strong>Full access</strong> lets the agent run commands and edit files without asking, and is the default for new threads. <strong>Ask for approval</strong> stops at each command or file change for you to allow it. Change the default in Settings › General › New Threads. See ${s.link("/features/approvals")}.</li>
  <li><strong>Build or Plan</strong> (${kbd("⇧", "⇥")}): in plan mode the agent investigates and proposes a plan instead of changing files. See ${s.link("/features/plan-mode")}.</li>
  <li>Below the field: whether the thread works in your <strong>Local checkout</strong> or a worktree of its own, and the branch.</li>
</ul>
<p>Type what you want and press Return. The reply streams in, with the agent’s commands and file changes folded into a work log you can expand. Type <code>@</code> to mention a file and <code>/</code> for commands, or drop in images and files.</p>

<h2 id="during">5. While it works</h2>
<ul>
  <li>Send another message to steer the running turn (Claude Code, Codex and OpenCode) or queue it for afterwards. ${kbd("⌘", "↩")} does the other one.</li>
  <li>Answer the agent’s questions and approval requests where Coincide shows them, right in the thread.</li>
  <li>Press ${kbd("⌘", ".")} to stop the turn.</li>
  <li>Open the diff with ${kbd("⌘", "D")} to review what changed, or the terminal with ${kbd("⌘", "J")}.</li>
  <li>Start another thread, on another agent if you like. Threads run at the same time; the sidebar shows which are working and which need you. Coincide notifies you when a turn finishes or needs you while it’s in the background.</li>
</ul>
<p>You can quit Coincide while agents work: by default they keep running in its ${s.link("/features/background-agents", "background agent host")}, and Coincide catches up when you open it.</p>

<h2 id="switch">6. Try switching agents</h2>
<p>Open the model picker in the same thread and choose another agent’s model. The next message goes to that agent, with a recap of the turns it missed, in the same folder. Switch back later and the first agent resumes its own session. See ${s.link("/features/switch-agents")}.</p>

<h2 id="next">Where to go next</h2>
<ul>
  <li>${s.link("/features/git", "Diffs, checkpoints and git")} and ${s.link("/features/pull-requests", "pull requests")}</li>
  <li>${s.link("/features/browser", "The browser in every thread")} and ${s.link("/features/scheduled-tasks", "scheduled tasks")}</li>
  <li>${s.link("/docs/import-cli-sessions", "Import the conversations you had in Terminal")}</li>
  <li>${s.link("/docs/keyboard-shortcuts", "Keyboard shortcuts")} and the ${s.link("/docs/settings", "settings tour")}</li>
  <li>Questions: the ${s.link("/faq", "FAQ")}, or <strong>Help › Get Help on Discord</strong></li>
</ul>
`,
};
