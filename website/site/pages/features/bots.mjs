import { table } from "../../layout.mjs";

// The seven characters, with the personality each one suggests (BotPersonalityPreset.defaultID).
const cast = [
  ["brulee", "Brulee", "a pink block-shaped character with an upside-down ice cream cone on its head", "Cheerful"],
  ["alien", "Alien", "a green alien with antennae and starry eyes", "Curious Explorer"],
  ["teddy", "Teddy", "a brown teddy bear", "Mentor"],
  ["star", "Star", "a yellow star blowing a kiss", "Coach"],
  ["cherry", "Cherry", "a red cherry with dizzy spiral eyes", "Witty"],
  ["croissant", "Croissant", "an orange croissant with cat whiskers", "Calm & Concise"],
  ["bomboloni", "Bomboloni", "a caramel pudding with puppy ears and a cherry on top", "Gentle"],
];

export default {
  path: "/features/bots",
  title: "Bots: standing AI assistants with a job · Coincide",
  description: "Bots in Coincide are saved assistants with a face, a personality and standing instructions, running on the agent and model you pick, in your chosen folder.",
  name: "Bots",
  summary: "Standing assistants with a face, a personality and a job, on the agent and model you choose.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Bots",
  lede: "A bot is an assistant you set up once and keep coming back to: it has a name, a character, a personality and standing instructions, and it runs on whichever agent and model you give it. Bots live in their own section of the sidebar, each with its own conversations.",
  related: ["/features/scheduled-tasks", "/features/model-picker", "/features/instructions", "/features/projects-and-threads"],
  body: (s) => `
<h2 id="what">What a bot is</h2>
<p>Under the hood, a bot is a saved preset over an ordinary agent conversation:</p>
${table(["Part", "What you set"], [
    ["Look", "One of seven characters, in one of eleven colors"],
    ["Name", "Anything you like"],
    ["Personality", "A preset, your own description (up to 4,000 characters), or none"],
    ["Instructions", "Its job, in your words (up to 20,000 characters)"],
    ["Agent and model", "Any agent and model from the model picker, with effort and speed"],
    ["Mode and permissions", "Plan or build, and approvals or full access, like any thread"],
    ["Folder", "Where its conversations run: your home folder unless you choose another"],
  ])}
<p>The personality and instructions reach the agent at the start of each session, as system or developer instructions where the agent has such a channel, otherwise as a marked block in front of the first message. They never appear in the transcript.</p>

<h2 id="create">Make one</h2>
<ol>
  <li>Choose File › New Bot…, or the + next to Bots in the sidebar.</li>
  <li>Pick a character and color, give it a name, and choose a personality. The editor previews how it greets you.</li>
  <li>Write its instructions: what it’s for and how it should work. For example, “Every morning, read the open pull requests in ~/code/app and list the ones waiting on me, oldest first.”</li>
  <li>Choose its agent and model, its mode and permissions, and its folder, then Create Bot.</li>
</ol>
<p>Click the bot to talk to it. Its menu in the sidebar has New Conversation, Past Conversations, Schedule…, Edit Bot… and Delete Bot…, and you can sort bots or drag them into your own order.</p>

<h2 id="cast">The cast</h2>
<p>Coincide starts you with one bot, Brulee, a cheerful everyday helper for quick questions and small jobs on your Mac. Like every starter, it’s an ordinary bot: edit it or delete it. The other characters are there for the bots you make, each with a personality it suggests:</p>
<ul class="cards">
${cast.map(([id, name, alt, personality]) => `  <li><div class="card"><b><img src="/img/bot-${id}.png" alt="${name}: ${alt}" width="56" height="56" loading="lazy"> ${name}</b><span>${personality.replace("&", "&amp;")}</span></div></li>`).join("\n")}
</ul>

<h2 id="personalities">Personalities</h2>
<p>Ten presets change how a bot talks, not what it does: Cheerful, Calm &amp; Concise, Witty, Mentor, Coach, Straight Shooter, Curious Explorer, Professional, Gentle and Creative. Choose Custom to describe one in your own words, or None to have it talk only as its instructions say.</p>

<h2 id="routines">Give a bot a routine</h2>
<p>Bots get really useful with a ${s.link("/features/scheduled-tasks", "schedule")}. Choose Schedule… from a bot’s menu and its prompt arrives in the bot’s conversation at the times you pick, such as a morning standup summary every weekday at nine or release notes every Friday. Schedules run while Coincide is open.</p>

<h2 id="tips">Tips and limits</h2>
<ul>
  <li><strong>Pick the folder deliberately.</strong> A bot can work with everything inside its folder. The home folder is the default; give a bot a narrower folder when its job is about one place.</li>
  <li><strong>Checkpoints.</strong> When a bot works in your home folder (or the disk’s root), Coincide doesn’t take per-turn ${s.link("/features/git", "checkpoints")}, since that would copy everything below it into git.</li>
  <li><strong>Any agent.</strong> Bots run on any of the six agents, and you can change a bot’s agent and model later in Edit Bot…</li>
  <li><strong>For project work, use a thread.</strong> Bots suit standing jobs and quick questions; for work on one codebase, a ${s.link("/features/projects-and-threads", "project thread")} keeps diffs, branches and worktrees together.</li>
</ul>
`,
};
