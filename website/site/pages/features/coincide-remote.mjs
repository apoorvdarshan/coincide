export default {
  path: "/features/coincide-remote",
  title: "Coincide Remote for iPhone and iPad (coming soon)",
  description: "Coincide Remote, coming soon to the App Store for iPhone and iPad, connects straight to your Mac over your network or Tailscale, with no relay or account.",
  name: "Coincide Remote",
  summary: "Coming soon to the App Store: follow and steer your Mac’s agents from iPhone or iPad, connected directly to your Mac.",
  type: "WebPage",
  eyebrow: "Feature · Coming soon",
  h1: "Coincide Remote for iPhone and iPad",
  lede: "Coincide Remote is the companion app that lets you follow and steer the agents on your Mac from your iPhone or iPad. On the home screen it’s called Coincide. It isn’t available yet; this page describes what it does, what it costs and how it handles your data.",
  related: ["/features/notifications", "/features/background-agents", "/features/languages"],
  body: (s) => `
<div class="callout">
  <p><strong>Coming soon to the App Store.</strong> Coincide Remote isn’t available yet. On the App Store it will be listed as “Coincide - AI Coding Agents”. Coincide for Mac 0.1.0 works fully on its own. Follow <a href="https://x.com/apoorvdarshan">@apoorvdarshan</a> or join the <a href="https://discord.gg/DETrbhDVqw">Discord</a> to hear when it ships. Details below may change before release.</p>
</div>

<h2 id="what">What it’s for</h2>
<p>Agents in Coincide often run for minutes or hours, in the ${s.link("/features/background-agents", "background agent host")}, while you’re away from the desk. Coincide Remote puts those threads in your pocket. A paired device can see and control much of what Coincide on that Mac can:</p>
<ul>
  <li>projects, threads and chats, with their messages and attachments, and new messages to your agents;</li>
  <li>answering an agent that’s waiting for approval or asking a question;</li>
  <li>diffs and git actions, scheduled tasks, bots, usage and settings;</li>
  <li>photos and files you attach on the phone, which go to your Mac and, when you send them, to the agent’s provider;</li>
  <li>dictation with Apple’s speech recognition on the device.</li>
</ul>
<p>It uses the Mac app’s themes and its 19 languages.</p>

<h2 id="pro">Free, Coincide Pro and tips</h2>
<p>Coincide Remote is free to download, and browsing is free: every project, thread, message, diff, setting and usage chart on your paired Mac.</p>
<p>Acting on your Mac from the phone needs <strong>Coincide Pro</strong>: sending prompts, answering approvals and questions, git and pull requests, scheduled tasks, bots and changing settings. It’s bought in the app through the App Store:</p>
<ul>
  <li><strong>Monthly:</strong> $2.99 a month.</li>
  <li><strong>Yearly:</strong> $19.99 a year, with a 7-day free trial.</li>
  <li><strong>Lifetime:</strong> $39.99, a one-time purchase.</li>
</ul>
<p>Those are US prices; the App Store shows local prices in other countries. Subscriptions renew automatically until you cancel them, with Manage Subscription in Settings › Coincide Pro or in your Apple Account’s subscription settings. The same pane has Restore Purchases. Optional tips in Settings support development and unlock nothing. The <a href="/terms#purchases">terms</a> cover purchases in full.</p>

<h2 id="demo">Explore the Demo</h2>
<p>No Mac at hand? Tap Explore the Demo on the first screen to look around a sample Mac with projects, threads, bots, diffs, scheduled tasks, usage and settings, under a banner that says it’s a demo. Nothing in the demo reaches a Mac or the network. Exit Demo, in the banner or in Settings › Macs, goes back to pairing.</p>

<h2 id="connection">How it connects</h2>
<p>There’s no Coincide server, relay or account in between. Your iPhone or iPad connects straight to Coincide on your Mac:</p>
<ul>
  <li><strong>Over your own network:</strong> on the same Wi-Fi or local network, the Mac announces itself with Bonjour, under your Mac’s name.</li>
  <li><strong>Over Tailscale:</strong> away from home, the phone reaches the Mac through your own Tailscale network.</li>
  <li><strong>Encrypted:</strong> the connection uses TLS 1.3, and the phone pins your Mac’s certificate when you pair, so it only talks to that Mac.</li>
  <li><strong>Limited to private addresses:</strong> the Mac accepts connections only from local, private and Tailscale addresses.</li>
</ul>
<p>Coincide has to be open on the Mac for the phone to connect.</p>

<h2 id="pairing">Pairing</h2>
<p>On the Mac, the switch lives in Settings › General › Remote (“Allow Coincide Remote”), and it’s off until you turn it on. Choose Pair iPhone or iPad… and the Mac shows a one-time pairing code that expires after five minutes; you scan it with the app.</p>
<p>The phone keeps a random token in its Keychain, and the Mac keeps only a hash of it. The same pane lists paired devices with when they last connected, lets you revoke any of them, and can reset the certificate, which forgets every paired device.</p>

<h2 id="alerts">Notifications</h2>
<p>With Coincide Remote in use and the Mac idle, Coincide sends its notifications (a turn finished, an agent needs you) to the iPhone or iPad instead of the Mac, never to both, and seeing a thread anywhere clears them everywhere. ${s.link("/features/notifications", "Notifications")} covers how this works on the Mac.</p>
<p><strong>Lock-screen alerts</strong> are optional and off by default. When you turn on “Notify this iPhone when it’s locked”, the Mac writes a short alert (the thread’s title, what happened and a detail line of up to 120 characters) to your own private iCloud database, and Apple delivers it as a push notification. Coincide deletes each alert once you’ve seen its thread. This needs a Mac build signed for iCloud; the builds published on GitHub for 0.1.0 leave that entitlement out, so lock-screen alerts aren’t available with them.</p>

<h2 id="permissions">Permissions on the phone</h2>
<p>Camera (to scan the pairing code and take photos you attach), photo library (photos you pick or save), microphone and speech recognition (dictation), and local network (to find and reach your Mac).</p>

<h2 id="privacy">Privacy</h2>
<p>Everything goes between your devices, and to your agents’ providers only when you send a message. Purchases go through the App Store, and the app checks them with RevenueCat under a random ID that isn’t tied to your name, email or Apple Account. The <a href="/privacy">privacy policy</a> already covers Coincide Remote, including what Apple may share if you install it through TestFlight or the App Store.</p>
`,
};
