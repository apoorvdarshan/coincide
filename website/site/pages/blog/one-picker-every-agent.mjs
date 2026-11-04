import { shared } from "./_blog.mjs";

const published = "2026-11-04T08:27:11+05:30";
const poster = "/img/blog/one-picker-every-agent.jpg";
const clip = "/video/blog/one-picker-every-agent.mp4";

export default {
  path: "/blog/one-picker-every-agent",
  title: "Claude Code, Codex and Cursor: one agent picker in Coincide",
  description: "A 12-second preview of Coincide’s agent and model picker: choose Claude Code, Codex or Cursor without leaving your conversation.",
  name: "One picker for your coding agents",
  summary: "Claude Code, Codex and Cursor in one native Mac interface, with each agent’s own CLI and login.",
  media: "Feature video",
  image: poster,
  type: "Article",
  eyebrow: "Workflow preview",
  h1: "One picker for your coding agents",
  lede: "Keep the conversation in one place, and choose the coding agent and model you want to use next.",
  published,
  updated: "2026-11-04",
  schema: [{
    "@type": "VideoObject",
    name: "Claude Code, Codex and Cursor in one Mac app",
    description: "An edited demo of Coincide’s model catalogs with generic task-board conversation text. The picker panels were captured from the app.",
    thumbnailUrl: "https://coincide.dev" + poster,
    uploadDate: published,
    duration: "PT12S",
    contentUrl: "https://coincide.dev" + clip,
    embedUrl: "https://coincide.dev/blog/one-picker-every-agent#watch",
    width: 1920,
    height: 1088,
  }],
  related: ["/features/model-picker", "/features/switch-agents", "/blog/one-conversation-six-agents"],
  body: (s) => `
<figure class="video" id="watch">
  <video controls playsinline preload="none" poster="${poster}" width="1920" height="1088" style="display:block;width:100%;height:auto;border-radius:18px" aria-label="Coincide agent picker: Codex, Claude Code and Cursor catalogs over a generic task-board conversation">
    <source src="${clip}" type="video/mp4">
    <a href="${clip}">Download the 12-second Coincide preview</a>.
  </video>
  <figcaption>A 12-second edited workflow preview. No audio; demo conversation.</figcaption>
</figure>

<h2 id="picker">The agent and model are one choice</h2>
<p>Click the model button below the composer, or press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>M</kbd>. The ${s.link("/features/model-picker", "picker")} has a search field, Favorites, and a tab for each agent. Choose a model and you also choose the agent that will handle the next turn.</p>
<p>The clip browses the Codex, Claude Code and Cursor catalogs. Available models come from the agents installed and signed in on your Mac; providers decide which models and limits your account can use. Reasoning effort and speed controls appear where the provider supports them.</p>

<h2 id="accounts">Your existing agents and logins</h2>
<p>Coincide drives each agent through its own command-line tool, with the login you already have. It does not resell tokens or put the agents behind a Coincide subscription. It is a free, MIT-licensed native Mac app.</p>

<h2 id="conversation">The conversation stays together</h2>
<p>When you ${s.link("/features/switch-agents", "switch agents mid-thread")}, each provider keeps its own native session. The next agent gets a recap of the turns it missed and continues in the same working directory. The ${s.link("/blog/one-conversation-six-agents", "handoff deep dive")} explains that boundary in more detail.</p>

<p class="note">This is an illustrative demo. The conversation and title were replaced with generic task-board text for privacy; the picker panels were captured from the app. The clip shows browsing model catalogs, not simultaneous execution or a completed task-board implementation. Model names are a snapshot of the recording.</p>

<h2 id="shared">Shared today</h2>
${shared([
  [
    "Mastodon",
    "https://mastodon.social/@apoorvcodes/117555908072740731",
    "post with the video"
  ],
  [
    "Bluesky",
    "https://bsky.app/profile/apoorvdarshan.com/post/3mzhdyie4ub2f",
    "post with the video"
  ],
  [
    "LinkedIn",
    "https://www.linkedin.com/feed/update/urn:li:ugcPost:7523578252326653953/",
    "post with the video"
  ],
  [
    "X",
    "https://x.com/apoorvdarshan/status/2117812718648672582",
    "post with the video"
  ],
  [
    "DEV",
    "https://dev.to/apoorvdarshan/claude-code-codex-and-cursor-one-agent-picker-in-coincide-b7k",
    "the companion article"
  ],
  [
    "daily.dev",
    "https://daily.dev/posts/claude-code-codex-and-cursor-one-agent-picker-in-coincide-mlbqoqgi7",
    "the workflow preview, shared"
  ]
])}

<p><a href="/download">Download Coincide</a> or read the <a href="https://github.com/apoorvdarshan/coincide">source on GitHub</a>.</p>
`,
};
