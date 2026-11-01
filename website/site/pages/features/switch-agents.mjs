import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/switch-agents",
  title: "Switch coding agents mid-thread · Coincide",
  description: "Hand a Coincide thread from Claude Code to Codex, Cursor or another agent without starting over: the next agent gets a recap of what it missed.",
  name: "Switch agents mid-thread",
  summary: "Hand a conversation to another agent; it gets a recap of the turns it missed and works in the same folder.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Switch agents in the middle of a thread",
  lede: "Start a task with one agent and finish it with another. Coincide keeps a native session for each agent in the thread and tells the next one exactly what it missed, so nothing has to be pasted or explained twice.",
  related: ["/features/model-picker", "/features/composer", "/agents", "/features/git"],
  body: (s) => `
<h2>How to switch</h2>
<p>Every thread runs one agent at a time, and you can change it before any message:</p>
<ul>
  <li><strong>Type a slash command.</strong> In the composer, <code>/claude</code>, <code>/codex</code>, <code>/cursor</code>, <code>/grok</code>, <code>/opencode</code> or <code>/antigravity</code> continues the thread with that agent. The list only offers agents that are installed, signed in and turned on.</li>
  <li><strong>Pick a model from another agent.</strong> Choose Agent and Model… (${kbd("⇧", "⌘", "M")}, or <code>/model</code>) opens ${s.link("/features/model-picker", "the model picker")}, which has a tab for every agent. Choosing any model there moves the thread to its agent.</li>
  <li><strong>Use the command palette.</strong> ${kbd("⌘", "K")} lists “Switch to Codex” and the like for every ready agent.</li>
</ul>
<p>With a slash command, Coincide picks the model that agent last used in this thread, or its first model, and the account it last ran with there, as long as that account is still ready.</p>

<h2>What the next agent receives</h2>
<p>Agents don’t share memory, so Coincide writes a handoff. When you send the first message after a switch, the new agent gets a recap of the turns it didn’t see, inside a <code>&lt;conversation_handoff&gt;</code> block, followed by your message. The recap includes:</p>
<ul>
  <li>your messages, with the names of files you attached;</li>
  <li>other agents’ replies, labeled with the agent and model that wrote them;</li>
  <li>their tool calls with their status, plus a trimmed tail of command output;</li>
  <li>plans they proposed, errors, and questions they asked you with your answers.</li>
</ul>
<p>Reasoning, approval prompts and notices are left out. The recap tells the agent that the earlier work happened in the same working directory and that files on disk already reflect it, and that everything inside the block is a record of earlier turns, not new instructions. The recap is capped at about 24,000 characters: when a thread is longer, the most recent entries are kept, and a note says how many earlier ones were left out.</p>

<h2>Each agent keeps its own session</h2>
<p>Switching doesn’t throw anything away. Each agent keeps its native session for the thread (a Claude Code conversation, a Codex thread, an OpenCode session and so on). Switch back to an agent you used earlier and it resumes that session and only hears about the turns since its last reply, not the whole thread again.</p>
${table(["Situation", "What the agent gets"], [
  ["First time an agent joins the thread", "The conversation so far, as a recap"],
  ["Returning to an agent", "Its own session, plus a recap of only what it missed"],
  ["Same agent, next message", "Just your message; its session is current"],
  ["Its saved session can’t be resumed", "A new session with a recap of the whole thread, and a notice in the thread"],
])}

<h2>Same folder, same files</h2>
<p>All agents in a thread work in the thread’s folder: the project checkout or the thread’s ${s.link("/features/worktrees", "worktree")}. The diff panel and ${s.link("/features/git", "per-turn checkpoints")} cover every agent’s turns, and the transcript’s agent rail changes color where a turn went to a different agent, so you can see who did what.</p>

<h2>Things to know</h2>
<ul>
  <li>Switching takes effect with the next message. A turn that’s running finishes with the agent that started it.</li>
  <li>Plan or build mode, access (full access or approvals) and the thread’s follow-up behavior carry over, but each agent applies them its own way. See ${s.link("/features/plan-mode")} and ${s.link("/features/approvals")}.</li>
  <li>A recap is text. The next agent reads what happened; it doesn’t inherit another agent’s tools, memory files or settings.</li>
  <li>Forking a thread or editing an earlier message drops the native sessions, so the next agent gets a full recap of the remaining conversation.</li>
  <li>You need each agent installed and signed in through its own CLI. The ${s.link("/agents", "agent pages")} cover setup.</li>
</ul>
`,
};
