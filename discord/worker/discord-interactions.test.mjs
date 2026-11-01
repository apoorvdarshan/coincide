import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  DISCORD_INTERACTIONS_PATH, handleDiscordInteractionsRequest, formatWait, recentReports,
  reportCooldownReply, reportCooldownSeconds,
} from "./discord-interactions.mjs";

const APP = "523456789012345678";
const GUILD = "623456789012345678";
const CHANNEL = "223456789012345678";
const USER = "123456789012345678";
const MESSAGE = "323456789012345678";
const GEMINI_KEY = "unit-gemini-key";
const nativeFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = nativeFetch; });

const hex = (bytes) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const PUBLIC_KEY = hex(await crypto.subtle.exportKey("raw", pair.publicKey));

function kv() {
  const data = new Map();
  return {
    data,
    async get(key) { return data.get(key)?.value ?? null; },
    async getWithMetadata(key) { const hit = data.get(key); return { value: hit?.value ?? null, metadata: hit?.metadata ?? null }; },
    async put(key, value, options = {}) { data.set(key, { value, metadata: options.metadata ?? null }); },
    async delete(key) { data.delete(key); },
  };
}

function environment(extra = {}) {
  return {
    DISCORD_PUBLIC_KEY: PUBLIC_KEY, DISCORD_APPLICATION_ID: APP, DISCORD_GUILD_ID: GUILD,
    DISCORD_GITHUB_TOKEN: "unit-github-token", DISCORD_STATE: kv(), ...extra,
  };
}

let nextId = 700000000000000000n;
function interaction(name, value, extra = {}) {
  nextId += 1n;
  return {
    type: 2, id: String(nextId), token: "test-interaction-token", application_id: APP, guild_id: GUILD,
    channel_id: CHANNEL, member: { user: { id: USER, username: "test-reporter" } },
    data: { name, options: [{ name: name === "ask" ? "question" : "report", type: 3, value }] }, ...extra,
  };
}

async function signed(body, { timestamp = String(Math.floor(Date.now() / 1000)), key = pair.privateKey } = {}) {
  const raw = JSON.stringify(body);
  const signature = hex(await crypto.subtle.sign("Ed25519", key, new TextEncoder().encode(timestamp + raw)));
  return new Request(`https://discord.coincide.dev${DISCORD_INTERACTIONS_PATH}`, {
    method: "POST", headers: { "X-Signature-Ed25519": signature, "X-Signature-Timestamp": timestamp }, body: raw,
  });
}

/** Runs a request and every background task it schedules, returning the immediate response. */
async function run(body, env, options) {
  const pending = [];
  const response = await handleDiscordInteractionsRequest(await signed(body, options), env, { waitUntil: (p) => pending.push(p) });
  for (let i = 0; i < pending.length; i += 1) await pending[i];
  return response;
}

/** Fake Gemini, GitHub and Discord. `gemini` and `github` return a Response or throw. */
function upstream({ gemini, github } = {}) {
  const calls = { gemini: [], github: [], replies: [] };
  globalThis.fetch = async (url, init) => {
    assert.equal(init.redirect, "manual");
    const { hostname, pathname } = new URL(url);
    if (hostname === "generativelanguage.googleapis.com") {
      calls.gemini.push({ url, init, body: JSON.parse(init.body) });
      return gemini ? gemini() : Response.json({ candidates: [{ content: { parts: [{ text: "Coincide runs on macOS 26 or later." }] } }] });
    }
    if (hostname === "api.github.com") {
      calls.github.push({ url, init, body: JSON.parse(init.body) });
      return github ? github() : Response.json({ number: 42, html_url: "https://github.com/apoorvdarshan/coincide/issues/42" });
    }
    if (hostname === "discord.com" && pathname.startsWith(`/api/v10/webhooks/${APP}/`)) {
      calls.replies.push(JSON.parse(init.body));
      return Response.json({ id: MESSAGE, channel_id: CHANNEL });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  return calls;
}

test("rejects unsigned, forged and stale requests, and answers Discord's signed PING", async () => {
  const env = environment();
  const forged = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  assert.equal((await run({ type: 1 }, env, { key: forged.privateKey })).status, 401);
  assert.equal((await run({ type: 1 }, env, { timestamp: String(Math.floor(Date.now() / 1000) - 600) })).status, 401);
  const unsigned = new Request(`https://x${DISCORD_INTERACTIONS_PATH}`, { method: "POST", body: "{}" });
  assert.equal((await handleDiscordInteractionsRequest(unsigned, env, {})).status, 401);
  const ping = await run({ type: 1, application_id: APP }, env);
  assert.deepEqual(await ping.json(), { type: 1 });
  assert.equal((await handleDiscordInteractionsRequest(new Request("https://x", { method: "GET" }), env, {})).status, 405);
});

test("commands from another application or server are refused before any work", async () => {
  const env = environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY });
  const calls = upstream();
  assert.equal((await run(interaction("ask", "hi", { application_id: "999999999999999999" }), env)).status, 403);
  const other = await (await run(interaction("ask", "hi", { guild_id: "888888888888888888" }), env)).json();
  assert.equal(other.type, 4);
  assert.equal(other.data.flags, 64);
  assert.match(other.data.content, /only in the Coincide community server/);
  assert.equal(calls.gemini.length + calls.github.length + calls.replies.length, 0);
});

