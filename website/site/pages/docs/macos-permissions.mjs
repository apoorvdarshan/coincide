import { table } from "../../layout.mjs";

export default {
  path: "/docs/macos-permissions",
  title: "macOS permissions Coincide asks for · Coincide",
  description: "Which macOS permissions Coincide can ask for, the feature that needs each one, and how to grant or revoke them in System Settings.",
  name: "macOS permissions",
  summary: "Each macOS permission Coincide can ask for, which feature needs it, and how to grant or take it back.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "macOS permissions",
  lede: "Coincide asks for a permission only when you use a feature that needs it. Most people never see more than one or two of these prompts. This page lists them all, so you know why each one appears and where to change your answer.",
  related: ["/features/computer-use", "/features/appshots", "/features/dictation", "/features/keep-awake", "/privacy"],
  body: (s) => `
<h2 id="list">The permissions</h2>
${table(["Permission", "Asked for when", "Where to change it"], [
  ["Microphone", "You dictate a message the first time (" + s.link("/features/dictation", "dictation") + ")", "System Settings › Privacy &amp; Security › Microphone"],
  ["Speech Recognition", "You dictate with Apple’s speech recognition, the default engine", "Privacy &amp; Security › Speech Recognition"],
  ["Accessibility", "You turn on " + s.link("/features/computer-use", "Computer Use") + ", or Appshots with both ⌘ keys or the window’s text", "Privacy &amp; Security › Accessibility"],
  ["Screen Recording", "You turn on Computer Use or " + s.link("/features/appshots", "Appshots") + ", which capture windows", "Privacy &amp; Security › Screen &amp; System Audio Recording"],
  ["Automation (Apple Events)", "Computer Use’s helper controls another app for an agent", "Privacy &amp; Security › Automation"],
  ["Full Disk Access", "You import from a browser whose data macOS protects, such as Safari, in Settings › Browser › Import", "Privacy &amp; Security › Full Disk Access"],
  ["Keychain access", "You import cookies from a Chromium browser (macOS asks to allow that browser’s Safe Storage key), or allow Coincide to read Cursor’s sign-in for usage limits", "Answered per prompt; Keychain Access app"],
  ["Notifications", "Coincide first notifies you that a turn finished or needs you", "System Settings › Notifications › Coincide"],
  ["Local Network", "You turn on Coincide Remote (coming soon) so a phone or iPad can connect", "Privacy &amp; Security › Local Network"],
  ["Allow in the Background (Login Items)", "The background agent host starts, or you turn on Keep Awake", "System Settings › General › Login Items &amp; Extensions"],
  ["Administrator password", "You turn Keep Awake on or off (it runs <code>pmset</code>)", "Asked each time"],
])}
<p>Settings › Computer Use and Settings › Appshots show the status of the permissions they need, with buttons that open the right System Settings pane. Grant the permission there, come back, and the status refreshes.</p>

<h2 id="background">Background items</h2>
<p>Three of Coincide’s parts run on their own, so macOS lists them under Login Items &amp; Extensions › Allow in the Background:</p>
<ul>
  <li><strong>The agent host</strong>, which keeps agents running after you quit Coincide (Settings › General › Agents › <strong>Keep agents running when Coincide quits</strong>). If you turn Coincide off there, Settings says “Coincide is turned off under Allow in the Background in Login Items. Turn it on to keep agents running after Coincide quits.” and offers <strong>Open Login Items…</strong>. Until then, agents run inside the app and stop when it quits. See ${s.link("/features/background-agents")}.</li>
  <li><strong>The lid watcher</strong>, which ${s.link("/features/keep-awake", "Keep Awake")} starts at login while it’s on, to follow the lid. If it isn’t allowed, Settings says “Allow Coincide in Login Items to watch the lid”.</li>
  <li><strong>The battery helper</strong>, a small launchd daemon that runs as root only while <strong>Sleep normally on battery</strong> and Keep Awake are on. It takes no input and only switches sleep on or off when the Mac is plugged in or unplugged. Until you allow it, the Mac stays awake on battery too.</li>
</ul>
<p>Turning these features off in Coincide unregisters their background items.</p>

<h2 id="signing">Why the prompts come back for some builds</h2>
<p>macOS ties privacy permissions to an app’s code signature. Releases are signed with Coincide’s Developer ID, so your answers last across updates. Builds you make from source are signed ad hoc by default, and each new build looks like a different app, so macOS asks again. Sign your own builds with a stable identity to avoid that (see ${s.link("/docs/build-from-source")}).</p>

<h2 id="revoke">Taking a permission back</h2>
<p>Turn it off in the pane listed above. The feature that needs it stops working until you allow it again: dictation can’t hear you, Computer Use and Appshots stop seeing windows, and so on. Turning the feature itself off in Coincide is usually simpler: Computer Use ends agents’ access when you turn it off or quit Coincide. What each feature sends and where is in the ${s.link("/privacy", "privacy policy")}.</p>
`,
};
