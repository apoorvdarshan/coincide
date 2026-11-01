# Automatic spam moderation

The `DiscordModeration` Durable Object in the `coincide-discord` Worker scans the Coincide server once a minute. The cron trigger calls it through a private binding; there is no public moderation endpoint and nothing runs on a Mac. [`worker/discord-moderation.mjs`](worker/discord-moderation.mjs) and its tests are kept identical to the copies in Fud AI and Verceltics, so a fix made in one should be copied to all three. Each deployment has its own bot token, Durable Object, server ID and private log.

## Policy

- First incident: delete the message, warn in its channel, and time the member out for 10 minutes.
- Second incident after that timeout: delete, warn, and time out for 24 hours.
- Third incident after that timeout: delete and ban automatically. There is no approval queue, and the ban does not delete the member's other messages.
- Thirty days without a strike resets the count. Bans are never lifted automatically.
- More spam during an active timeout is removed without another strike or a longer timeout. Longer existing timeouts are never shortened. Messages from before moderation was first turned on are ignored.
- Exempt before anything happens: Apoorv's user ID `823100527675965480`, the server owner, bots, webhooks, system messages, administrators, and members whose role is at or above Janus's role.

Triggers are narrow and deterministic:

1. Six distinct non-bot user mentions, or three role mentions, in one message.
2. Five identical messages of at least 20 characters within 60 seconds.
3. Three identical messages with a link and an explicit solicitation ("join my", "buy now", "hire me" and similar) within five minutes.
4. A message that opens with a free-Nitro claim/get line and links outside `discord.com` or `discord.gift`.

Matching ignores case and whitespace, across channels and regardless of scan order. Quoted text and code blocks are excluded from the text rules, so pasted logs and GitHub usernames are fine. A single possible promotion only adds a private flag to #mod-log, at most once per member per day, with no strike or warning. There is no AI judgment, no banned-word list, and links are never followed. This is not complete scam detection.

Discord's native AutoMod rules (see [README.md](README.md)) block some messages before they are sent; those never reach this scanner and never count as strikes.

## Configuration

Worker variables in [`wrangler.jsonc`](wrangler.jsonc): `DISCORD_MODERATION_ENABLED` must be `true` (anything else stops scanning), plus `DISCORD_GUILD_ID`, `DISCORD_APPLICATION_ID` and `DISCORD_MODERATION_LOG_CHANNEL_ID` (#mod-log). The `DISCORD_MODERATION` binding is a SQLite-backed Durable Object from migration `discord-moderation-v1`. It uses the Worker's `DISCORD_BOT_TOKEN`.

Every scan first checks that the server owner is `823100527675965480`, the token belongs to Janus, the application has the Message Content intent, Janus can delete messages, time members out and ban, and #mod-log is private (`@everyone` denied View Channel, only the owner and Janus allowed). If any check fails, the scan stops and logs the reason; nothing is enforced on a misconfigured server. Channels Janus can't read are skipped with a warning.

To turn moderation off, set `DISCORD_MODERATION_ENABLED` to `false` and redeploy. That does not undo existing timeouts or bans. A healthy scan logs `discord_moderation_scan_ok` (`wrangler tail coincide-discord`).

## State and delivery

One scan runs at a time. A transaction saves the message cursor, the strike and the pending action together before anything is sent to Discord, and each finished step is checkpointed, so a retry never adds a strike or restarts a timeout. Deletes and bans are idempotent; warnings and log lines use deterministic nonces. A 429 response pauses scanning until Discord's retry time. Other failures are retried up to five times; then the strike is rolled back if the punishment wasn't confirmed, and a failure notice goes to #mod-log. An expired timeout is abandoned rather than applied late.

Each scan reads up to 100 new messages per text or announcement channel and active thread, within a 45-second budget, rotating the starting channel. Enforcement is therefore about a minute behind, not instant. Edited messages, messages deleted before a scan, archived threads, DMs, voice and attachments are not checked, and the first copies of a repeated burst are not removed retroactively.

## Data kept

No message text, bot token or interaction token is stored. Each member record holds IDs, up to 30 content fingerprints (SHA-256) with timestamps, used only within a five-minute window, plus strike counters; records are deleted after 30 days without a scanned message. The cursors, the activation time and the latest failure marker persist. #mod-log lines contain user IDs, reasons and message links, never copied text, and stay until the owner deletes them.

## Appeals

Members appeal to the server owner. To lift a penalty, remove the timeout or ban in Discord. To also clear a member's strikes, turn moderation off, deploy a reviewed one-off change inside the Durable Object that deletes `user:<Discord user ID>` (and a matching `pending` action), then remove that change and turn moderation back on. There is no public reset endpoint. Don't delete `started` or the cursor keys unless you mean to reset the activation point.

Never test enforcement with synthetic spam against real members. The test suite covers exemptions, false positives, bursts, escalation and resets, longer timeouts, pagination, flags, disabled mode, missing permissions or intent, storage failures, retries and nonces.
