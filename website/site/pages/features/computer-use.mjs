import { table } from "../../layout.mjs";

export default {
  path: "/features/computer-use",
  title: "Computer Use: let coding agents use Mac apps · Coincide",
  description: "Turn on Computer Use in Coincide and any agent can see and operate native Mac apps through a bundled Cua Driver helper, with its own cursor. No MCP setup.",
  name: "Computer Use",
  summary: "Agents see and operate native Mac apps through a bundled helper, with their own cursor. Off by default.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Computer Use",
  lede: "With Computer Use on, an agent in any thread can list your Mac’s apps and windows, read a window’s controls, click, type, scroll and take screenshots. It works the same for every agent Coincide runs, and it’s off until you turn it on.",
  related: ["/features/browser", "/features/appshots", "/docs/macos-permissions"],
  body: (s) => `
<h2 id="turn-on">Turn it on</h2>
<ol>
  <li>Open Settings › Computer Use and turn on “Allow agents to use this Mac”.</li>
  <li>Grant the permissions the pane lists, Accessibility and Screen Recording, with its Grant Access and Open System Settings buttons, then come back to refresh their status.</li>
  <li>Ask an agent to do something in a Mac app, for example “Open Notes, start a note called Groceries with today’s list, and show me a screenshot.”</li>
</ol>
<p>The permissions belong to Coincide itself, because Coincide runs the helper as its own child process. You grant them once, not once per agent, and you don’t have to set up an MCP server for any agent: every thread reaches Computer Use through a private connection Coincide gives it.</p>

<h2 id="how">How it works</h2>
<p>Coincide bundles <a href="https://github.com/trycua/cua">Cua Driver</a>, an open-source helper made by Cua AI (MIT license), and starts it only when an agent needs it. After about two idle minutes, or soon after every thread is done with it, the helper stops; the next request starts it again.</p>
<p>Coincide passes agents only a fixed set of the helper’s tools:</p>
${table(["Kind", "Tools"], [
    ["Look", "list apps and windows, read a window’s state and the desktop, verify a result, zoom into part of a screenshot"],
    ["Act", "click, double-click, right-click, set a control’s value, type text, press keys and shortcuts, scroll, drag, move the cursor, use a menu item, launch an app, move or resize a window, run several steps in a row"],
  ])}
<p>Browser control, arbitrary scripts, installing things and changing the helper’s own configuration aren’t available through Coincide. For websites, agents use the thread’s ${s.link("/features/browser", "Coincide browser")} instead.</p>

<h3 id="cursor">The agent’s cursor</h3>
<p>With “Show agent cursor” on (the default), Coincide draws a cursor where the agent clicks and types, on whichever display it’s working on, so you can watch without losing your own pointer. Agents are told to work in the background where an app allows it, and to use foreground actions, which do move focus on your screen, only for the task you asked for.</p>

<h3 id="one-thread">One thread at a time</h3>
<p>Several threads can have Computer Use, but only one controls the desktop at a time. Another thread that wants it waits until the first releases it. Settings › Computer Use › Activity shows which threads are using the Mac, with Stop Computer Use and Restart Computer Use buttons.</p>

<h2 id="privacy">Privacy</h2>
<ul>
  <li>Screenshots and window contents an agent reads go to that agent’s provider, as part of the conversation.</li>
  <li>Cua Driver normally sends content-free telemetry to Cua AI and checks online for newer versions of itself. Coincide switches both off every time it starts the helper, so the helper sends nothing to Cua AI. It’s updated only when Coincide is.</li>
  <li>The private connection is limited to its thread and carries a short-lived credential.</li>
</ul>
<p>The <a href="/privacy">privacy policy</a> has the exact settings Coincide uses.</p>

<h2 id="safely">Using it safely</h2>
<ul>
  <li><strong>Turn it on for the job, off afterwards.</strong> Turning Computer Use off ends every agent’s access at once, and it also stops when Coincide quits.</li>
  <li><strong>Close what you don’t want seen.</strong> An agent may take screenshots of any window it works with. Close private documents and messages first.</li>
  <li><strong>Prefer approvals.</strong> Run threads that use Computer Use with ${s.link("/features/approvals", "Ask for approval")} rather than full access when the task touches anything important.</li>
  <li><strong>Treat screens as untrusted.</strong> Agents are told that window text and screenshots are content, not instructions, but a page or document can still try to mislead an agent. Watch what it does with the agent cursor on.</li>
  <li><strong>Stay nearby.</strong> Actions can change files, settings and messages in real apps, and there’s no undo for what another app does.</li>
</ul>

<h2 id="limits">Limitations</h2>
<ul>
  <li>Computer Use runs only while Coincide is open, unlike agent turns, which ${s.link("/features/background-agents", "keep running in the background")}.</li>
  <li>Agents act on what the helper can see through Accessibility and screenshots; apps that expose little to Accessibility are harder to operate.</li>
</ul>
`,
};
