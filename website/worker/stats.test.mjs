import assert from "node:assert/strict";
import { test } from "node:test";
import { badge, collectStats, handleStats, summarizeReleases, yearRanges } from "./stats.mjs";

const release = (tag, assets, extra = {}) => ({
  tag_name: tag, draft: false, prerelease: false,
  assets: Object.entries(assets).map(([name, download_count]) => ({ name, download_count })),
  ...extra,
});

const releases = [
  release("v0.2.0", { "Coincide-0.2.0.dmg": 10, "Coincide.dmg": 40, "Coincide-macos-universal.zip": 7, "SHA256SUMS.txt": 99 }),
  release("v0.3.0-beta", { "Coincide.dmg": 5 }, { prerelease: true }),
  release("v0.1.0", { "Coincide-0.1.0.dmg": 3, "Coincide.dmg": 20, "Coincide-macos-universal.zip": 2, "SHA256SUMS.txt": 50 }),
  release("v9.9.9", { "Coincide.dmg": 1000 }, { draft: true }),
  release("ios-v0.1.0", { "Coincide.zip": 500 }),
];

test("adds DMG and ZIP downloads of published Mac releases only", () => {
  assert.deepEqual(summarizeReleases(releases), { downloads: 87, releases: 3, latest: "v0.2.0" });
  assert.deepEqual(summarizeReleases([]), { downloads: 0, releases: 0, latest: null });
});

test("splits the npm range into years", () => {
  assert.deepEqual(yearRanges("2026-11-01", "2026-11-01"), [["2026-11-01", "2026-11-01"]]);
  assert.deepEqual(yearRanges("2026-11-01", "2028-02-10"), [
    ["2026-11-01", "2027-10-31"], ["2027-11-01", "2028-02-10"],
  ]);
});

test("makes a shields.io badge", () => {
  assert.deepEqual(badge({ downloads: 12345 }),
    { schemaVersion: 1, label: "downloads", message: "12,345", color: "blue", cacheSeconds: 3600 });
  assert.equal(badge(null).message, "unavailable");
  assert.equal(badge(null).isError, true);
});

function fakeFetch({ github = releases, githubStatus = 200, npm = { downloads: [{ downloads: 4 }, { downloads: 6 }] }, npmStatus = 200 } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init });
    if (url.startsWith("https://api.github.com/")) return new Response(JSON.stringify(github), { status: githubStatus });
    if (url.startsWith("https://api.npmjs.org/")) return new Response(JSON.stringify(npm), { status: npmStatus });
    throw new Error(`unexpected ${url}`);
  };
  return { impl, calls };
}

test("adds npm downloads to the GitHub ones for the total", async () => {
  const { impl, calls } = fakeFetch();
  const stats = await collectStats({}, { fetchImpl: impl, now: new Date("2026-12-01T10:00:00Z") });
  assert.equal(stats.github, 87);
  assert.equal(stats.npm, 10);
  assert.equal(stats.downloads, 97);
  assert.equal(stats.latest, "v0.2.0");
  assert.ok(calls.some(({ url }) => url === "https://api.npmjs.org/downloads/range/2026-11-01:2026-12-01/coincide-dev"));
  assert.equal(calls.find(({ url }) => url.includes("github")).init.headers.Authorization, undefined);
});

test("counts an unpublished npm package as 0 and an npm outage as unknown", async () => {
  assert.equal((await collectStats({}, { fetchImpl: fakeFetch({ npmStatus: 404 }).impl })).npm, 0);
  const outage = await collectStats({}, { fetchImpl: fakeFetch({ npmStatus: 500 }).impl });
  assert.equal(outage.npm, null);
  assert.equal(outage.downloads, 87, "an npm outage leaves the GitHub count");
});

test("sends the optional GitHub token in a header", async () => {
  const { impl, calls } = fakeFetch();
  await collectStats({ GITHUB_TOKEN: "t" }, { fetchImpl: impl });
  const github = calls.find(({ url }) => url.includes("github"));
  assert.equal(github.init.headers.Authorization, "Bearer t");
  assert.ok(!github.url.includes("t@") && !github.url.includes("token"));
});

function fakeCache() {
  const entries = new Map();
  return {
    entries,
    async match(request) { return entries.get(request.url)?.clone(); },
    async put(request, response) { entries.set(request.url, response); },
  };
}
const ctx = { waitUntil: (promise) => promise };

test("serves the stats and badge from the cache", async () => {
  const cache = fakeCache();
  const { impl, calls } = fakeFetch();
  const first = await handleStats(new Request("https://coincide.dev/api/stats"), {}, ctx, { fetchImpl: impl, cache });
  assert.equal(first.status, 200);
  assert.equal((await first.json()).downloads, 97);
  const count = calls.length;
  const badgeResponse = await handleStats(new Request("https://coincide.dev/api/stats/badge"), {}, ctx, { fetchImpl: impl, cache });
  assert.deepEqual(await badgeResponse.json(),
    { schemaVersion: 1, label: "downloads", message: "97", color: "blue", cacheSeconds: 3600 });
  assert.equal(calls.length, count, "the badge reused the cached numbers");
});

test("fails soft when GitHub is unavailable", async () => {
  const cache = fakeCache();
  const { impl } = fakeFetch({ githubStatus: 403 });
  const stats = await handleStats(new Request("https://coincide.dev/api/stats"), {}, ctx, { fetchImpl: impl, cache });
  assert.equal(stats.status, 503);
  assert.deepEqual(await stats.json(), { error: "unavailable" });
  const badgeResponse = await handleStats(new Request("https://coincide.dev/api/stats/badge"), {}, ctx, { fetchImpl: impl, cache });
  assert.equal(badgeResponse.status, 200);
  assert.equal((await badgeResponse.json()).message, "unavailable");
});

test("answers only GET and HEAD", async () => {
  const response = await handleStats(new Request("https://coincide.dev/api/stats", { method: "POST" }), {}, ctx, { cache: fakeCache() });
  assert.equal(response.status, 405);
});
