import { shared, video, videoSchema } from "./_blog.mjs";

const short = {
  id: "qpZBAiav69I",
  short: true,
  title: "Coding agents with a face: meet the Coincide bots",
  description: "The seven Coincide bots, their personalities, and a bot with a morning routine, in a 26-second cartoon.",
  image: "/img/blog/coding-agents-with-a-face.jpg",
  width: 540,
  height: 960,
  uploaded: "2026-11-02",
  duration: "PT26S",
};

export default {
  path: "/blog/coding-agents-with-a-face",
  title: "Coding agents with a face: meet the Coincide bots",
  description: "Bots in Coincide are coding agents with a face: a character, a personality and standing instructions, on the agent, model and folder you pick.",
  name: "Coding agents with a face",
  summary: "Meet the bots: seven characters, ten personalities, and a routine on the agent and model you choose.",
  media: "YouTube Short",
  type: "Article",
  eyebrow: "Feature of the day",
  h1: "Coding agents with a face: meet the Coincide bots",
  lede: "Bots are how you keep a standing assistant around in Coincide: a coding agent with a face, a personality and a job.",
  published: "2026-11-02T21:34:00+05:30",
  updated: "2026-11-02",
  schema: [videoSchema(short)],
  related: ["/features/bots", "/features/scheduled-tasks", "/blog/one-conversation-six-agents"],
  body: (s) => `
${video(short)}

<h2 id="what">What a bot is</h2>
<p>A bot is a saved setup for new conversations: its look, name, personality and instructions, plus the agent, model and modes those conversations start with, and the folder they run in. Open the bot and you’re talking to that setup, on the command-line tool and login you already have. The ${s.link("/features/bots", "Bots feature page")} has every option.</p>

<h2 id="character">Pick a character</h2>
<p>There are seven characters (Brulee, Alien, Star, Croissant, Bomboloni, Cherry and Teddy) and eleven colors. They’re drawn in code, so they stay sharp at any size, and their eyes blink now and then while the bot is working, unless you’ve asked macOS to reduce motion.</p>

<h2 id="personality">Give it a personality</h2>
<p>Pick one of ten presets: Cheerful, Calm &amp; Concise, Witty, Mentor, Coach, Straight Shooter, Curious Explorer, Professional, Gentle or Creative. Each one shows a sample greeting in its voice, written by hand, not generated. Or choose Custom and describe the personality yourself, starting from a preset’s text if you like.</p>

<h2 id="agent">Its own agent, model and folder</h2>
<p>Each bot decides where its conversations start: Codex with GPT-5.5 in one repository, Claude Code with Opus in another. You don’t have to pick the agent, model and folder again every time.</p>

<h2 id="routine">Give it a routine</h2>
<p>${s.link("/features/scheduled-tasks", "Scheduled tasks")} can send a message into a bot’s conversation once, daily, on weekdays or chosen days, weekly, every few minutes or hours, or on a cron expression, in a chosen time zone. A “Morning standup” every weekday at 9:00 is a single schedule. Schedules run while Coincide is open and wait for a busy thread to finish its turn.</p>

<p class="note">The video recreates the app with demo data. The bots use Coincide’s own artwork.</p>

<h2 id="shared">Where the bots went today</h2>
${shared([
    ["YouTube", "https://youtube.com/shorts/qpZBAiav69I", "the 26-second Short"],
    ["X", "https://x.com/apoorvdarshan/status/2117285304105320567", "post with the video"],
    ["Bluesky", "https://bsky.app/profile/apoorvdarshan.com/post/3mzdoqgnpf22m", "post with the video"],
    ["Mastodon", "https://mastodon.social/@apoorvcodes/117547656882214031", "post with the video"],
    ["LinkedIn", "https://www.linkedin.com/feed/update/urn:li:ugcPost:7523050239180865536/", "post with the video"],
    ["DEV", "https://dev.to/apoorvdarshan/coding-agents-with-a-face-bots-in-coincide-40d5", "the article"],
    ["daily.dev", "https://daily.dev/posts/coding-agents-with-a-face-bots-in-coincide-a-native-mac-app-for-claude-code-codex-and-cursor--btniasp6c", "the article, shared"],
  ])}
<p>Which bot would you pick? Tell me on <a href="https://x.com/apoorvdarshan">X</a> or in the <a href="https://discord.gg/DETrbhDVqw">Discord</a>.</p>
`,
};
