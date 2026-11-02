# App Store listing

Coincide Remote's App Store listing (en-US), which store-release reads with `[ios.listing]` in
[`store-release.toml`](store-release.toml): the first code block under each heading from **App Name** to
**Marketing URL**. With `IOS_UPLOAD_LISTING` on, a release uploads the promotional text, description, keywords and the
support and marketing URLs to the tag's version. The name, subtitle and privacy policy URL belong to the app, not a
version: they're set in App Store Connect (App Information), and kept here so the whole listing reads in one place.

Version 0.1.0 has no What's New: App Store Connect shows it only from an app's second version on.

## App Name
```
Coincide - AI Coding Agents
```

## Subtitle (30 chars max)
```
Your Mac’s agents, on iPhone
```

## Promotional Text (170 chars max)
```
Follow and steer Claude Code, Codex, Cursor and more on your Mac from iPhone or iPad. Approve commands, review diffs, push and open pull requests.
```

## Keywords (100 chars max)
```
claude,codex,cursor,grok,opencode,antigravity,remote,control,git,github,diff,pull request,llm,prompt
```

## Description
```
Coincide puts the coding agents running on your Mac in your pocket. Follow your Claude Code, Codex, Cursor, Grok, OpenCode and Antigravity threads live on your iPhone or iPad, and step in when they need you.

This app is the companion to Coincide, the free, open-source Mac app for running AI coding agents. It connects straight to your Mac over your own network or Tailscale, with no Coincide server, relay or account in between.

WHAT YOU CAN DO
• Watch threads live: messages, reasoning, tool calls and pictures as they happen.
• Prompt and steer: send a message, steer the running turn or queue the next one, with dictation and photo attachments.
• Approve and answer: allow or deny commands and answer an agent's questions from anywhere.
• Review changes: see each turn's diff and what's uncommitted, then commit, push, and open or merge pull requests.
• Projects, chats and bots: start threads in any project, chat without one, and talk to your bots.
• Scheduled tasks: create, pause and run them.
• Usage: every agent's limits and token use at a glance.
• Settings: change Coincide's settings on your Mac from your phone.
• Notifications when a turn finishes or an agent needs you, on your phone while your Mac is idle.
• The Mac app's themes and its 19 languages, on iPhone and iPad.

WHAT YOU NEED
Coincide on your Mac, free from coincide.dev. In its Settings › General › Remote, turn on Allow Coincide Remote and choose Pair iPhone or iPad, then scan the code with this app. After that, your phone reconnects on the same network or through Tailscale. Your agents run on your Mac with your own accounts.

No Mac at hand? Tap Explore the Demo on the first screen to look around with sample projects and threads.

FREE, PRO AND TIPS
Browsing is free: every project, thread, message, diff, setting and usage chart. Coincide Pro unlocks the actions that run on your Mac, such as sending prompts, approvals, git and pull requests, scheduled tasks, bots and settings. Choose Monthly, Yearly with a 7-day free trial, or a one-time Lifetime purchase. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period, and you can manage or cancel them in your App Store account settings. Optional tips in Settings support development and unlock nothing.

PRIVACY
Everything goes between your devices, and to your agents' providers only when you send a message. No ads, no tracking. The App Store and RevenueCat handle purchases.

Coincide is an independent project, not affiliated with Anthropic, OpenAI, Cursor, xAI or Google. Agent names and logos are trademarks of their owners and are shown only to identify them.

Website: https://coincide.dev
Source code: https://github.com/apoorvdarshan/coincide
Privacy Policy: https://coincide.dev/privacy
Terms of Use: https://coincide.dev/terms
```

## Privacy URL
```
https://coincide.dev/privacy
```

## Support URL
```
https://coincide.dev/faq
```

## Marketing URL
```
https://coincide.dev
```

## Category
```
Primary: Developer Tools
Secondary: Productivity
```

## Age Rating
```
4+
```

No objectionable content, gambling, contests, ads, user-to-user messaging, user-generated content or unrestricted
web access (links open in Safari).

## Content Rights
```
Uses third-party content, with the necessary rights
```

The agents' names and logos, shown only to identify the tools Coincide works with; the agents' replies; and the user's
own projects and threads from their Mac.

## App Privacy (App Store Connect)

Tracking: no. Coincide Remote talks only to the user's own Mac, and to RevenueCat for Coincide Pro and tips, under an
anonymous RevenueCat ID (`CoincideRemote/Pro/ProStore.swift` never calls `logIn` or sets attributes):

- Purchases › Purchase History: not linked to the user, not used for tracking; App Functionality and Analytics.
- Identifiers › User ID (the anonymous RevenueCat ID): not linked to the user, not used for tracking; App
  Functionality.

Nothing else is collected.

## Price and Availability
```
Free, in every territory, and in new territories as App Store Connect adds them
```

## In-App Purchases

[`catalog/products.json`](catalog/products.json) lists them. With `IOS_SUBMIT_REVIEW` on, a release submits the
version with the catalog's Ready to Submit subscriptions and in-app purchases.

## Reviewer Notes
```
Coincide is the iPhone and iPad companion to Coincide, a free, open-source Mac app for running AI coding agents (https://coincide.dev, source code: https://github.com/apoorvdarshan/coincide). With a Mac, you pair once by scanning a code from Coincide's Settings › General › Remote; the phone then connects directly to that Mac over the local network or Tailscale. There is no account, server or sign-in.

To review without a Mac: on the first screen, tap "Explore the Demo". It opens a sample Mac with projects, threads, bots, diffs, scheduled tasks, usage and settings, under a banner that says it's a demo. Nothing in the demo connects to a Mac or the network. "Exit Demo" (in the banner, or Settings › Macs) goes back to the pairing screen.

Coincide Pro (StoreKit through RevenueCat):
- Browsing is free: every project, thread, message, diff, setting and usage chart.
- Every action that would run on the Mac (sending a prompt, approving a command, starting a thread, git and pull request actions, scheduled tasks, bots, Mac settings) opens the Coincide Pro paywall instead. In the demo, tap the message field in any thread, or New Bot on the Bots tab.
- The paywall is also on the first screen ("Coincide Pro Plans") and in Settings › Coincide Pro, with Restore Purchases, the Terms of Use and the Privacy Policy.
- Plans: Coincide Pro Monthly, Coincide Pro Yearly (7-day free trial) and Coincide Pro Lifetime (a one-time purchase).
- Tips: Settings › Support Coincide lists four consumable tips (Small Commit, Clean Diff, Green CI, Ship It). They unlock nothing.

Testing purchases in the sandbox: sign in with a Sandbox Apple Account when the purchase sheet asks, then buy any plan or tip. Once Coincide Pro is active, actions in the demo no longer open the paywall; since it's a demo, they say "This is a demo, so nothing runs" instead of running on a Mac. Settings › Coincide Pro shows the active plan and Manage Subscription; Restore Purchases restores it after a reinstall.

The app shows no ads and does not track users. Agent names and logos (Claude Code, Codex, Cursor, Grok, OpenCode, Antigravity) are shown only to identify the tools the Mac app works with.
```
