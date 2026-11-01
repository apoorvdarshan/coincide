import { table } from "../../layout.mjs";

export default {
  path: "/features/dictation",
  title: "Dictate prompts to coding agents on your Mac · Coincide",
  description: "Talk to Claude Code, Codex and other agents in Coincide with Apple’s on-device speech, a local Whisper model, or OpenAI or Groq with your own API key.",
  name: "Dictation",
  summary: "Speak your prompts with Apple’s on-device speech, a local Whisper model, or OpenAI or Groq with your key.",
  type: "WebPage",
  eyebrow: "Feature",
  h1: "Dictation",
  lede: "Coincide’s composer has a microphone. Speak a prompt instead of typing it, with the engine you prefer: Apple’s speech recognition on your Mac, a Whisper model that runs offline, or OpenAI or Groq with your own API key.",
  related: ["/features/composer", "/features/appshots", "/docs/keyboard-shortcuts"],
  body: (s) => `
<h2 id="use">Dictate a message</h2>
<ol>
  <li>Click the microphone in the composer, or choose Edit › Dictate. The first time, macOS asks whether Coincide may use the microphone.</li>
  <li>Speak. With Apple’s engine, the words appear as you talk.</li>
  <li>Click again to stop. The text waits in the composer for you to check and send, or goes straight out if you turn on “Send when I stop”.</li>
</ol>
<p>Everything is in Settings › Voice: the engine, the language (automatic by default), which microphone to use, and a level meter to test it. Testing the microphone records nothing.</p>

<h2 id="engines">Choose an engine</h2>
${table(["Engine", "Where it runs", "Good to know"], [
    ["Apple (on device)", "On your Mac", "The default. Partial text appears as you speak. macOS downloads a language’s speech model the first time you dictate in it, or when you click Download Now."],
    ["Whisper (on this Mac)", "On your Mac, offline", "You download a model once (see below), then it works without a network."],
    ["OpenAI", "OpenAI’s transcription API", "Uses your OpenAI API key. Models: GPT Transcribe (recommended), GPT-4o Transcribe, GPT-4o mini Transcribe and Whisper."],
    ["Groq", "Groq’s API", "Uses your Groq API key. Models: Whisper Large v3 Turbo (faster) and Whisper Large v3 (more accurate)."],
  ])}

<h3 id="whisper">Local Whisper models</h3>
<p>Whisper runs through WhisperKit. Coincide bundles no models: they download from Hugging Face only when you click Download in Settings › Voice, are checked against their published checksums, and run offline afterwards.</p>
${table(["Model", "Download", "Trade-off"], [
    ["Tiny", "about 79 MB", "Fastest, least accurate"],
    ["Base", "about 149 MB", "Fast, good for clear speech (the default)"],
    ["Small", "about 489 MB", "Slower, more accurate"],
    ["Large v3 Turbo", "about 648 MB", "Most accurate; best on Apple silicon with 16 GB of memory or more"],
  ])}

<h3 id="keys">API keys for OpenAI and Groq</h3>
<p>Paste your key in Settings › Voice and choose Test Key; Coincide keeps it in your Keychain. If Codex is signed in with an OpenAI API key, “Use Codex’s Key…” copies that key from <code>~/.codex/auth.json</code> into Coincide’s own Keychain item. It never reads ChatGPT sign-ins, and changing the key in Codex later doesn’t change Coincide’s copy.</p>

<h2 id="shortcut">Dictate with a keyboard shortcut</h2>
<p>Turn on the keyboard shortcut in Settings › Voice to dictate without reaching for the mouse. It’s off by default, and while it’s off Coincide watches no keys for dictation. The default is the 🌐 fn key; you can record another key with ⌘, ⌃ or ⌥, or a single modifier on its own.</p>
<ul>
  <li><strong>Hold to talk, tap to toggle</strong> (the default): hold the key while you speak and let go to stop, or tap once to start and again to stop.</li>
  <li><strong>Hold only</strong> or <strong>Tap only</strong>, if you prefer one.</li>
</ul>
<p>The shortcut works while a Coincide window is in front. If macOS also does something when you press 🌐, set “Press 🌐 key to” to Do Nothing in System Settings › Keyboard; Coincide’s Voice pane links there.</p>

<h2 id="privacy">Privacy</h2>
<ul>
  <li>With Apple’s engine or Whisper, your audio stays on your Mac.</li>
  <li>With OpenAI or Groq, the recording is sent to that provider to be transcribed, under your account and its data policies.</li>
  <li>Recordings are held in memory only while they’re transcribed.</li>
</ul>
<p>The <a href="/privacy">privacy policy</a> covers dictation in the same terms.</p>

<h2 id="agents">Works with every agent</h2>
<p>Dictation fills Coincide’s composer, so it works the same whichever agent the thread uses. It pairs well with ${s.link("/features/appshots", "appshots")}: capture a window, then say what you want done with it.</p>
`,
};
