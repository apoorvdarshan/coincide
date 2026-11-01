import { kbd, table } from "../../layout.mjs";

export default {
  path: "/features/projects-and-threads",
  title: "Projects, threads and chats for coding agents · Coincide",
  description: "Organize agent conversations by project in Coincide’s sidebar: search messages, pin, archive, snooze and settle threads, and set defaults per project.",
  name: "Projects and threads",
  summary: "A sidebar of projects, threads and chats with message search, pinning, archiving, snoozing and per-project defaults.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Projects, threads and chats",
  lede: "Coincide’s sidebar holds every conversation you have with every agent. Threads belong to a project folder, chats stand on their own, and the inbox tools keep a busy list manageable.",
  related: ["/features/command-palette", "/features/worktrees", "/features/bots", "/docs/keyboard-shortcuts"],
  body: (s) => `
<h2>Projects, threads and chats</h2>
<ul>
  <li><strong>A project</strong> is a folder on your Mac, usually a Git repository. Add one with File › Add Project… (${kbd("⇧", "⌘", "O")}). Its threads run agents in that folder, or in a ${s.link("/features/worktrees", "worktree")} of it.</li>
  <li><strong>A thread</strong> is one conversation in a project. File › New Thread (${kbd("⌘", "N")}) starts one in the current project, File › New Thread in Project picks another, and hovering a project’s row in the sidebar shows its own New Thread button.</li>
  <li><strong>A chat</strong> is a conversation without a project, listed under its own Chats heading. File › New Chat (${kbd("⇧", "⌘", "N")}) starts one. If you mostly use Coincide like a chat app, Settings › General › “New Thread starts a chat” makes ${kbd("⌘", "N")} start a chat.</li>
</ul>
<p>${s.link("/features/bots", "Bots")} have their own section at the top. A thread can move to another project with Move to Project in its context menu; its agents’ sessions in the old folder end, and running threads stay where they are.</p>

<h2>Finding a thread</h2>
<ul>
  <li><strong>Search.</strong> The sidebar’s search field (Edit › Find › Search Threads, ${kbd("⌥", "⌘", "F")}) matches thread titles and projects as you type, and after a short pause also searches every thread’s messages, showing the matching line.</li>
  <li><strong>Keyboard.</strong> ${kbd("⌘", "1")} to ${kbd("⌘", "9")} jump to the threads numbered in the sidebar (hold ${kbd("⌘")} to see the numbers), and ${kbd("⇧", "⌘", "[")} / ${kbd("⇧", "⌘", "]")} go to the previous or next thread.</li>
  <li><strong>The palette.</strong> ${s.link("/features/command-palette", "The command palette")} searches threads, projects and settings with typo tolerance.</li>
  <li><strong>Sorting.</strong> Projects, threads, chats and bots each have Sort By options (manual order, recent activity, name, and for threads date created), and Threads per Project can fit the list to the sidebar, show a fixed number or show all.</li>
</ul>

<h2>Keeping the list short</h2>
${table(["Action", "What it does", "How"], [
  ["Pin", "Keeps a thread at the top of its list", `Thread › Pin Thread, ${kbd("⇧", "⌘", "P")}`],
  ["Archive", "Moves a thread out of the sidebar, keeping its history", `Thread › Archive Thread, ${kbd("⌘", "W")}`],
  ["Snooze", "Hides a thread until In 1 Hour, In 3 Hours, This Evening, Tomorrow or Next Week; it comes back at the top", "Snooze in the thread’s context menu"],
  ["Settle", "Hides a quiet thread until new activity arrives in it", "Settle in the thread’s context menu"],
  ["Mark as Unread", "Puts the unread dot back", "The thread’s context menu"],
])}
<p>A snoozed or settled thread whose agent is working, or needs an approval or an answer, stays in view. The sidebar’s options menus have Show Archived Threads, Show Snoozed Threads and Show Settled Threads, and View › Archived Threads… (${kbd("⌥", "⌘", "A")}) and Settings › Archive list everything archived. Settings › General can ask before archiving or deleting a thread.</p>

<h2>Acting on several threads</h2>
<p>Select several threads in the sidebar (⌘-click or Shift-click) to archive or unarchive, settle or unsettle, move or delete them together. Undo and Redo (${kbd("⌘", "Z")}, ${kbd("⇧", "⌘", "Z")} or the Edit menu) take back a whole batch during the current app session. Undo restores the conversations and their checkpoints; it doesn’t restart an agent or terminal command that was stopped.</p>

<h2>Thread titles</h2>
<p>With Settings › General › “Name threads with the agent” on, the thread’s own agent titles it from your first message and its first reply, using its quickest model. “Keep titles up to date” lets the agent check the title every few turns while you use the thread. Rename a thread yourself with ${kbd("⌘", "R")}, and it keeps your name. Titling is a small request to the agent, so it counts toward that provider’s usage.</p>

<h2>Project defaults</h2>
<p>Project Defaults… in a project’s context menu sets the model, permissions (${s.link("/features/approvals", "full access or approvals")}) and mode (${s.link("/features/plan-mode", "plan or build")}) for new threads in that project. Turn on Use Global Defaults to follow Settings › General instead. Existing threads keep their own settings.</p>

<h2>Fast with long histories</h2>
<p>The sidebar loads from a small index, and a thread’s transcript is read only when you open it, so hundreds of threads don’t slow down launch. Everything is stored on your Mac; see ${s.link("/docs/data-storage")}.</p>
`,
};
