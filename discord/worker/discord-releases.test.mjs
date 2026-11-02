import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { announceReleases, announcementText, publishedReleases, releaseNotes, runReleaseAnnouncements } from "./discord-releases.mjs";

const CHANNEL = "1566353944077279284";
const NOW = Date.parse("2026-11-01T08:00:00Z");
const nativeNow = Date.now;
afterEach(() => { Date.now = nativeNow; });

function kv() {
  const data = new Map();
  return {
    data,
    async get(key) { return data.get(key) ?? null; },
    async put(key, value) { data.set(key, value); },
  };
}

const environment = (extra = {}) => ({
  DISCORD_BOT_TOKEN: "unit-bot-token", DISCORD_ANNOUNCEMENTS_CHANNEL_ID: CHANNEL,
  DISCORD_GITHUB_TOKEN: "unit-github-token", DISCORD_STATE: kv(), ...extra,
});

let nextId = 100;
function release(fields = {}) {
  nextId += 1;
  return {
    id: nextId, name: `v0.${nextId}.0`, tag_name: `v0.${nextId}.0`, draft: false, prerelease: false,
    published_at: new Date(NOW).toISOString(), html_url: `https://github.com/apoorvdarshan/coincide/releases/tag/v0.${nextId}.0`,
    body: "## What's new\n- Faster startup", ...fields,
  };
}

/** A fake GitHub releases API and Discord channel. `releases` is read on every call. */
function upstream(state, { discordStatus = 200, githubStatus = 200 } = {}) {
  const posts = [];
  const github = [];
  const fetchImpl = async (url, init) => {
    assert.equal(init.redirect, "manual");
    const { hostname, pathname } = new URL(url);
    if (hostname === "api.github.com" && pathname === "/repos/apoorvdarshan/coincide/releases") {
      github.push(init);
      return githubStatus === 200 ? Response.json(state.releases) : new Response("nope", { status: githubStatus });
    }
    if (hostname === "discord.com" && pathname === `/api/v10/channels/${CHANNEL}/messages`) {
      assert.equal(init.headers.Authorization, "Bot unit-bot-token");
      posts.push(JSON.parse(init.body));
      return discordStatus === 200 ? Response.json({ id: "1" }) : new Response("{}", { status: discordStatus });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  return { posts, github, fetchImpl };
}

test("stays disabled without a bot token, channel or state, and makes no requests", async () => {
  const fetchImpl = async () => { throw new Error("must not fetch"); };
  for (const missing of [{ DISCORD_BOT_TOKEN: "" }, { DISCORD_ANNOUNCEMENTS_CHANNEL_ID: "general" }, { DISCORD_STATE: undefined }]) {
    assert.deepEqual(await announceReleases(environment(missing), fetchImpl), { status: "disabled" });
  }
});

test("the first check seeds existing releases without announcing a backlog", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [release(), release({ prerelease: true })] };
  const { posts, github, fetchImpl } = upstream(state);
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "seeded", releases: 2 });
  assert.equal(posts.length, 0);
  assert.equal(github[0].headers.Authorization, "Bearer unit-github-token");
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 0 });
  assert.equal(posts.length, 0);
});

test("an empty repository seeds too, so its first release is announced exactly once", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  const { posts, fetchImpl } = upstream(state);
  assert.equal((await announceReleases(env, fetchImpl)).status, "seeded");
  const first = release({ prerelease: true, published_at: new Date(NOW + 60_000).toISOString() });
  state.releases = [first];
  Date.now = () => NOW + 3_600_000;
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 1 });
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 0 });
  assert.equal(posts.length, 1);
  assert.match(posts[0].content, new RegExp(`^\\*\\*Coincide ${first.name.replaceAll(".", "\\.")}\\*\\* is out \\(pre-release\\)\\.`));
  assert.match(posts[0].content, /Faster startup/);
  assert.match(posts[0].content, new RegExp(`<${first.html_url}>`));
  assert.deepEqual(posts[0].allowed_mentions, { parse: [] });
  assert.equal(posts[0].enforce_nonce, true);
  assert.equal(posts[0].nonce, `release-${first.id}`);
});

test("drafts and foreign or malformed entries are never announced", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  const { posts, fetchImpl } = upstream(state);
  await announceReleases(env, fetchImpl);
  state.releases = [
    release({ draft: true }),
    release({ html_url: "https://github.com/someone/else/releases/tag/v1" }),
    release({ published_at: null }),
    release({ name: "", tag_name: "" }),
  ];
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 0 });
  assert.equal(posts.length, 0);
});

