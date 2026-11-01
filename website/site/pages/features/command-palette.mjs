import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/command-palette",
  title: "⌘K command palette · Coincide",
  description: "Coincide’s ⌘K command palette finds threads, projects, settings and actions, switches agents and models, and searches files in the thread’s folder.",
  name: "Command palette",
  summary: "Press ⌘K to find threads, run actions, switch agents and models, open files and search your project’s text.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "The ⌘K command palette",
  lede: "Press ⌘K anywhere in Coincide’s window and type. The palette searches actions, threads, projects and settings together, and you never have to leave the keyboard.",
  related: ["/docs/keyboard-shortcuts", "/features/projects-and-threads", "/features/model-picker", "/features/switch-agents"],
  body: (s) => `
<h2>Opening and moving around</h2>
<p>View › Command Palette… opens it, with ${kbd("⌘", "K")} by default (you can change the shortcut in Settings › Keyboard). It floats over the main window, never over other apps, and closes when you press Escape or click elsewhere. Arrow keys move through the results and Return runs one. Some items open a nested list; Escape steps back out of it before closing the palette.</p>

<h2>What it lists</h2>
<p>Before you type, it shows the most useful actions, your recent threads, and more actions below them. As you type, results are grouped into Actions, Threads, Projects and Settings, and the best-matching group comes first.</p>
${table(["What", "Examples"], [
  ["Actions", "New Thread in a project, New Chat, New Bot…, Talk to a bot, Add Project…, Open in your editor, Show or Hide Terminal, Diff, Pull Requests or Browser Preview, Find in Thread…, Stop Agent, Pin, Rename or Archive Thread, Schedule a Message in This Thread…, Edit Instructions, Dictate, Change Appearance…, Refresh Agents, Open Settings"],
  ["Composer controls", "Choose Agent and Model…, Choose Reasoning Effort…, Choose Access…, Switch to Plan Mode or Build Mode, and Switch to each other ready agent"],
  ["Threads", "Every thread and chat, by title, with its branch and project counting a little toward the match"],
  ["Projects", "Every project, found by name or path; the New Thread in… list starts a thread in one"],
  ["Settings", "General, Agent, Model, Voice and Keyboard settings, Global Instructions and About Coincide, found by keywords such as “whisper” or “keybindings”"],
])}
<p>Actions show their keyboard shortcut on the right, using yours if you changed it, so the palette is also a way to learn them.</p>

<h2>Files and text in the thread’s folder</h2>
<p>With a thread open, two nested lists work on its folder (its ${s.link("/features/worktrees", "worktree")} or the project):</p>
<ul>
  <li><strong>Go to File…</strong> finds files by name and opens the one you pick in the editor you chose for Open In.</li>
  <li><strong>Search in Project…</strong> finds text in the folder’s files, a few lines per file, and opens the file at the matching line when the editor supports it. It uses ripgrep when it’s installed with Homebrew, and <code>grep</code> otherwise, skipping <code>.git</code> and <code>node_modules</code>.</li>
</ul>

<h2>Adding a project by path</h2>
<p>Type a path that starts with <code>/</code> or <code>~</code> and the palette lists folders there. Tab completes a folder so you can keep browsing, and choosing one adds it as a project.</p>

<h2>How matching works</h2>
<p>The palette’s search is forgiving but not vague:</p>
<ul>
  <li>Every word you type must start a word somewhere, so “sid” finds “Fix sidebar”.</li>
  <li>Words typed together still match, so “vscode” finds “VS Code”.</li>
  <li>When nothing matches exactly, one typo is allowed.</li>
  <li>A match inside a word needs at least four letters and only counts in titles, so “del” doesn’t find “model”.</li>
  <li>Case and accents are ignored, and among equally good matches, threads you used recently rank higher.</li>
</ul>

<h2>Palette or sidebar search?</h2>
<p>The palette matches names: thread titles, projects, commands and settings. To find a thread by something said in it, use the sidebar’s search (${kbd("⌥", "⌘", "F")}), which also looks through messages; inside a thread, ${kbd("⌘", "F")} finds text in the transcript. See ${s.link("/features/projects-and-threads")} and the full ${s.link("/docs/keyboard-shortcuts", "list of shortcuts")}.</p>
`,
};
