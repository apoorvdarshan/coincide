// The coincide.dev Worker: static files come straight from public/; this only answers /api/interest, the public
// count of taps asking for Coincide on other platforms. Every tap adds one; nothing about the visitor is stored.
import { DurableObject } from "cloudflare:workers";

const PLATFORMS = ["windows", "linux", "android"];
const ORIGINS = new Set(["https://coincide.dev", "https://www.coincide.dev"]);
// Generous enough for frantic tapping, low enough that a script can't run the numbers up.
const TAPS_PER_WINDOW = 100;
const WINDOW_MS = 10_000;

export class InterestCounter extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS counts (platform TEXT PRIMARY KEY, total INTEGER NOT NULL)");
    // Recent taps per address, in memory only, for the rate limit.
    this.recent = new Map();
  }

  counts() {
    const counts = Object.fromEntries(PLATFORMS.map((platform) => [platform, 0]));
    for (const row of this.ctx.storage.sql.exec("SELECT platform, total FROM counts")) counts[row.platform] = row.total;
    return counts;
  }

  add(platform, address) {
    const now = Date.now();
    const taps = (this.recent.get(address) ?? []).filter((time) => now - time < WINDOW_MS);
    if (taps.length < TAPS_PER_WINDOW) {
      taps.push(now);
      this.ctx.storage.sql.exec(
        "INSERT INTO counts (platform, total) VALUES (?, 1) ON CONFLICT(platform) DO UPDATE SET total = total + 1",
        platform,
      );
    }
    if (this.recent.size > 10_000) this.recent.clear();
    this.recent.set(address, taps);
    return this.counts();
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/api/interest" && !url.pathname.startsWith("/api/interest/")) return env.ASSETS.fetch(request);
    const counter = env.INTEREST.get(env.INTEREST.idFromName("global"));
    const headers = { "content-type": "application/json", "cache-control": "no-store" };
    if (request.method === "GET" && url.pathname === "/api/interest") {
      return new Response(JSON.stringify(await counter.counts()), { headers });
    }
    const platform = url.pathname.slice("/api/interest/".length);
    if (request.method === "POST" && PLATFORMS.includes(platform)) {
      if (!ORIGINS.has(request.headers.get("origin") ?? "")) return new Response("forbidden", { status: 403 });
      const address = request.headers.get("cf-connecting-ip") ?? "unknown";
      return new Response(JSON.stringify(await counter.add(platform, address)), { headers });
    }
    return new Response("not found", { status: 404 });
  },
};
