# Janus, the Coincide Discord bot

Janus runs the Coincide community server: <https://discord.gg/DETrbhDVqw> (also <https://discord.coincide.dev>, which redirects there). It is a single Cloudflare Worker, `coincide-discord`, with no npm dependencies. Discord delivers slash commands to it as signed HTTP requests, and cron triggers run everything else, so nothing depends on a Mac or an always-on process.

| Feature | How it works |
| --- | --- |
| `/ask question:…` | Sends the question to Google Gemini with a fixed description of Coincide and replies in the channel. Up to 1,500 characters. 60-second cooldown per member. |
| `/bug report:…` | Opens a **public** `bug` issue in `apoorvdarshan/coincide`. Up to 4,000 characters. |
| `/feature report:…` | Opens a **public** `enhancement` issue there. Up to 4,000 characters. |
| Issue-closure replies | When an issue opened with `/bug` or `/feature` closes, Janus replies to its original response and mentions only the person who reported it. |
| Release announcements | Every hour, newly published GitHub releases are posted in #announcements. |
| Spam moderation | Every minute, new messages are checked against fixed spam rules ([MODERATION.md](MODERATION.md)). |

## Server and IDs

These are public identifiers, not secrets.

| What | Value |
| --- | --- |
| Server "Coincide" (owner: Apoorv, `823100527675965480`) | `1566352780862427258` |
| Application and bot user "Janus" (private bot, guild install only) | `1566350650839797780` |
| Interactions public key | in [`wrangler.jsonc`](wrangler.jsonc) |
| Permanent invite (no expiry, unlimited uses, lands in #welcome) | <https://discord.gg/DETrbhDVqw> |
| Worker, custom domain | `coincide-discord`, `https://discord.coincide.dev` |
| Interactions endpoint | `https://discord.coincide.dev/api/discord/interactions` |
| GitHub issues webhook (`issues` events, JSON) | `https://discord.coincide.dev/api/discord/github-issues` |
| KV namespace `COINCIDE_DISCORD_STATE` (binding `DISCORD_STATE`) | `076da39ea1cd450eab1b8e72b12cf047` |

| Channel | ID | Purpose |
| --- | --- | --- |
| #welcome | `1566353941485064212` | Welcome text and rules. Read-only. |
| #announcements | `1566353944077279284` | Releases and news. Read-only; Janus posts releases here. |
| #general | `1566352791751098368` | Chat. Discord's join messages go here. |
| #help | `1566353949336797275` | Usage questions; `/ask` works anywhere. |
| #bug-reports | `1566353951299862598` | `/bug`, for the Mac app and Coincide Remote. |
| #feature-requests | `1566353955494039602` | `/feature`. |
| #mod-log | `1566353958543560714` | Private moderation log: only the owner and Janus. |

Channel links have the form `https://discord.com/channels/1566352780862427258/<channel ID>` and work only for members. Links meant for people who haven't joined should use the invite.

The server requires a verified email, scans media from all members, and notifies on mentions only. Discord's native AutoMod also blocks suspected spam, messages with 15 or more mentions (with raid protection), and the sexual-content and slur keyword presets, alerting #mod-log. The hoisted Developer role belongs to the owner.

## Secrets

Set on the Worker with `wrangler secret put <NAME>` from this folder. Never commit them. The bot token and GitHub token are also in the owner's password manager (`API · Coincide Discord bot`).

| Secret | Used for |
| --- | --- |
| `DISCORD_BOT_TOKEN` | Release posts, issue-closure replies and moderation. Janus's own token; never another app's. |
| `DISCORD_GITHUB_TOKEN` | Creating `/bug` and `/feature` issues and reading releases. A fine-grained token limited to `apoorvdarshan/coincide` with **Issues: read and write** (plus the mandatory Metadata: read). It expires on 2027-11-01; replace it before then. |
| `DISCORD_GITHUB_WEBHOOK_SECRET` | Verifies the SHA-256 signature of the repository's issues webhook. The same random value is set on the webhook. |
| `DISCORD_GEMINI_API_KEY` | `/ask`, and optionally organizing reports. A Gemini key dedicated to Janus, separate from any other app or bot. Without it, `/ask` replies privately that AI answers are not configured yet, and reports are filed with their original text only. |

## Deploy

```bash
cd discord
wrangler deploy
```

This uploads the Worker, keeps the `discord.coincide.dev` custom domain, and updates the three cron triggers. Secrets are kept across deploys. The bot's settings (`wrangler.jsonc` `vars`) are public values only. `DISCORD_BOT_NAME` is the name Janus uses for itself in replies.

Tests run in GitHub Actions (`.github/workflows/discord.yml`, `node --test discord/worker/*.test.mjs`) when anything in this folder changes.

## Register commands

Commands are registered for the Coincide server only. Put the bot token in an env file outside the repository, readable only by you, then from the repository root:

```bash
node --env-file="$HOME/.config/coincide/discord.env" discord/scripts/register-commands.mjs
```

The script checks that the token belongs to Janus and can see the server, then upserts `/ask`, `/bug` and `/feature` one at a time; other commands are left alone. `--dry-run` prints the definitions without credentials or network access.

## Discord application settings

In the [Developer Portal](https://discord.com/developers/applications/1566350650839797780/information) (or with `PATCH /applications/@me` and the bot token):

- Interactions Endpoint URL: `https://discord.coincide.dev/api/discord/interactions`. Discord checks it with a signed PING when it is saved.
- Public Bot: off. Installation: guild install only, no install link.
- Terms of Service URL: `https://coincide.dev/terms#janus`. Privacy Policy URL: `https://coincide.dev/privacy#discord` (portal only).
- Message Content intent: on (the limited flag, needed by moderation). Presence and Server Members intents: off.
- Name, avatar and description can be changed with `PATCH /users/@me` (bot username and avatar) and `PATCH /applications/@me` (icon, description); the application name changes only in the portal.

Janus's role holds View Channels, Send Messages, Send Messages in Threads, Embed Links, Read Message History, Manage Messages, Ban Members and Timeout Members for moderation, plus Manage Server, Manage Channels, Manage Roles and Create Invite so the server can be managed through the API. To drop the management permissions, untick them on the role in Server Settings › Roles.

## Release announcements

The hourly run (`23 * * * *`) reads the newest 30 releases of `apoorvdarshan/coincide`. Drafts are ignored; pre-releases are public, so they are announced and marked "(pre-release)". The first successful run records every release that is already published without posting anything. After that, each new release is posted once with its name, the start of its notes and a link, at most three per run, oldest first. A release is marked as announced only after Discord accepts the post, so a failed post is retried an hour later with the same message nonce. A release published before the first run that only shows up later is not treated as new.

KV keys: `releases:v1:seeded` (time of the first run) and `releases:v1:seen:<release ID>`. To announce a release again, delete its `seen` key; to start over, delete them all, and the next run seeds again without posting.

## Issue-closure replies

`/bug` and `/feature` privately store the issue number with the reporter's Discord user ID, the channel ID and the ID of Janus's response, under `issue-close:link:<issue number>` for two years. No report text, usernames or interaction tokens are stored. When GitHub sends a signed `issues` `closed` event for `apoorvdarshan/coincide`, Janus replies to that response in the same channel, mentions only the reporter, and says whether the issue was closed as completed, not planned, a duplicate, or without a reason. It never claims a fix has shipped in a release. Issues without a stored link (anything not opened through Janus) are ignored.

Events are queued in KV before the webhook is acknowledged, delivered right away, and retried every five minutes in batches of 25 for up to seven days (`issue-close:pending:<number>:<closed at>`). A completion marker (`issue-close:sent:…`) and a deterministic Discord nonce prevent repeat replies to the same closure; a later closure after reopening can notify again. KV is eventually consistent, so this is best-effort, not exactly-once. If queueing fails the webhook answers 503; redeliver it from the repository's webhook settings once things recover. Delete an `issue-close:link:` key to stop notifications for that report.

## Data handling

The published [Privacy Policy](https://coincide.dev/privacy#discord) and [Terms](https://coincide.dev/terms#janus) cover the server and Janus; they are also the application's Privacy Policy and Terms of Service URLs.

- Only text people submit with a command is sent to Google Gemini. Gemini's own terms govern what it keeps; no retention promise is made beyond them.
- `/bug` and `/feature` publish the report, unchanged, plus any AI summary in a public GitHub issue. Discord usernames and IDs are not added, and `@` mentions are neutralized.
- Cooldown and replay markers in KV are SHA-256 hashes of IDs, kept for at most two days. Reports share a wait per member that starts at 10 minutes, doubles with each report up to a day, and resets after two days without one.
- Logs record event names and error categories, never submitted text, tokens or upstream response bodies.

## Recovery

- **Commands fail with "not configured"**: check the secrets above with `wrangler secret list`, then redeploy.
- **Interactions fail entirely**: confirm `https://discord.coincide.dev/api/discord/interactions` answers a bare POST with 401, and that the endpoint URL is still set on the application.
- **Bot token leaked or reset**: reset it in the portal, then `wrangler secret put DISCORD_BOT_TOKEN` and update the password manager entry.
- **GitHub token expired**: create a new fine-grained token with the same scope and `wrangler secret put DISCORD_GITHUB_TOKEN`. Until then `/bug` and `/feature` reply that they couldn't confirm the issue, and the release check logs `github_releases_http_401`.
- **Webhook**: its deliveries are listed in the repository's Settings › Webhooks. Rotate the secret by setting a new random value on both the webhook and `DISCORD_GITHUB_WEBHOOK_SECRET`.
- **Logs**: `wrangler tail coincide-discord`, or the Worker's Observability tab.
