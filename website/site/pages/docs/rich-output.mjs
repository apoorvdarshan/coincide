import { code, table } from "../../layout.mjs";

export default {
  path: "/docs/rich-output",
  title: "Images, media and interactive previews · Coincide",
  description: "How agents show real images, audio, video and sandboxed interactive HTML or SVG in a Coincide thread, with the coincide-html and coincide-svg fences.",
  name: "Rich agent output",
  summary: "How agents show images, audio, video and sandboxed interactive HTML or SVG previews in a thread, and the limits.",
  type: "TechArticle",
  eyebrow: "Reference",
  h1: "Images, media and interactive previews",
  lede: "An agent’s reply in Coincide is more than text. When it links an image, a clip or a small HTML tool it made, Coincide shows the real thing under the reply. Every agent can do this, because it’s plain Markdown; Coincide tells each agent how at the start of its turns.",
  related: ["/features/transcript", "/features/browser", "/agents", "/features/composer"],
  body: (s) => `
<h2 id="media">Images, audio and video</h2>
<p>Coincide shows media that a reply links with Markdown:</p>
${code(`![Screenshot of the settings page](/Users/me/project/out/settings.png)
[Demo recording](/Users/me/project/out/demo.mp4)
![Chart](https://example.com/chart.png)`)}
<ul>
  <li>Images: PNG, JPEG, GIF, WebP, HEIC, AVIF, BMP and TIFF. Click one to open it.</li>
  <li>Video (MP4, M4V, MOV, WebM) and audio (MP3, M4A, WAV, AAC, AIFF, FLAC, OGG) get player controls. Nothing autoplays.</li>
  <li>Local files work best with absolute paths. A relative path is read from the thread’s working folder; chats without a project have their own folder, so absolute paths are the safe choice there.</li>
  <li>HTTP and HTTPS addresses work too. Coincide fetches web images without cookies, up to 8 MB.</li>
</ul>
<p>When Codex generates an image with its own image tool, Coincide copies the result into the thread’s attachments and shows it, even if the reply forgets to link it. Coincide doesn’t give any agent an image or video generator it doesn’t already have.</p>

<h2 id="interactive">Interactive previews</h2>
<p>For a chart, a diagram or a small tool, an agent can write a fenced block in the <code>coincide-html</code> or <code>coincide-svg</code> language. Coincide renders it as a live preview under the reply:</p>
${code("```coincide-html\n<canvas id=\"c\" width=\"400\" height=\"200\"></canvas>\n<script>\n  const ctx = document.getElementById('c').getContext('2d');\n  [40, 90, 60, 120].forEach((v, i) => ctx.fillRect(20 + i * 90, 200 - v, 60, v));\n</script>\n```")}
<p>Linking a local <code>.html</code>, <code>.htm</code> or <code>.svg</code> file does the same. Ordinary <code>html</code> fences stay code samples, so agents can still show you HTML without running it.</p>
<h3>The sandbox</h3>
<p>Previews run in a sandboxed web view with a strict content policy:</p>
<ul>
  <li>Inline JavaScript and CSS work; external scripts, stylesheets and fonts don’t.</li>
  <li>No network requests, forms, downloads, pop-ups or navigation away from the preview.</li>
  <li>No cookies, saved logins or storage that outlives the preview, and no bridge to Coincide or your Mac.</li>
  <li>Images, media and fonts must be embedded as <code>data:</code> or <code>blob:</code> URLs.</li>
</ul>
<p>So build previews from inline code and embedded data, such as SVG, canvas or a table built from a JSON array in the script.</p>

<h2 id="limits">Limits</h2>
${table(["What", "Limit"], [
  ["Previews per reply", "8 (images, media and interactive previews together)"],
  ["A coincide-html or coincide-svg block, or a linked .html or .svg file", "256 KB"],
  ["Inline data: images", "12 MB as text, 8 MB decoded"],
  ["Web images", "8 MB"],
  ["Local images", "64 MB"],
])}
<p>Previews wait until a streamed response finishes, so a half-written block is never run. If something can’t be shown, the card says “Preview unavailable”. The Markdown stays in the reply, selectable and copyable, either way.</p>

<h2 id="agents">What Coincide tells agents</h2>
<p>Coincide adds a short note to each turn explaining these rules: how to link images and media, to use absolute paths, the two fence languages and the sandbox. It also asks agents to show only files and results they really created, and to say so when a generation tool failed or isn’t available instead of claiming an image or video that doesn’t exist.</p>
`,
};