test("/ask fails clearly and privately until the Gemini key is configured", async () => {
  const calls = upstream();
  const body = await (await run(interaction("ask", "Which agents work?"), environment())).json();
  assert.equal(body.type, 4);
  assert.equal(body.data.flags, 64);
  assert.match(body.data.content, /not configured yet/);
  assert.equal(calls.gemini.length + calls.replies.length, 0);
});

test("/ask defers, sends the key only in a header and replies without mentions", async () => {
  const calls = upstream();
  const response = await run(interaction("ask", "Which macOS do I need?"), environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY }));
  assert.equal((await response.json()).type, 5);
  assert.equal(calls.gemini.length, 1);
  assert.equal(calls.gemini[0].init.headers["x-goog-api-key"], GEMINI_KEY);
  assert.ok(!calls.gemini[0].url.includes(GEMINI_KEY));
  assert.match(calls.gemini[0].body.systemInstruction.parts[0].text, /^You are Brulee/);
  assert.equal(calls.gemini[0].body.contents[0].parts[0].text, "Which macOS do I need?");
  assert.equal(calls.replies.length, 1);
  assert.equal(calls.replies[0].content, "Coincide runs on macOS 26 or later.");
  assert.deepEqual(calls.replies[0].allowed_mentions, { parse: [], replied_user: false });
});

test("/ask reports an AI failure without leaking details and enforces a one-minute cooldown", async () => {
  const env = environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY });
  const calls = upstream({ gemini: () => Response.json({ error: { status: "UNAVAILABLE" } }, { status: 503 }) });
  await run(interaction("ask", "first"), env);
  assert.match(calls.replies[0].content, /couldn't reach my AI helper/);
  await run(interaction("ask", "second"), env);
  assert.equal(calls.gemini.length, 1);
  assert.equal(calls.replies[1].content, "Please wait a minute between questions.");
});

test("a replayed interaction is processed once", async () => {
  const env = environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY });
  const calls = upstream();
  const once = interaction("ask", "hello");
  await run(once, env);
  await run(once, env);
  assert.equal(calls.gemini.length, 1);
  assert.equal(calls.replies.length, 1);
});

test("/bug without AI publishes the original report and records closure routing", async () => {
  const env = environment();
  const calls = upstream();
  await run(interaction("bug", "Crash when switching to Codex\nmacOS 26.1, Coincide 0.1.0 @someone"), env);
  assert.equal(calls.gemini.length, 0);
  const issue = calls.github[0].body;
  assert.equal(calls.github[0].url, "https://api.github.com/repos/apoorvdarshan/coincide/issues");
  assert.equal(calls.github[0].init.headers.Authorization, "Bearer unit-github-token");
  assert.equal(issue.title, "Crash when switching to Codex");
  assert.deepEqual(issue.labels, ["bug"]);
  assert.match(issue.body, /## Original report\n\n> Crash when switching to Codex\n> macOS 26\.1, Coincide 0\.1\.0 @​someone/);
  assert.doesNotMatch(issue.body, /Summary \(AI-organized\)/);
  assert.doesNotMatch(issue.body, new RegExp(`${USER}|test-reporter`));
  assert.match(calls.replies[0].content, /public GitHub issue: https:\/\/github\.com\/apoorvdarshan\/coincide\/issues\/42/);
  assert.ok(env.DISCORD_STATE.data.has("issue-close:link:42"));
});

test("/feature keeps the original text under an AI summary, and AI failure still files the report", async () => {
  const organized = upstream({
    gemini: () => Response.json({ candidates: [{ content: { parts: [{ text: '{"title":"Pin threads per project","body":"### Request\\nPin threads."}' }] } }] }),
  });
  await run(interaction("feature", "please let me pin threads"), environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY }));
  assert.equal(organized.github[0].body.title, "Pin threads per project");
  assert.deepEqual(organized.github[0].body.labels, ["enhancement"]);
  assert.match(organized.github[0].body.body, /## Summary \(AI-organized\)\n\n### Request\nPin threads\.[\s\S]*## Original report\n\n> please let me pin threads/);

  const fallback = upstream({ gemini: () => { throw new Error(`fetch failed for key ${GEMINI_KEY}`); } });
  await run(interaction("feature", "dark mode for the terminal"), environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY }));
  assert.equal(fallback.github.length, 1);
  assert.equal(fallback.github[0].body.title, "dark mode for the terminal");
  assert.match(fallback.github[0].body.body, /> dark mode for the terminal/);
});

