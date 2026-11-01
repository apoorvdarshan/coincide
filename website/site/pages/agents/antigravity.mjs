export default {
  path: "/agents/antigravity",
  title: "Google Antigravity agent on your Mac · Coincide",
  description: "Run Google’s Antigravity agent in Coincide with a Google sign-in or Gemini API key: the verified runtime download, models, quotas and the account risk.",
  name: "Antigravity",
  summary: "Google’s agent through its own ACP runtime, which Coincide downloads and verifies. Read the account-risk note first.",
  icon: "/img/logo-antigravity.png",
  logo: { src: "/img/logo-antigravity.png", alt: "Antigravity logo" },
  eyebrow: "Agent · Google",
  h1: "Antigravity in Coincide",
  lede: "Coincide can run Google’s Antigravity agent through Google’s own Agent Client Protocol runtime, signed in with your Google account or a Gemini API key. Before you use a Google sign-in, read the account risk below.",
  related: ["/docs/agent-accounts", "/features/usage-dashboard", "/features/approvals", "/docs/troubleshooting", "/agents/grok-build"],
  body: (s) => `
<div class="callout warn">
  <p><strong>Account risk.</strong> Google’s <a href="https://antigravity.google/terms">Antigravity terms</a> call accessing the service with third-party software, tools or services a breach. Since February 2026, Google has suspended accounts for this, mostly personal Google AI Pro and Ultra sign-ins used through third-party tools, and a suspension also cuts off Gemini CLI and Code Assist. Coincide drives Google’s own Antigravity agent, but Google staff have given conflicting answers about tools that do. Use it at your own risk, and consider a separate Google account. Gemini API keys from Google AI Studio or Gemini Enterprise aren’t affected.</p>
  <p>Coincide shows this notice in Settings › Antigravity and asks you to acknowledge it once, with “I Understand”, before you sign in or turn Antigravity on.</p>
</div>

<h2 id="how">How Coincide runs Antigravity</h2>
<p>Antigravity’s agent runs as Google’s ACP server, a runtime separate from the Antigravity app. Coincide installs it for you: it downloads a pinned release from Google (<code>dl.google.com</code>), checks the archive’s size and SHA-256 checksum and every file’s checksum, verifies Google’s Developer ID signature, and starts the runtime once to check it before using it. Newer runtimes arrive with Coincide updates. If you’d rather use your own copy, Coincide also finds <code>agy_acp_server</code> on your <code>PATH</code> or at a custom path.</p>
<p>Coincide keeps Antigravity’s sign-in in a private profile inside its own data folder, separate from any other Google tools you use.</p>

<h2 id="setup">Set it up</h2>
<ol>
  <li>Open <strong>Settings › Antigravity</strong>, read the notice and choose I Understand.</li>
  <li>Choose <strong>Install Antigravity</strong>. Coincide shows the download size and progress, and then the installed version. (Google publishes the runtime for Apple silicon and Intel Macs.)</li>
  <li>Choose <strong>Sign in with Google</strong> and finish signing in in your browser. If you sign in on another device, you can paste the address the browser ends on back into Coincide.</li>
  <li>Pick an Antigravity model in the composer, or type <code>/antigravity</code> to continue a thread with it.</li>
</ol>
<p>To avoid the subscription-account risk, add an account with a Gemini API key instead, in the same pane; each API-key account gets its own profile and the key is kept in your Keychain. ${s.link("/docs/agent-accounts", "Agent accounts")} has the details.</p>

<h2 id="models">Models</h2>
<p>Coincide asks the runtime which models your account can use, without sending a prompt, and keeps the list for six hours. It offers only models your account lists. Reasoning effort appears only where the runtime offers it for a model.</p>

<h2 id="features">What works with Antigravity</h2>
<ul>
  <li><strong>Approvals and full access:</strong> in approval mode, each request offers Allow once, Allow for this thread, Deny or Cancel, along with Google’s own security warning. Full access uses the runtime’s <code>yolo</code> mode.</li>
  <li><strong>Questions</strong> from Antigravity are answered inline.</li>
  <li><strong>Images</strong> (PNG, JPEG, WebP and BMP) can be attached.</li>
  <li><strong>Plan mode:</strong> Coincide asks for a plan in the prompt, and switches the runtime to a planning mode if it offers one.</li>
  <li><strong>Follow-ups</strong> are queued for the next turn; Antigravity can’t be steered mid-turn.</li>
  <li><strong>Stopping</strong> cancels the turn, and Coincide replaces the runtime process if it hasn’t stopped after five seconds.</li>
  <li><strong>Resuming:</strong> each thread resumes its own Antigravity session.</li>
  <li><strong>Usage limits:</strong> for Google sign-ins, the Gemini and shared Claude and GPT quotas, over five hours and a week, read from Google’s Cloud Code service. None for API-key accounts.</li>
</ul>

<h2 id="limits">Limitations</h2>
<ul>
  <li>The account risk above, for Google subscription sign-ins.</li>
  <li>If Google says your account needs a subscription, or asks you to sign in again in the middle of a turn, the turn stops and Coincide asks you to sign in to Antigravity in Settings.</li>
  <li>Coincide’s data folder can’t contain a colon (<code>:</code>) in its path, because the runtime can’t use it.</li>
  <li>No mid-turn steering.</li>
</ul>
`,
};
