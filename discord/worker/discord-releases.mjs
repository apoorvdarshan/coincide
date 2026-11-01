/**
 * Hourly announcement of newly published Coincide GitHub releases in #announcements.
 *
 * Coincide ships through GitHub Releases only. Drafts are never announced. The first
 * successful check records every release that is already public without posting, so
 * enabling this never announces a backlog. Pre-releases are public and are announced,
 * marked as such.
 */
const REPOSITORY = "apoorvdarshan/coincide";
const RELEASES_API = `https://api.github.com/repos/${REPOSITORY}/releases?per_page=30`;
const RELEASE_URL_PREFIX = `https://github.com/${REPOSITORY}/releases/`;
const STATE_PREFIX = "releases:v1";
const SNOWFLAKE = /^\d{17,20}$/;
/** Releases published this long before seeding still count as already announced. */
const SEED_GRACE_MS = 60 * 60 * 1000;
const MAX_POSTS_PER_RUN = 3;
const MAX_NOTES_CHARS = 1_400;

class ReleaseCheckError extends Error {
  constructor(code) {
    super(code);
    this.name = "ReleaseCheckError";
  }
}

function config(env, name) {
  return typeof env[name] === "string" ? env[name].trim() : "";
}

/** Text safe to post: no control characters, HTML comments or images; capped length. */
export function releaseNotes(markdown) {
  if (typeof markdown !== "string") return "";
  const cleaned = markdown
    .replace(/<!--[\s\S]*?(?:-->|$)/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "")
    .replace(/\r\n?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  if (cleaned.length <= MAX_NOTES_CHARS) return cleaned;
  const cut = cleaned.slice(0, MAX_NOTES_CHARS);
  const lineBreak = cut.lastIndexOf("\n");
  return `${(lineBreak > MAX_NOTES_CHARS / 2 ? cut.slice(0, lineBreak) : cut).trimEnd()}\n…`;
}

function plainName(value) {
  return typeof value === "string" ? value.replace(/[\u0000-\u001f\u007f*_`~|<>@#[\]]/g, "").trim().slice(0, 80) : "";
}

export function announcementText(release) {
  const name = plainName(release.name) || plainName(release.tag_name);
  const title = /coincide/i.test(name) ? name : `Coincide ${name}`;
  const notes = releaseNotes(release.body);
  return [
    `**${title}** is out${release.prerelease ? " (pre-release)" : ""}.`,
    notes,
    `Download and full release notes: <${release.html_url}>`,
  ].filter(Boolean).join("\n\n");
}

/** Only fully published releases of this repository with a verifiable identity. */
export function publishedReleases(payload) {
  if (!Array.isArray(payload)) throw new ReleaseCheckError("github_releases_unexpected");
  return payload
    .filter((release) => release && release.draft === false
      && Number.isSafeInteger(release.id) && release.id > 0
      && typeof release.published_at === "string" && Number.isFinite(Date.parse(release.published_at))
      && typeof release.html_url === "string" && release.html_url.startsWith(RELEASE_URL_PREFIX)
      && (plainName(release.name) || plainName(release.tag_name)))
    .sort((a, b) => Date.parse(a.published_at) - Date.parse(b.published_at));
}

async function request(url, init, code, fetchImpl) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  try {
    // Workers supports manual redirects; the non-2xx check below rejects them without following.
    const response = await fetchImpl(url, { ...init, redirect: "manual", signal: controller.signal });
    if (!response.ok) {
      await response.body?.cancel();
      throw new ReleaseCheckError(`${code}_http_${response.status}`);
    }
    const text = await response.text();
    if (text.length > 2_000_000) throw new ReleaseCheckError(`${code}_response_too_large`);
    return text ? JSON.parse(text) : null;
  } catch (error) {
    if (error instanceof ReleaseCheckError) throw error;
    throw new ReleaseCheckError(`${code}_request_failed`);
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchReleases(env, fetchImpl) {
  const token = config(env, "DISCORD_GITHUB_TOKEN");
  return publishedReleases(await request(RELEASES_API, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "coincide-discord-releases",
      "X-GitHub-Api-Version": "2022-11-28",
      // Authenticated reads avoid the shared unauthenticated rate limit of Cloudflare's egress IPs.
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  }, "github_releases", fetchImpl));
}

async function postAnnouncement(token, channel, release, fetchImpl) {
  await request(`https://discord.com/api/v10/channels/${channel}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bot ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "DiscordBot (https://coincide.dev, 1)",
    },
    body: JSON.stringify({
      content: announcementText(release),
      allowed_mentions: { parse: [] },
      flags: 4, // No link preview cards.
      // Discord drops a repeat with the same nonce for a few minutes, covering a retried run.
      nonce: `release-${release.id}`.slice(0, 25),
      enforce_nonce: true,
    }),
  }, "discord_post", fetchImpl);
}

/**
 * Returns what happened, for logs and tests: disabled, seeded, or checked with a count of
 * posts. Throws ReleaseCheckError when GitHub, Discord or KV fail; nothing is marked as
 * announced unless Discord accepted the post, so the next hourly run retries it.
 */
export async function announceReleases(env, fetchImpl = fetch) {
  const token = config(env, "DISCORD_BOT_TOKEN");
  const channel = config(env, "DISCORD_ANNOUNCEMENTS_CHANNEL_ID");
  const state = env.DISCORD_STATE;
  if (!token || !SNOWFLAKE.test(channel) || !state) return { status: "disabled" };
  const releases = await fetchReleases(env, fetchImpl);
  const seenKey = (release) => `${STATE_PREFIX}:seen:${release.id}`;
  const seededAt = Number(await state.get(`${STATE_PREFIX}:seeded`));
  if (!Number.isFinite(seededAt) || seededAt <= 0) {
    for (const release of releases) await state.put(seenKey(release), "seed");
    await state.put(`${STATE_PREFIX}:seeded`, String(Date.now()));
    console.log("discord_releases_seeded", JSON.stringify({ releases: releases.length }));
    return { status: "seeded", releases: releases.length };
  }
  let posted = 0;
  for (const release of releases) {
    if (posted >= MAX_POSTS_PER_RUN) break;
    if (await state.get(seenKey(release))) continue;
    // A release published before seeding that only now shows up (for example after newer
    // ones were deleted) is old news, not a new release.
    if (Date.parse(release.published_at) < seededAt - SEED_GRACE_MS) {
      await state.put(seenKey(release), "old");
      continue;
    }
    await postAnnouncement(token, channel, release, fetchImpl);
    await state.put(seenKey(release), "posted");
    posted += 1;
    console.log("discord_release_announced", JSON.stringify({ id: release.id }));
  }
  return { status: "checked", posted };
}

/** Scheduled entry point: logs a safe error code instead of throwing raw errors. */
export async function runReleaseAnnouncements(env) {
  try {
    await announceReleases(env);
  } catch (error) {
    // Never log upstream bodies, credentials or arbitrary exception text.
    console.error("discord_release_check_failed", error instanceof ReleaseCheckError ? error.message : "unexpected_failure");
  }
}
