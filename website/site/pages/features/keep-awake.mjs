import { code, table } from "../../layout.mjs";

export default {
  path: "/features/keep-awake",
  title: "Keep a MacBook awake for agents, lid closed · Coincide",
  description: "Keep Awake keeps your MacBook running coding agents around the clock, lid closed included, and puts your exact sleep settings back when you turn it off.",
  name: "Keep Awake",
  summary: "Keep a MacBook running agents 24/7 with the lid closed, and restore your sleep settings afterwards.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Keep Awake",
  lede: "Long agent runs and overnight schedules need a Mac that doesn’t go to sleep, even with the lid closed. Keep Awake, in Settings › General, sets that up with one switch, and puts your exact sleep settings back when you turn it off.",
  related: ["/features/background-agents", "/features/scheduled-tasks", "/docs/uninstall", "/docs/macos-permissions"],
  body: (s) => `
<h2 id="turn-on">Turn it on</h2>
<ol>
  <li>Open Settings › General › Keep Awake and turn on “Keep this Mac awake 24/7”.</li>
  <li>Enter your password when macOS asks. Coincide needs it to change the Mac’s power settings with <code>pmset</code>.</li>
  <li>If the pane says so, allow Coincide in Login Items (its Open Login Items… button takes you there), so the lid watcher can run.</li>
</ol>
<p>From then on the Mac never sleeps, closing the lid included, and the display turns off when the lid closes. The pane shows the current state, for example “This Mac stays awake, lid closed too”, and whether the lid watcher is running.</p>

<h2 id="what-changes">What it changes</h2>
<p>Turning it on runs the equivalent of these two commands, after reading your current settings:</p>
${code(`
pmset -c sleep 0          # never idle-sleep on the charger
pmset -a disablesleep 1   # nothing sleeps the system, lid closed included
`)}
<p>Turning it off asks for your password once more and puts back the exact sleep settings from before. While sleep is disabled, Apple menu › Sleep does nothing.</p>
<p>A small lid watcher, started by launchd at login while Keep Awake is on, follows the Mac’s lid notifications (it doesn’t poll) to handle the display and sound options below.</p>

<h2 id="options">Options</h2>
${table(["Option", "Default", "What it does"], [
    ["Turn the display off when the lid closes", "On", "macOS stops doing this once sleep is disabled, so Coincide does it."],
    ["Keep displays off while the lid is closed", "Off", "If a keyboard or mouse wakes an external display, it goes dark again within two seconds."],
    ["Mute sound while the lid is closed", "Off", "Your earlier mute setting comes back when you open the lid."],
    ["Sleep normally on battery", "Off", "Stay awake only on the charger; on battery the Mac sleeps as usual, closing the lid included."],
  ])}

<h3 id="battery">Sleep normally on battery</h3>
<p><code>pmset disablesleep</code> covers every power source, and only an administrator can change it. So “Sleep normally on battery” adds a small battery helper: a launchd daemon that runs as root, which you allow once in Login Items. It takes no input and only switches that one setting when you plug the Mac in or unplug it. It’s registered only while this option and Keep Awake are both on. Until you allow it, the Mac stays awake on battery too.</p>

<h2 id="care">Before you rely on it</h2>
<ul>
  <li><strong>Keep it plugged in.</strong> Without “Sleep normally on battery”, a Mac on battery keeps running until the battery is empty.</li>
  <li><strong>Give it airflow.</strong> A closed MacBook working hard still needs to shed heat; don’t leave it in a bag.</li>
  <li><strong>Turn Keep Awake off before you delete Coincide.</strong> That’s what puts your sleep settings back. ${s.link("/docs/uninstall", "Uninstalling Coincide")} has the full steps.</li>
</ul>

<h2 id="why">Why it pairs with background agents</h2>
<p>Agent turns already keep running when you quit Coincide, in its ${s.link("/features/background-agents", "background agent host")}, but nothing runs while the Mac is asleep. Keep Awake closes that gap for long turns, and lets ${s.link("/features/scheduled-tasks", "scheduled tasks")} run overnight while Coincide stays open.</p>

<h2 id="origin">Where it comes from</h2>
<p>Keep Awake is based on <a href="https://github.com/apoorvdarshan/macbook-24x7-agents">macbook-24x7-agents</a>, a command-line setup by Coincide’s author, and can replace it. If that tool is installed, the pane tells you.</p>
<p>Neither Keep Awake nor its helpers send anything anywhere.</p>
`,
};
