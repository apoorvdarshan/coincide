import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/plan-mode",
  title: "Plan mode for Claude Code, Codex and more · Coincide",
  description: "Put a Coincide thread in plan mode so the agent investigates and proposes a plan without editing files, then implement it in one click.",
  name: "Plan mode",
  summary: "Have the agent investigate and propose a plan without changing files, refine it, then implement it with one click.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Plan first, then build",
  lede: "In plan mode the agent reads, searches and asks questions, then returns a concrete plan instead of changing your code. You refine the plan in the same thread and start the work when it’s right.",
  related: ["/features/approvals", "/features/composer", "/features/switch-agents", "/agents/claude-code"],
  body: (s) => `
<h2>Turning it on</h2>
<p>Every thread is in either <strong>Build</strong> or <strong>Plan</strong> mode, shown on the mode button in the composer. To switch:</p>
<ul>
  <li>press ${kbd("⇧", "Tab")} in the composer;</li>
  <li>type <code>/plan</code>, or <code>/build</code> (also <code>/default</code>) to go back;</li>
  <li>use Thread › Plan Mode, or Switch to Plan Mode in the ${s.link("/features/command-palette", "command palette")}.</li>
</ul>
<p>A project can start its new threads in plan mode: set Mode in the project’s Project Defaults… (see ${s.link("/features/projects-and-threads")}).</p>

<h2>Working with the plan</h2>
<ol>
  <li>Describe what you want and send it. The agent investigates with read-only actions and may ask you questions, which you answer inline.</li>
  <li>When it proposes a plan, a <strong>Plan ready</strong> card appears above the composer with the plan itself. You can collapse it to a preview, open it in the transcript, copy it or hide it.</li>
  <li>To change the plan, just type: in plan mode a new message refines the plan rather than starting the work.</li>
  <li>When you’re happy, click <strong>Implement</strong>. Coincide switches the thread to build mode and asks the agent to implement the plan.</li>
</ol>
<p>Because the plan stays in the thread, you can also ${s.link("/features/switch-agents", "switch agents")} between planning and building: one agent plans, and another receives the plan in its recap and carries it out.</p>

<h2>How each agent plans</h2>
<p>Coincide uses each agent’s own plan mode where it has one, so the agent’s safeguards apply. Where it doesn’t, Coincide asks for a plan in the prompt.</p>
${table(["Agent", "How plan mode works"], [
  ["Claude Code", "Claude Code’s own plan permission mode. When Claude presents its plan, Coincide shows it and Claude waits for you. If Claude enters plan mode by itself during a build turn, you’re asked whether to <strong>Implement</strong> or <strong>Keep planning</strong>, with room to say what should change."],
  ["Codex", "Codex’s plan collaboration mode, with its plan tool."],
  ["Cursor", "Cursor’s own plan mode over the Agent Client Protocol; Cursor’s plans show in the card."],
  ["OpenCode", "OpenCode’s built-in plan agent, with a rule that denies file edits."],
  ["Grok Build", "Grok Build has no plan mode Coincide can select, so Coincide sends instructions with your message: investigate read-only, don’t edit files, return a concrete plan. Grok’s plan is captured when it finishes."],
  ["Antigravity", "Coincide sends the same plan instructions with your message, and switches Antigravity to a plan mode if its runtime offers one."],
])}

<h2>Limits to keep in mind</h2>
<ul>
  <li>For Grok Build and Antigravity, plan mode is a request in the prompt. A well-behaved agent follows it, but nothing technically stops an edit. If that matters, also choose Ask for approval so every command and edit needs your OK; see ${s.link("/features/approvals")}.</li>
  <li>Even with native plan modes, agents can still read files and run read-only commands, and what they read goes to their provider like any turn.</li>
  <li>Switching back to build mode returns the agent to the thread’s normal mode and access setting with the next message.</li>
  <li>The Implement button sends a short message (“Implement the plan.”) in build mode; you can instead switch with ${kbd("⇧", "Tab")} and write your own instructions.</li>
</ul>
`,
};
