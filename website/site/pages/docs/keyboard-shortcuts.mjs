import { kbd, table } from "../../layout.mjs";

const none = '<span class="note">none</span>';

export default {
  path: "/docs/keyboard-shortcuts",
  title: "Keyboard shortcuts · Coincide",
  description: "Every keyboard shortcut in Coincide: menu commands, the composer, sidebar, conversation, terminal and command palette, and how to change them.",
  name: "Keyboard shortcuts",
  summary: "Every default shortcut, the keys each part of the window handles, and how to record your own in Settings › Keyboard.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "Keyboard shortcuts",
  lede: "These are Coincide’s default shortcuts. The menu commands in the first section below can each get a shortcut of your own in Settings › Keyboard, which also lists the keys below and warns you about clashes.",
  related: ["/features/command-palette", "/features/composer", "/features/terminal", "/docs/settings"],
  body: (s) => `
<nav class="toc" aria-label="On this page"><p>On this page</p><ol>
  <li><a href="#commands">Menu commands you can change</a></li>
  <li><a href="#composer">Composer</a></li>
  <li><a href="#sidebar">Sidebar and conversation</a></li>
  <li><a href="#terminal">Terminal</a></li>
  <li><a href="#palette">Command palette</a></li>
  <li><a href="#fixed">Fixed menu shortcuts</a></li>
  <li><a href="#elsewhere">Shortcuts set elsewhere</a></li>
  <li><a href="#customize">Changing shortcuts</a></li>
</ol></nav>

<h2 id="commands">Menu commands you can change</h2>
<p>These are the defaults. Commands marked “none” have no shortcut until you give them one.</p>
<h3>File</h3>
${table(["Command", "Shortcut"], [
  ["New Thread", kbd("⌘", "N")],
  ["New Chat", kbd("⇧", "⌘", "N")],
  ["Add Project…", kbd("⇧", "⌘", "O")],
  ["Open in Editor", kbd("⌘", "O")],
  ["Reveal in Finder", none],
])}
<p>Settings › General › New Threads › <strong>New Thread starts a chat</strong> makes ${kbd("⌘", "N")} start a chat without a project.</p>
<h3>Edit</h3>
${table(["Command", "Shortcut"], [
  ["Add Selection to Composer (quotes a reply, takes terminal output or comments on diff lines, whichever has focus)", kbd("⌘", "L")],
  ["Find › Search Threads", kbd("⌥", "⌘", "F")],
])}
<h3>View</h3>
${table(["Command", "Shortcut"], [
  ["Show or Hide Sidebar", kbd("⌘", "B")],
  ["Show or Hide Terminal", kbd("⌘", "J")],
  ["Show or Hide Diff", kbd("⌘", "D")],
  ["Show or Hide Scheduled Tasks", kbd("⌥", "⌘", "S")],
  ["Archived Threads…", kbd("⌥", "⌘", "A")],
  ["Command Palette…", kbd("⌘", "K")],
  ["Increase Font Size", `${kbd("⌘", "+")} (also ${kbd("⌘", "=")})`],
  ["Decrease Font Size", kbd("⌘", "−")],
  ["Reset Font Size", kbd("⌘", "0")],
])}
<h3>Thread</h3>
${table(["Command", "Shortcut"], [
  ["Stop", kbd("⌘", ".")],
  ["Previous Thread / Next Thread", `${kbd("⇧", "⌘", "[")} / ${kbd("⇧", "⌘", "]")}`],
  ["Go to Thread 1–9 (the numbered threads in the sidebar)", `${kbd("⌘", "1")} … ${kbd("⌘", "9")}`],
  ["Choose Agent and Model…", kbd("⇧", "⌘", "M")],
  ["Reasoning Effort…", kbd("⇧", "⌘", "E")],
  ["Access…", kbd("⇧", "⌘", "A")],
  ["Plan Mode", `${none} in the menu; ${kbd("⇧", "⇥")} in the composer`],
  ["Rename…", kbd("⌘", "R")],
  ["Pin or Unpin Thread", kbd("⇧", "⌘", "P")],
  ["Archive or Unarchive Thread", kbd("⌘", "W")],
  ["Copy Path", none],
  ["Delete Thread…", none],
])}
<p>In the main window ${kbd("⌘", "W")} archives the open thread, where you can bring it back from Archived Threads; File › Close Window is ${kbd("⇧", "⌘", "W")}. Other windows still close with ${kbd("⌘", "W")}.</p>
<h3>Help</h3>
${table(["Command", "Shortcut"], [
  ["Report an Issue… (opens GitHub’s bug report form)", none],
  ["Request a Feature…", none],
])}

<h2 id="composer">Composer</h2>
<p>The composer’s keys follow two settings in Settings › General › Chat: <strong>Send messages with</strong> (Return, the default, or Command-Return) and <strong>Follow-up behavior</strong> (Steer, the default, Queue or Interrupt). With the defaults:</p>
${table(["Keys", "What they do"], [
  [kbd("↩"), "Send the message, or steer the agent with it while it works"],
  [kbd("⌘", "↩"), "Queue the message for after the turn instead"],
  [kbd("⇧", "⌘", "↩"), "Send the first queued message into the current turn"],
  [kbd("⇧", "↩"), "Insert a new line"],
  [kbd("⇧", "⇥"), "Switch between Build and Plan"],
  [`${kbd("↑")} / ${kbd("↓")}`, "Earlier and later messages you sent"],
  [kbd("⌥", "↑"), "Edit the last queued message"],
  [kbd("⇥"), "Insert the highlighted file or command"],
  [kbd("⎋"), "Close file and command suggestions (and cancel dictation)"],
])}
<p>With <strong>Command-Return</strong>, ${kbd("⌘", "↩")} sends, ${kbd("⇧", "⌘", "↩")} does the other follow-up, and ${kbd("↩")} inserts a new line. With <strong>Queue</strong>, the roles of steering and queueing swap. Type <code>@</code> to mention a file and <code>/</code> for commands. Steering works with Claude Code, Codex and OpenCode; for the other agents a steered message waits in the queue.</p>

<h2 id="sidebar">Sidebar and conversation</h2>
${table(["Where", "Keys", "What they do"], [
  ["Sidebar", kbd("↩"), "Move to the composer"],
  ["Sidebar", kbd("⌫"), "Delete the thread"],
  ["Sidebar", `hold ${kbd("⌘")}`, "Show the thread numbers for Go to Thread"],
  ["Conversation", `${kbd("→")} / ${kbd("←")}`, "Expand or collapse the selected entry"],
  ["Conversation", `${kbd("Space")} or ${kbd("↩")}`, "Open or close the selected entry"],
  ["Conversation", kbd("⌘", "C"), "Copy the selected entry"],
  ["Conversation", kbd("⎋"), "Back to the composer (closes the find bar first)"],
  ["Conversation", kbd("⌘", "F"), "Find in the thread"],
  ["Conversation", `${kbd("⌘", "G")} / ${kbd("⇧", "⌘", "G")}`, "Next and previous match"],
])}
<p>Typing while the conversation has focus goes to the composer. ${kbd("⌘")}-clicking a web link opens it in the other browser: your default browser, or Coincide’s ${s.link("/features/browser", "browser panel")} if you set links to open outside.</p>

<h2 id="terminal">Terminal</h2>
<p>While a ${s.link("/features/terminal", "terminal")} has focus, these keys act on it instead of the menu commands they share:</p>
${table(["Keys", "What they do"], [
  [`${kbd("⌘", "T")} or ${kbd("⌘", "N")}`, "New terminal"],
  [kbd("⌘", "D"), "Split right"],
  [kbd("⇧", "⌘", "D"), "Split down"],
  [kbd("⌘", "W"), "Close terminal"],
  [kbd("⌘", "K"), "Clear"],
  [`${kbd("⇧", "⌘", "[")} / ${kbd("⇧", "⌘", "]")}`, "Previous and next terminal tab"],
  [`${kbd("⌥", "⌘", "←")} / ${kbd("⌥", "⌘", "→")}`, "Previous and next pane"],
  [`${kbd("⌘", "←")} / ${kbd("⌘", "→")}`, "Move to the start or end of the line"],
  [`${kbd("⌥", "←")} / ${kbd("⌥", "→")}`, "Move by word"],
  [`${kbd("⌘", "↑")} / ${kbd("⌘", "↓")}`, "Previous and next command (with the shell integration’s prompt marks)"],
  [kbd("⇧", "⌘", "L"), "Send the last command’s output to the agent"],
])}

<h2 id="palette">Command palette</h2>
${table(["Keys", "What they do"], [
  [kbd("⌘", "K"), "Open the palette"],
  [`${kbd("↑")} / ${kbd("↓")}`, "Choose a result"],
  [kbd("↩"), "Run the chosen result"],
  [kbd("⇥"), "Complete a folder path"],
  [kbd("⌫"), "Back to the previous list"],
  [kbd("⎋"), "Close"],
])}
<p>Start with <code>/</code> or <code>~</code> to add a folder as a project. More in ${s.link("/features/command-palette")}.</p>

<h2 id="fixed">Fixed menu shortcuts</h2>
<p>These belong to standard macOS menu items and can’t be changed in Coincide:</p>
${table(["Command", "Shortcut"], [
  ["Coincide › Settings…", kbd("⌘", ",")],
  ["Coincide › Hide Coincide / Hide Others", `${kbd("⌘", "H")} / ${kbd("⌥", "⌘", "H")}`],
  ["Coincide › Quit Coincide", `${kbd("⌘", "Q")} (hold it, or press it twice, while “Hold ⌘Q to quit” is on)`],
  ["File › Close Window", kbd("⇧", "⌘", "W")],
  ["Edit › Undo / Redo", `${kbd("⌘", "Z")} / ${kbd("⇧", "⌘", "Z")}`],
  ["Edit › Cut, Copy, Paste, Select All", `${kbd("⌘", "X")}, ${kbd("⌘", "C")}, ${kbd("⌘", "V")}, ${kbd("⌘", "A")}`],
  ["Edit › Paste and Match Style", kbd("⌥", "⇧", "⌘", "V")],
  ["Edit › Find › Find…, Find Next, Find Previous", `${kbd("⌘", "F")}, ${kbd("⌘", "G")}, ${kbd("⇧", "⌘", "G")}`],
  ["Edit › Find › Use Selection for Find", kbd("⌘", "E")],
  ["Edit › Spelling and Grammar › Check Document Now", kbd("⌘", ";")],
  ["View › Show Toolbar", kbd("⌥", "⌘", "T")],
  ["View › Enter Full Screen", kbd("⌃", "⌘", "F")],
  ["Window › Minimize", kbd("⌘", "M")],
])}
<p>Undo and Redo also apply to inbox actions on whole groups of threads (archiving, unarchiving or deleting several at once) during the current session.</p>

<h2 id="elsewhere">Shortcuts set elsewhere</h2>
<ul>
  <li><strong>Appshots</strong>: press the left and right ${kbd("⌘")} keys together in any app, or record your own shortcut, in Settings › Appshots. See ${s.link("/features/appshots")}.</li>
  <li><strong>Dictation</strong>: off by default. Turn on a keyboard shortcut in Settings › Voice: a key with ${kbd("⌘")}, ${kbd("⌃")} or ${kbd("⌥")}, one modifier pressed on its own, or the 🌐 fn key, held or tapped. It works while a Coincide window is in front. See ${s.link("/features/dictation")}.</li>
</ul>

<h2 id="customize">Changing shortcuts</h2>
<ol>
  <li>Open Settings › Keyboard. Filter by a command’s name or keys, or turn on <strong>Show only conflicts</strong>.</li>
  <li>Click a command’s shortcut and type the new one. Escape cancels; Delete removes the shortcut. Shortcuts need ${kbd("⌘")} or ${kbd("⌃")}, so they never take keys away from text fields.</li>
  <li>Read the notes under the row. Coincide tells you when a shortcut is “Also assigned to” another command, when macOS uses it, when it would take a key from the composer, or when a standard menu item keeps it (then your command gets no shortcut). It also notes keys a focused terminal keeps for itself.</li>
</ol>
<p><strong>Reset All…</strong> puts every menu command back to its default. App Shortcuts you add for Coincide in System Settings › Keyboard › Keyboard Shortcuts take priority over Coincide’s own; the pane links there with <strong>Open Keyboard Settings…</strong>.</p>
`,
};
