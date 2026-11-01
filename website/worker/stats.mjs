// Public download counts for coincide.dev: GET /api/stats (JSON) and GET /api/stats/badge (a shields.io endpoint badge,
// https://img.shields.io/endpoint?url=https://coincide.dev/api/stats/badge). Both come from public APIs, are cached at
// each Cloudflare location for an hour, and record nothing about the visitor.
//
// What is counted, without counting anything twice:
//   downloads  Downloads of a release's DMG or ZIP from GitHub Releases, over every published release. Every way to
//              install fetches one of these: the website's Download button and Homebrew the DMG (Coincide.dmg and
//              Coincide-<version>.dmg), `npx coincide-dev` and the in-app updater the ZIP. SHA256SUMS.txt isn't
//              counted. These are downloads, not people: one Mac can download several times, and updates count too.
//   npm        Downloads of the coincide-dev package since its first publish. Each install through it also fetches the
//              ZIP above, so this number is reported on its own and never added to downloads.

export const REPOSITORY = "apoorvdarshan/coincide";
export const NPM_PACKAGE = "coincide-dev";
// Before the package existed; npm's range API takes at most 18 months per request, so the total is read in years.
export const NPM_SINCE = "2026-11-01";
const CACHE_SECONDS = 3600;
const ERROR_CACHE_SECONDS = 300;
const COUNTED = /\.(dmg|zip)$/i;

/** Adds up the DMG and ZIP downloads of published releases, and finds the newest stable release. */
export function summarizeReleases(releases) {
  let downloads = 0;
  let published = 0;
  let latest = null;
  for (const release of releases) {
    if (release.draft) continue;
    published++;
    if (!release.prerelease && !latest) latest = release.tag_name;
    for (const asset of release.assets ?? []) {
      if (COUNTED.test(asset.name) && Number.isFinite(asset.download_count)) downloads += asset.download_count;
    }
  }
  return { downloads, releases: published, latest };
}

/** The date ranges, at most a year each, from `since` to `today` (YYYY-MM-DD, inclusive). */
export function yearRanges(since, today) {
  const ranges = [];
  let start = new Date(`${since}T00:00:00Z`);
  const end = new Date(`${today}T00:00:00Z`);
  while (start <= end) {
    const stop = new Date(Math.min(end.getTime(), Date.UTC(start.getUTCFullYear() + 1, start.getUTCMonth(), start.getUTCDate() - 1)));
    ranges.push([start.toISOString().slice(0, 10), stop.toISOString().slice(0, 10)]);
    start = new Date(stop.getTime() + 86_400_000);
  }
  return ranges;
}

export function formatCount(count) {
  return new Intl.NumberFormat("en-US").format(count);
}

/** A shields.io endpoint badge for the downloads total, or a grey "unavailable" one. */
export function badge(stats) {
  if (!stats || !Number.isFinite(stats.downloads)) {
    return { schemaVersion: 1, label: "downloads", message: "unavailable", color: "lightgrey", isError: true, cacheSeconds: ERROR_CACHE_SECONDS };
  }
  return { schemaVersion: 1, label: "downloads", message: formatCount(stats.downloads), color: "blue", cacheSeconds: CACHE_SECONDS };
}

async function fetchReleases(env, fetchImpl) {
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "coincide-website-stats",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  // Optional: a token with no permissions only raises GitHub's rate limit (Workers share addresses).
  if (env.GITHUB_TOKEN) headers.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  const releases = [];
  for (let page = 1; page <= 10; page++) {
    const response = await fetchImpl(`https://api.github.com/repos/${REPOSITORY}/releases?per_page=100&page=${page}`, { headers });
    if (!response.ok) throw new Error(`github_${response.status}`);
    const batch = await response.json();
    if (!Array.isArray(batch)) throw new Error("github_unexpected");
    releases.push(...batch);
    if (batch.length < 100) break;
  }
  return releases;
}

async function fetchNpmDownloads(today, fetchImpl) {
  let total = 0;
  for (const [start, end] of yearRanges(NPM_SINCE, today)) {
    const response = await fetchImpl(`https://api.npmjs.org/downloads/range/${start}:${end}/${NPM_PACKAGE}`, {
      headers: { "User-Agent": "coincide-website-stats" },
    });
    if (response.status === 404) continue; // not published yet, or nothing in that range
    if (!response.ok) throw new Error(`npm_${response.status}`);
    const body = await response.json();
    for (const day of body.downloads ?? []) if (Number.isFinite(day.downloads)) total += day.downloads;
  }
  return total;
}

/** Fresh numbers. GitHub must answer; npm failing only leaves npm null. */
export async function collectStats(env, { fetchImpl = fetch, now = new Date() } = {}) {
  const today = now.toISOString().slice(0, 10);
  const [releases, npm] = await Promise.all([
    fetchReleases(env, fetchImpl),
    fetchNpmDownloads(today, fetchImpl).catch(() => null),
  ]);
  return { ...summarizeReleases(releases), npm, updated: now.toISOString() };
}

function json(body, seconds, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": `public, max-age=${seconds}`,
      "access-control-allow-origin": "*",
    },
  });
}

/** Serves /api/stats and /api/stats/badge from this location's cache, refreshing at most hourly. */
export async function handleStats(request, env, ctx, { fetchImpl = fetch, cache = caches.default } = {}) {
  const url = new URL(request.url);
  if (request.method !== "GET" && request.method !== "HEAD") return new Response("method not allowed", { status: 405 });
  const key = new Request(`${url.origin}/api/stats?cache=v1`);
  let stats = null;
  const cached = await cache.match(key);
  if (cached) stats = await cached.json();
  if (!stats) {
    try {
      stats = await collectStats(env, { fetchImpl });
      ctx.waitUntil(cache.put(key, json(stats, CACHE_SECONDS)));
    } catch (error) {
      console.log("stats_unavailable", String(error?.message ?? error));
      const failure = { error: "unavailable" };
      ctx.waitUntil(cache.put(key, json(failure, ERROR_CACHE_SECONDS)));
      stats = failure;
    }
  }
  const ok = !stats.error;
  if (url.pathname === "/api/stats/badge") return json(badge(ok ? stats : null), ok ? CACHE_SECONDS : ERROR_CACHE_SECONDS);
  return ok ? json(stats, CACHE_SECONDS) : json(stats, ERROR_CACHE_SECONDS, 503);
}
