import { video, videoSchema, shared } from "./_blog.mjs";
const poster = "/img/blog/native-swift-coding-agents.jpg";
const clip = {"id": "SIcmHi7FV3s", "short": false, "title": "Swift. AppKit. No Electron. Meet Coincide.", "image": "/img/blog/native-swift-coding-agents.jpg", "width": 1280, "height": 720, "description": "An edited 10-second Coincide motion preview: native Swift and AppKit, with captured Codex, Claude Code and Cursor picker panels over generic conversation text.", "uploaded": "2026-11-05T05:36:39Z", "duration": "PT10S"};
export default {
  path: "/blog/native-swift-coding-agents",
  title: "Swift. AppKit. No Electron: native agents in Coincide",
  description: "A 10-second preview of Coincide’s native Swift and AppKit interface: Claude Code, Codex and Cursor, with a conversation that stays together.",
  name: "Switch agents. Stay native.",
  summary: "Swift and AppKit on the Mac, with each coding agent’s own CLI and login behind the interface.",
  media: "Feature video",
  image: poster,
  type: "Article",
  eyebrow: "Native to Mac",
  h1: "Swift. AppKit. No Electron.",
  lede: "Different coding agents, one native Mac app. A new 10-second motion preview of Coincide.",
  published: "2026-11-05T11:08:37+05:30",
  updated: "2026-11-05",
  schema: [videoSchema(clip)],
  related: ["/features/model-picker", "/features/switch-agents", "/blog/one-conversation-six-agents"],
  body: (s) => `
${video(clip)}
<h2 id="native">Built with Swift and AppKit</h2>
<p>Coincide’s Mac interface is built with AppKit, with SwiftUI where it fits, such as Settings. The main window, conversation, composer and agent picker are native Mac UI. The app uses native menus, keyboard shortcuts and accessibility rather than an Electron shell.</p>
<p>That is what the video means by “Swift. AppKit. No Electron.” It is an architectural description, not a benchmark or a promise that every workload will run faster than another app.</p>
<h2 id="agents">Your agents and your existing logins</h2>
<p>Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity run through their own command-line tools. Coincide uses the logins you already have; it does not sell, proxy or meter tokens. The native interface brings those agents into one place.</p>
<p>The preview shows the Codex, Claude Code and Cursor ${s.link("/features/model-picker", "picker catalogs")}. Available models depend on the agents installed and signed in on your Mac and on your provider account. Choosing a model also chooses the agent that handles the next turn.</p>
<h2 id="thread">Switch agents. Keep the thread.</h2>
<p>When you ${s.link("/features/switch-agents", "switch agents mid-thread")}, the next agent gets a recap of the turns it missed and continues in the same working directory. Each agent keeps its own native session. Switch back, and that agent resumes its session.</p>
<p>The ${s.link("/blog/one-conversation-six-agents", "handoff deep dive")} explains the mechanism and its limits. A shared thread does not mean the providers share their internal state.</p>
<h2 id="footage">About this preview</h2>
<p>This is an edited illustrative demo. Conversation text was replaced with generic content for privacy; the picker panels were captured from Coincide. The clip browses provider catalogs, rather than recording a fresh live handoff or simultaneous execution. Model names reflect the captured app state. The motion design and synthesized sound are original.</p>
<h2 id="shared">Shared today</h2>
${shared([
  [
    "YouTube",
    "https://youtu.be/SIcmHi7FV3s",
    "the 10-second motion preview"
  ],
  [
    "Mastodon",
    "https://mastodon.social/@apoorvcodes/117562202416381254",
    "post with the video"
  ],
  [
    "Bluesky",
    "https://bsky.app/profile/apoorvdarshan.com/post/3mzkdvda5k222",
    "post with the video"
  ],
  [
    "LinkedIn",
    "https://www.linkedin.com/feed/update/urn:li:ugcPost:7523981132330094592/",
    "post with the video"
  ],
  [
    "X",
    "https://x.com/apoorvdarshan/status/2118215553412411665",
    "post with the video"
  ],
  [
    "DEV",
    "https://dev.to/apoorvdarshan/swift-appkit-no-electron-coding-agents-in-a-native-mac-app-52l9",
    "the companion article"
  ],
  ["daily.dev", "https://daily.dev/posts/swift-appkit-no-electron-switch-agents-stay-native--mgzsqutbd", "the motion preview, shared"]
])}
<p><a href="/download">Download Coincide</a> or read the <a href="https://github.com/apoorvdarshan/coincide">MIT-licensed source on GitHub</a>.</p>
`,
};
