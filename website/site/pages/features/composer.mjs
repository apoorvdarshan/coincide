import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/composer",
  title: "Composer: attachments, @files and follow-ups · Coincide",
  description: "Write to any coding agent in Coincide with images and PDFs, @ file mentions, slash commands and quotes, and steer or queue messages while it works.",
  name: "Composer",
  summary: "Attachments, @ file mentions, slash commands, quotes and diff comments, and steering or queueing while an agent works.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "The composer",
  lede: "The composer is where you talk to whichever agent runs the thread. It takes files and images, mentions files in your project, runs commands, and decides what happens when you send while the agent is still working.",
  related: ["/features/model-picker", "/features/plan-mode", "/features/transcript", "/features/dictation"],
  body: (s) => `
<h2>Sending</h2>
<p>Settings › General › “Send messages with” chooses Return (Shift-Return adds a line) or Command-Return (Return adds a line). In an empty composer, the Up arrow brings back your earlier messages in the thread, and Down walks back to your draft. Each thread keeps its own draft, attachments included, when you switch threads or restart Coincide. ${kbd("⌘", ".")} stops the running turn.</p>

<h2>Attachments</h2>
<p>Paste or drop images into the composer, or click the attach button to choose images, PDFs or other files. Images are copied into Coincide’s attachments folder as PNG, JPEG, GIF or WebP, at most 2000 pixels on the long edge; click a thumbnail to see it in Quick Look. How the file reaches the agent depends on the agent:</p>
${table(["Agent", "Images", "Other files"], [
  ["Claude Code", "Sent inline (resized to fit Claude’s limits)", "PDFs are sent as documents, up to 100 pages or 20 MB; other files are named by path"],
  ["Codex", "Sent as local images, when the model accepts images", "Named by path"],
  ["Cursor", "Sent inline, or named by path if Cursor can’t take them", "Named by path"],
  ["Grok Build", "PNG, JPEG, GIF and WebP up to 10 MB, inline", "Named by path"],
  ["OpenCode", "Sent as file references with their path", "Named by path"],
  ["Antigravity", "PNG, JPEG, WebP and BMP", "Named by path"],
])}
<p>“Named by path” means the agent is told where the file is on your Mac and can open it with its own tools.</p>

<h2>Quotes, terminal output and diff comments</h2>
<p>Context you collect shows as cards beside the attachments:</p>
<ul>
  <li><strong>Quotes.</strong> Select text in a reply, plan or message and click <strong>Reply</strong>, or press ${kbd("⌘", "L")} (Edit › Add Selection to Composer).</li>
  <li><strong>Terminal output.</strong> Select text in the ${s.link("/features/terminal", "terminal")} and add it the same way, or press ${kbd("⇧", "⌘", "L")} in the terminal to send the last command’s output.</li>
  <li><strong>Diff comments.</strong> In the ${s.link("/features/git", "diff")}, select lines and choose Comment on Selected Lines… to tell the agent what to do about them.</li>
</ul>
<p>Cards stay attached through drafts and sending, and they’re included when another agent takes over the thread.</p>

<h2>Mentions and commands</h2>
${table(["Type", "What it offers"], [
  ["<code>@</code>", "Files and folders in the thread’s folder, from <code>git ls-files</code> (so <code>.gitignore</code> is respected) or a folder walk. Choosing a folder keeps the list open on its contents."],
  ["<code>/</code>", "Coincide’s commands: <code>/model</code>, <code>/plan</code>, <code>/build</code>, <code>/usage-limits</code> when the agent reports limits, and one per other ready agent, such as <code>/codex</code>. Below them, the current agent’s own slash commands."],
  ["<code>$</code>", "The current agent’s skills, when it reports any."],
  ["<code>#</code>", "Open pull requests of the repository on GitHub, mentioned as a link."],
])}
<p>Tab or Return chooses the highlighted suggestion and Escape closes the list. A message that is only a Coincide command, such as <code>/plan</code>, changes the thread instead of being sent.</p>

<h2>Sending while the agent works</h2>
<p>Each thread has a follow-up behavior, chosen in its composer (new threads start with the one in Settings › General):</p>
<ul>
  <li><strong>Steer</strong> sends your message into the running turn, so the agent adjusts course without stopping. Claude Code, Codex and OpenCode support this.</li>
  <li><strong>Queue</strong> holds the message until the turn ends. Queued messages show in a card where you can send one now, edit it or remove it.</li>
  <li><strong>Interrupt</strong> stops the turn and sends your message next.</li>
</ul>
<p>The alternate send does the other thing for one message: ${kbd("⌘", "↩")} (or ${kbd("⇧", "⌘", "↩")} when Command-Return sends), or ⌘-click on the send button. For Cursor, Grok Build and Antigravity, which can’t take a message mid-turn, Steer is shown but queues instead.</p>

<h2>The composer’s controls</h2>
<p>Under the text are the thread’s settings: ${s.link("/features/model-picker", "agent and model")}, reasoning effort, speed where offered, ${s.link("/features/approvals", "access")}, and ${s.link("/features/plan-mode", "plan or build")} mode. On the right are attach, the microphone for ${s.link("/features/dictation", "dictation")}, a meter of your plan’s ${s.link("/features/usage-dashboard", "usage limits")} for agents that report them, and a context-window meter showing how full the conversation is.</p>
`,
};
