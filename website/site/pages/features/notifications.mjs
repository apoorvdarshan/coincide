import { table } from "../../layout.mjs";

export default {
  path: "/features/notifications",
  title: "Notifications when agents finish or need you · Coincide",
  description: "Coincide notifies you when a coding agent finishes, fails, needs approval or has a question, sends each alert to one device only and clears it once seen.",
  name: "Notifications",
  summary: "Hear when an agent finishes, fails, needs approval or asks a question, on the one device you’re using.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Notifications that know where you are",
  lede: "Agents take minutes, and you’ll be doing something else. Coincide tells you when a turn is done or an agent is waiting on you, and once you’ve seen the thread, the alert goes away.",
  related: ["/features/background-agents", "/features/approvals", "/features/coincide-remote", "/features/browser"],
  body: (s) => `
<h2>What you’re told about</h2>
<p>With Settings › General › Notifications › “Notify when Coincide is in the background” on (the default), Coincide posts a macOS notification for these events, unless you’re already looking at that thread:</p>
${table(["Notification", "When"], [
  ["<em>Agent</em> finished", "A turn ends. The notification shows the opening line of the agent’s reply."],
  ["<em>Agent</em> failed", "A turn ends with an error, with the error’s text."],
  ["<em>Agent</em> needs approval", "An agent in a thread set to Ask for approval wants to run a command or edit a file."],
  ["<em>Agent</em> has a question", "An agent stopped to ask you something."],
  ["Your turn in the browser", "An agent working in the thread’s browser needs you to sign in, pass a check or enter a code."],
  ["<em>Agent</em> is waiting to start", "An agent is slow to start, which usually means macOS is asking for permission to access a folder and needs you at the Mac."],
])}
<p>Each notification is titled with the thread’s name, says what happened and in which project, and plays the default sound. Clicking it opens the thread, with its browser for a browser request. Archived threads don’t notify.</p>
<p>macOS asks for permission the first time a notification is due, not at launch. If notifications are turned off for Coincide in System Settings › Notifications, the setting says so.</p>

<h2>The Dock badge</h2>
<p>Coincide’s Dock icon shows how many approvals are waiting across all threads, so a glance tells you whether any agent is blocked on you. Answer them in each thread; see ${s.link("/features/approvals")}.</p>

<h2>Even with Coincide closed</h2>
<p>When you quit Coincide while agents are still working, the ${s.link("/features/background-agents", "background agent host")} keeps them running and posts the same finished, failed, approval and question notifications itself. Clicking one opens Coincide on that thread.</p>

<h2>One device at a time</h2>
<p>Coincide sends each event to exactly one place, so you don’t get the same alert on your Mac and your phone:</p>
<ul>
  <li>If you’re using the Mac (any input in the last two minutes, screen unlocked and awake), the Mac gets it, even with a phone in front of you.</li>
  <li>If the Mac is idle, locked or asleep and you’re using ${s.link("/features/coincide-remote", "Coincide Remote")} on an iPhone or iPad, the alert appears there instead.</li>
  <li>If neither is in use, a phone that turned on lock-screen alerts and was used in the last four hours gets one on its lock screen, through your own iCloud account; otherwise the Mac does.</li>
  <li>The device that would show an alert stays quiet when the thread is already open on its screen.</li>
</ul>
<p class="note">Coincide Remote is coming soon to the App Store. Until it’s out, notifications go to your Mac. Lock-screen alerts also need a Mac build signed for iCloud; see the ${s.link("/privacy", "privacy policy")} for what such an alert contains.</p>

<h2>Cleared once seen</h2>
<p>Opening a thread clears what was posted about it everywhere: notifications on the Mac, including ones the agent host posted while Coincide was closed, alerts in Coincide Remote and lock-screen alerts. You won’t come back to a stack of alerts for things you’ve already read.</p>

<h2>Turning them off</h2>
<p>Turn off “Notify when Coincide is in the background” in Settings › General, or manage Coincide in System Settings › Notifications to change banner style, sounds or Focus behavior. Notifications are ordinary local macOS notifications; nothing about them is sent to us.</p>
`,
};
