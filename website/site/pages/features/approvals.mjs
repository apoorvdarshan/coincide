import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/approvals",
  title: "Approvals, full access and agent questions · Coincide",
  description: "Choose per thread whether coding agents run freely or ask before each command and file edit, and answer agents’ questions right in the thread.",
  name: "Approvals and questions",
  summary: "Let agents run freely or approve each command and edit, per thread, and answer agents’ questions inline.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Full access, approvals and questions",
  lede: "Each thread has an access setting. With Full access, agents run commands and edit files without asking. With Ask for approval, every command and file change waits for you, and the request appears right above the composer.",
  related: ["/features/plan-mode", "/features/background-agents", "/features/notifications", "/features/computer-use"],
  body: (s) => `
<h2>Choosing the access mode</h2>
<p>The access button in the composer shows the thread’s mode. Change it there, with Thread › Access… (${kbd("⇧", "⌘", "A")}), or with Choose Access… in the ${s.link("/features/command-palette", "command palette")}.</p>
<ul>
  <li><strong>Full access</strong>: “Agents run commands and edit files without asking.” This is the default for new threads.</li>
  <li><strong>Ask for approval</strong>: “Agents ask before running commands or editing files.”</li>
</ul>
<p>Settings › General › New Threads › Access sets what new threads start with, and a project’s Project Defaults… can set its own. Changing the access of one thread also makes it the default for the next new thread.</p>
<p>When you move a thread from Full access to Ask for approval, Coincide ends the agent sessions that might still hold full access: idle ones at once, a running one when its turn ends. The next message resumes them under approval, so an agent can’t keep working unasked in the background.</p>

<h2>Answering an approval</h2>
<p>An approval request shows above the composer with what the agent wants to do, such as a command approval with the exact command, a file change approval, or a web access approval, and the agent’s own choices as buttons. Common choices:</p>
<ul>
  <li><strong>Allow</strong> once, or <strong>Deny</strong>, which lets the agent try something else;</li>
  <li><strong>Deny and stop</strong>, which also ends the turn;</li>
  <li>a session-wide choice such as “Always allow this session” (Claude Code) or “Allow for this session” (Codex), and for Codex sometimes “Always allow” a specific command or host.</li>
</ul>
<p>Some requests have a text field for a note to send with your choice. If you type a new message while an approval is waiting, sending it declines the request and steers the agent with your message instead. The Dock icon’s badge counts approvals waiting in all threads, and with Coincide in the background a notification tells you; see ${s.link("/features/notifications")}.</p>

<h2>What each mode means for each agent</h2>
<p>Coincide maps the two modes onto each agent’s own permission system, so the agent enforces them.</p>
${table(["Agent", "Full access", "Ask for approval"], [
  ["Claude Code", "<code>bypassPermissions</code>. If your Claude Code settings don’t allow it, Coincide falls back to auto mode, then to asking.", "Claude Code’s default mode. “Always allow” is limited to this session and never switches Claude into a mode that skips more than file-edit prompts."],
  ["Codex", "Never asks, and runs without a sandbox.", "A read-only sandbox; Codex asks before commands it doesn’t trust and before any change."],
  ["Cursor", "Runs <code>cursor-agent</code> with <code>--force</code>.", "Cursor’s own options for each request, plus Cancel."],
  ["Grok Build", "Grok’s always-approve mode.", "Grok’s default permission mode: Approve, Allow all edits this session, Decline or Cancel."],
  ["OpenCode", "Allows everything.", "Asks before shell commands, edits and work outside the project folder."],
  ["Antigravity", "Antigravity’s yolo mode.", "Allow once, Allow for this thread, Deny or Cancel, with Google’s security note."],
])}
<p>For Grok Build and Antigravity, reading and searching files never needs approval, in either mode. Changing the access mode of a Cursor or Grok Build thread restarts the agent process, which then reloads the conversation.</p>

<h2>Questions from the agent</h2>
<p>Agents sometimes stop to ask you something, such as Claude Code’s AskUserQuestion, Codex’s input requests, Cursor’s and Grok Build’s questions, Antigravity’s interactions and OpenCode’s forms. Coincide shows them one at a time above the composer: pick an option or type an answer, then go on to the next with Next or Back. Answers to secret questions use a password field and aren’t saved in the transcript. In the work log the question reads “Answer below” until you do, then lists your answers.</p>
<p>Claude Code and Codex can also show forms from their MCP servers. OpenCode forms with links, hidden or conditional fields are declined with a note to the agent, since Coincide can’t show them faithfully.</p>

<h2>Choosing wisely</h2>
<ul>
  <li>Full access is fast but trusts the agent with your shell and files. Run it in a ${s.link("/features/worktrees", "worktree")}, keep ${s.link("/features/git", "checkpoints")} on, and review the diff.</li>
  <li>Ask for approval suits unfamiliar repositories, production credentials, or prompt-based ${s.link("/features/plan-mode", "plan mode")}.</li>
  <li>Schedules an agent creates for itself have their own approval: by default you allow them from a card in the thread (Settings › General › “Approve schedules agents create”). See ${s.link("/features/scheduled-tasks")}.</li>
</ul>
`,
};
