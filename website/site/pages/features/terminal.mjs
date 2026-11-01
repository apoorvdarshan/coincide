import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/terminal",
  title: "An integrated terminal in every thread · Coincide",
  description: "Each Coincide thread has its own terminal in the thread’s folder, with tabs, split panes, shell integration and one key to send output to the agent.",
  name: "Integrated terminal",
  summary: "A terminal per thread in its folder or worktree, with tabs, up to four panes, and a key to send output to the agent.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "A terminal in every thread",
  lede: "Run the dev server, the tests or a quick git command without leaving the conversation. Every thread has its own terminals, opened in the thread’s folder, and they keep running while you look at other threads.",
  related: ["/features/worktrees", "/features/composer", "/docs/keyboard-shortcuts", "/features/git"],
  body: (s) => `
<h2>Opening it</h2>
<p>View › Show Terminal (${kbd("⌘", "J")}) shows or hides the thread’s terminal; the first one starts on demand. Settings › General › Terminal places it in a <strong>Bottom panel</strong> below the chat, with its button in the rail on the left, or a <strong>Right panel</strong> beside the diff and browser preview, with its button among theirs at the top right.</p>
<p>A new terminal starts your login shell in the thread’s folder: its ${s.link("/features/worktrees", "worktree")}, or the project folder, or the nearest folder that still exists if that one was moved. It gets your login shell’s environment, minus the variables describing whatever terminal Coincide itself was started from.</p>

<h2>Tabs and panes</h2>
<p>The slim header above the terminal has the thread’s tabs and a new-tab button on the left, and the working directory, split buttons and hide on the right. A tab can hold up to four shells, side by side or stacked. Shells keep running while their thread is off screen, until you close them, delete the thread or quit Coincide.</p>
<p>A program that reports progress the way <code>brew</code> and <code>cargo</code> do (the OSC 9;4 sequence) shows a progress bar on its tab.</p>

<h2>Keys in a focused terminal</h2>
${table(["Keys", "Action"], [
  [kbd("⌘", "T") + " or " + kbd("⌘", "N"), "New terminal"],
  [kbd("⌘", "D") + " / " + kbd("⇧", "⌘", "D"), "Split right / split down"],
  [kbd("⌘", "W"), "Close terminal"],
  [kbd("⌘", "K"), "Clear"],
  [kbd("⇧", "⌘", "[") + " / " + kbd("⇧", "⌘", "]"), "Previous / next terminal tab"],
  [kbd("⌥", "⌘", "←") + " / " + kbd("⌥", "⌘", "→"), "Previous / next pane"],
  [kbd("⌘", "←") + " / " + kbd("⌘", "→"), "Start / end of the line"],
  [kbd("⌥", "←") + " / " + kbd("⌥", "→"), "Move by word"],
  [kbd("⌘", "↑") + " / " + kbd("⌘", "↓"), "Previous / next command"],
  [kbd("⇧", "⌘", "L"), "Send the last command’s output to the agent"],
])}
<p>While the terminal has focus it keeps these keys for itself, so ${kbd("⌘", "K")} clears the terminal rather than opening the ${s.link("/features/command-palette", "command palette")}, and ${kbd("⌘", "W")} closes a shell instead of archiving the thread. The full list is in ${s.link("/docs/keyboard-shortcuts")}.</p>

<h2>Handing output to the agent</h2>
<p>Coincide’s shell integration marks prompts and commands, for zsh and bash, so it knows where the last command’s output starts and ends. ${kbd("⇧", "⌘", "L")} attaches that output to the composer as a card, and selecting any text and pressing ${kbd("⌘", "L")} adds the selection. Either way the agent gets exactly the error you’re looking at. The integration loads through its own startup files and never edits your dotfiles; if it can’t be set up, the shell starts as usual.</p>

<h2>Project scripts</h2>
<p>Commands a project runs often, such as its dev server or tests, can be saved as project scripts. Running one opens it in a terminal of the thread, and the one you ran last becomes the toolbar’s one-click script. A script marked “Run when a thread gets a new worktree” runs on its own in each new worktree, for setup such as installing dependencies.</p>

<h2>Appearance</h2>
<p>The terminal follows Coincide’s light or dark theme. Settings › General has GPU rendering (Metal; turn it off to draw with the CPU) and Translucent terminal, which lets the desktop show through, blurred. The terminal is built on <a href="https://github.com/migueldeicaza/SwiftTerm">SwiftTerm</a>.</p>

<h2>Things to know</h2>
<ul>
  <li>This terminal is yours. Agents run their own commands through their own tools, and those appear in the thread’s work log, not here.</li>
  <li>Terminals don’t run in the background agent host, so they stop when Coincide quits, even though agents keep going (see ${s.link("/features/background-agents")}).</li>
</ul>
`,
};