test("a GitHub failure is reported as unconfirmed and is never retried automatically", async () => {
  const env = environment();
  const calls = upstream({ github: () => Response.json({ message: "Bad credentials" }, { status: 401 }) });
  await run(interaction("bug", "Terminal tab freezes"), env);
  assert.equal(calls.github.length, 1);
  assert.match(calls.replies[0].content, /couldn't confirm the GitHub issue was created/);
  assert.ok(![...env.DISCORD_STATE.data.keys()].some((key) => key.startsWith("issue-close:link:")));
});

test("/bug and /feature are refused privately when GitHub is not configured", async () => {
  const calls = upstream();
  const body = await (await run(interaction("bug", "x"), environment({ DISCORD_GITHUB_TOKEN: "" }))).json();
  assert.equal(body.data.flags, 64);
  assert.match(body.data.content, /not configured yet/);
  assert.equal(calls.github.length, 0);
});

test("reports share an escalating cooldown across /bug and /feature", async () => {
  const env = environment();
  const calls = upstream();
  await run(interaction("bug", "first report"), env);
  await run(interaction("feature", "second report right away"), env);
  assert.equal(calls.github.length, 1);
  assert.match(calls.replies[1].content, /You can send another report in (10|9) minutes?\./);
  assert.match(calls.replies[1].content, /starts at 10 minutes, doubles with each report up to a day/);
});

test("cooldown arithmetic: doubling, cap, streak reset and wording", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 8, 12].map(reportCooldownSeconds), [600, 1200, 2400, 4800, 9600, 76800, 86400]);
  const hour = 3_600_000;
  const now = 1_800_000_000_000;
  // A gap of two days or more ends the streak; shorter gaps chain.
  assert.deepEqual(recentReports({ reports: [now - 80 * hour, now - 30 * hour, now - hour] }, false, now), [now - 30 * hour, now - hour]);
  assert.deepEqual(recentReports({ reports: [now - 70 * hour, now - 30 * hour, now - hour] }, false, now), [now - 70 * hour, now - 30 * hour, now - hour]);
  assert.deepEqual(recentReports({ reports: [now - 49 * hour] }, false, now), []);
  assert.deepEqual(recentReports({ reports: [now - 2 * hour, now - hour] }, true, now), [now - 2 * hour]);
  assert.deepEqual(recentReports(null, false, now), []);
  assert.equal(formatWait(40 * 60_000), "40 minutes");
  assert.equal(formatWait(80 * 60_000), "1 hour 20 minutes");
  assert.equal(formatWait(21 * hour), "21 hours");
  assert.match(reportCooldownReply(undefined), /still being sent/);
  assert.match(reportCooldownReply(now + 30 * 60_000, now), /in 30 minutes\./);
});

test("unavailable state storage fails the command clearly instead of skipping limits", async () => {
  const env = environment({ DISCORD_GEMINI_API_KEY: GEMINI_KEY });
  env.DISCORD_STATE.getWithMetadata = async () => { throw new Error("kv down"); };
  const calls = upstream();
  await run(interaction("ask", "hello"), env);
  assert.equal(calls.gemini.length, 0);
  assert.match(calls.replies[0].content, /temporarily unavailable/);
});
