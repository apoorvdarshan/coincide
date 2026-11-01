import { table } from "../../layout.mjs";

export default {
  path: "/features/background-agents",
  title: "Agents keep running after you quit · Coincide",
  description: "Coincide runs coding agents in a background host, so quitting, updating or a crash doesn’t stop a turn. Reopen it and the reply is still streaming.",
  name: "Background agents",
  summary: "A background agent host keeps every turn running when you quit, update or crash Coincide.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Agents outlive the app",
  lede: "Long agent turns shouldn’t depend on a window staying open. Coincide runs its agents in a small background process, the agent host, so you can quit Coincide, install an update or recover from a crash while an agent keeps working.",
  related: ["/features/keep-awake", "/features/notifications", "/docs/updating", "/features/scheduled-tasks"],
  body: (s) => `
<h2>How it works</h2>
<p>The agent host is a helper inside Coincide.app that macOS starts on demand as a LaunchAgent (<code>com.apoorvdarshan.coincide.agent-host</code>). It owns the agent processes for every agent, Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity alike, and keeps a log of their events. The app talks to it over a private connection on your Mac.</p>
<ul>
  <li><strong>When you quit,</strong> the app detaches. Turns go on, subagents and long commands included, and the host keeps logging.</li>
  <li><strong>When you reopen Coincide,</strong> it attaches to every session the host is still running and replays what happened while it was closed, so a reply that was streaming is still streaming.</li>
  <li><strong>When nothing is running,</strong> no turn, no approval or question waiting, no background work, the host exits on its own. It never ends a running turn silently; if it ever crashes, the thread says “The agent host stopped unexpectedly”.</li>
</ul>
<p>Each session is locked to the one process that runs it, so an agent is never started twice for the same thread, even across a relaunch.</p>

<h2>Turning it on</h2>
<p>It’s on by default: Settings › General › Agents › “Keep agents running when Coincide quits”. macOS has to allow it once. If Coincide is turned off under <em>Allow in the Background</em> in System Settings’ Login Items, Settings shows a notice with an <strong>Open Login Items…</strong> button; turn Coincide on there.</p>
<p>The same section has “Close idle agents after”, which shuts down agent processes that have been idle for a while to free memory. Threads pick up where they left off on their next message.</p>

<h2>Updates without interruptions</h2>
<p>An update replaces Coincide.app while agents may still be running. The host runs from its own copy of its files, so an update never changes a running host, and macOS keeps trusting its signature:</p>
<ul>
  <li>If the new version speaks the same protocol, it adopts the running host’s sessions and asks it to exit once idle.</li>
  <li>If not, the old host’s agents finish there, new sessions run in the app meanwhile, and Coincide switches to the new host once the old one is gone.</li>
</ul>
<p>See ${s.link("/docs/updating")} for how updates are downloaded and installed.</p>

<h2>When agents run in the app instead</h2>
${table(["Situation", "What happens"], [
  ["The setting is off", "Agents run inside Coincide and stop when it quits."],
  ["Coincide isn’t allowed in Login Items", "Same, until you allow it."],
  ["The host doesn’t answer", "A new turn waits a few seconds, then starts in the app. Coincide keeps trying to reach the host in the background."],
  ["A build without a Developer ID signature, or a development build", "The host needs a signed build, so agents run in the app."],
])}
<p>Settings › General › Agents shows which of these applies. Quitting asks first when agents running in the app would stop.</p>

<h2>Things to know</h2>
<ul>
  <li>The host keeps agents running while your Mac is awake. A MacBook that sleeps pauses them; ${s.link("/features/keep-awake")} can keep it awake on long jobs, even with the lid closed.</li>
  <li>${s.link("/features/terminal", "Terminals")} and the browser belong to the app, so they stop when Coincide quits.</li>
  <li>${s.link("/features/scheduled-tasks", "Scheduled tasks")} start only while Coincide is open; a run they start keeps going after you quit, like any turn.</li>
  <li>While Coincide is closed, the agent host posts the ${s.link("/features/notifications", "notifications")} itself, when a turn finishes or fails or an agent needs approval or an answer, if notifications are on. Clicking one opens Coincide.</li>
  <li>The host runs only on your Mac and talks only to the app and the agents; it sends nothing anywhere else (see the ${s.link("/privacy", "privacy policy")}).</li>
</ul>
`,
};