test("a failed Discord post is retried on the next run instead of being marked announced", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  await announceReleases(env, upstream(state).fetchImpl);
  state.releases = [release()];
  const failing = upstream(state, { discordStatus: 503 });
  await assert.rejects(announceReleases(env, failing.fetchImpl), /discord_post_http_503/);
  const working = upstream(state);
  assert.deepEqual(await announceReleases(env, working.fetchImpl), { status: "checked", posted: 1 });
  assert.equal(working.posts[0].nonce, failing.posts[0].nonce);
});

test("a GitHub failure neither seeds nor posts", async () => {
  const env = environment();
  const { posts, fetchImpl } = upstream({ releases: [release()] }, { githubStatus: 403 });
  await assert.rejects(announceReleases(env, fetchImpl), /github_releases_http_403/);
  assert.equal(env.DISCORD_STATE.data.size, 0);
  assert.equal(posts.length, 0);
});

test("an old release that resurfaces after seeding is not announced as new", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  const { posts, fetchImpl } = upstream(state);
  await announceReleases(env, fetchImpl);
  state.releases = [release({ published_at: "2026-09-01T00:00:00Z" })];
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 0 });
  assert.equal(posts.length, 0);
});

test("at most three announcements per run, oldest first", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  const { posts, fetchImpl } = upstream(state);
  await announceReleases(env, fetchImpl);
  const later = (minutes) => new Date(NOW + minutes * 60_000).toISOString();
  state.releases = [release({ published_at: later(4) }), release({ published_at: later(1) }), release({ published_at: later(3) }), release({ published_at: later(2) })];
  assert.equal((await announceReleases(env, fetchImpl)).posted, 3);
  assert.equal((await announceReleases(env, fetchImpl)).posted, 1);
  const order = posts.map((post) => state.releases.find((r) => post.nonce === `release-${r.id}`).published_at);
  assert.deepEqual(order, [...order].sort());
});

test("release text is cleaned and capped, and names cannot inject markup or mentions", () => {
  const notes = releaseNotes(`<!-- hidden -->Intro\r\n![shot](https://x/y.png)\n\n\n\nMore\u0007${"x".repeat(2000)}`);
  assert.ok(!notes.includes("hidden") && !notes.includes("![") && !notes.includes("\u0007") && !notes.includes("\r"));
  assert.ok(notes.length <= 1_402);
  const text = announcementText(release({ name: "**@everyone** <#1> v1", body: "" }));
  assert.match(text, /^\*\*Coincide everyone 1 v1\*\* is out\./);
  assert.deepEqual(publishedReleases([]), []);
  assert.throws(() => publishedReleases({ message: "Not Found" }), /github_releases_unexpected/);
});

test("iOS store build releases are never announced", async () => {
  Date.now = () => NOW;
  const env = environment();
  const state = { releases: [] };
  const { posts, fetchImpl } = upstream(state);
  assert.equal((await announceReleases(env, fetchImpl)).status, "seeded");
  const later = new Date(NOW + 60_000).toISOString();
  const ios = release({ name: "Coincide for iOS 0.1.0", tag_name: "ios-v0.1.0", prerelease: true, published_at: later });
  const mac = release({ published_at: later });
  assert.deepEqual(publishedReleases([ios, mac]).map((r) => r.id), [mac.id]);
  state.releases = [ios, mac];
  Date.now = () => NOW + 3_600_000;
  assert.deepEqual(await announceReleases(env, fetchImpl), { status: "checked", posted: 1 });
  assert.equal(posts.length, 1);
  assert.doesNotMatch(posts[0].content, /iOS/);
});

test("the scheduled entry point logs a safe code instead of throwing", async () => {
  const errors = [];
  const nativeError = console.error;
  const nativeFetch = globalThis.fetch;
  console.error = (...args) => errors.push(args);
  globalThis.fetch = async () => new Response("", { status: 500 });
  try {
    await runReleaseAnnouncements(environment());
  } finally {
    console.error = nativeError;
    globalThis.fetch = nativeFetch;
  }
  assert.deepEqual(errors, [["discord_release_check_failed", "github_releases_http_500"]]);
});
