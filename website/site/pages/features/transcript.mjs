import { kbd } from "../../layout.mjs";

export default {
  path: "/features/transcript",
  title: "A native transcript for agent replies · Coincide",
  description: "Coincide renders agent replies natively: Markdown with tables and highlighted code, images, media, sandboxed previews, folded work logs and agent labels.",
  name: "Native transcript",
  summary: "Markdown, highlighted code, images, audio, video, sandboxed previews and folded work logs, labeled by agent and model.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "A transcript that reads well",
  lede: "Coincide draws each conversation with native macOS text, not a web view. Replies stream in smoothly, long threads stay fast, and you can always tell which agent and model wrote what.",
  related: ["/docs/rich-output", "/features/composer", "/features/git", "/features/switch-agents"],
  body: (s) => `
<h2>Replies in Markdown</h2>
<p>Agents write GitHub-flavored Markdown, and Coincide renders it: headings, emphasis, links, lists with task items, block quotes, tables, rules and fenced code. Code blocks are syntax-highlighted for common languages, with Xcode’s colors, and have a copy button. A reply that is still streaming renders sensibly mid-block, and only the parts that changed are drawn again, so long replies don’t slow down as they grow.</p>
<p>By default replies are set in New York, Apple’s serif, with code and tables in the system fonts. Settings › General › Reply font switches to San Francisco, “Your messages” puts your own messages on the left or right, and View › Increase Font Size (${kbd("⌘", "+")}), Decrease (${kbd("⌘", "-")}) and Reset (${kbd("⌘", "0")}) change the size of the transcript and the composer.</p>

<h2>Who said it</h2>
<ul>
  <li><strong>The agent rail.</strong> A line runs down the left side of the transcript in the color of the agent doing the work, with the agent’s logo where it starts answering. When the next turn goes to another agent, the line blends into that agent’s color, so a thread several agents worked on shows who did what at a glance.</li>
  <li><strong>Labels.</strong> Each reply ends with the agent’s name in its color and the model that wrote it; in a bot’s conversation, the bot comes first.</li>
  <li><strong>Reasoning.</strong> Settings › General › Show reasoning includes the agent’s thinking when the model shares it.</li>
</ul>

<h2>Work logs that fold away</h2>
<p>While an agent works, its turn opens with “Working for 12s”. When it finishes, that line becomes a “Worked for 2m 13s” toggle that folds the turn’s tool calls, reasoning and interim replies, leaving the answer in view. Expand a tool call to see its input and output: the command and what it printed, or the diff of a file it edited. Very long output is trimmed from the front, since the end of a log matters most. Below a message you steered into a running turn, “Continued for 20s” folds the work that followed it.</p>
<p>Approvals and questions also appear in the log, with their outcome; see ${s.link("/features/approvals")}.</p>

<h2>Images, media and previews</h2>
<p>Agents can show more than text. Coincide renders, below the Markdown that refers to them:</p>
<ul>
  <li>images from absolute paths on your Mac or from the web;</li>
  <li>audio and video with playback controls, which never autoplay;</li>
  <li>inline previews of local <code>.html</code> and <code>.svg</code> files;</li>
  <li>interactive charts and small tools from <code>coincide-html</code> and <code>coincide-svg</code> code blocks, which run in a sandbox with no network, logins, forms, downloads or access to the app;</li>
  <li>images that Codex generates, copied into the thread’s attachments even when the reply doesn’t link them.</li>
</ul>
<p>Previews wait until a reply has finished streaming, and up to eight are shown per reply. ${s.link("/docs/rich-output")} explains how agents (or you, in instructions) can use these.</p>

<h2>Working with the transcript</h2>
<ul>
  <li><strong>Find.</strong> Edit › Find › Find… (${kbd("⌘", "F")}) searches the thread, including rendered Markdown, tool-call titles and expanded output, and highlights each match.</li>
  <li><strong>Reply.</strong> Select text in a reply, plan or message and a Reply button appears; it puts the selection in the composer as a quote (${kbd("⌘", "L")} does the same).</li>
  <li><strong>Copy.</strong> Copy a message, a whole response or a single code block.</li>
  <li><strong>Fork or rewind.</strong> “Fork from this response” starts a new thread with the conversation up to there, and “Edit from here” rewinds to one of your messages; see ${s.link("/features/git")}.</li>
  <li><strong>Links.</strong> A web link opens in the thread’s ${s.link("/features/browser", "browser")}, and ⌘-click opens your default browser. Settings › General › “Open links in your default browser” swaps the two.</li>
</ul>

<h2>Fast with long histories</h2>
<p>A transcript is read from disk only when you open its thread, so a long history doesn’t slow down launch or the sidebar. Agents’ messages and tool output stay on your Mac in Coincide’s data folder (see ${s.link("/docs/data-storage")}).</p>
`,
};
