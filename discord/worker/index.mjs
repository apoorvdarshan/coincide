import { runDiscordModeration } from "./discord-moderation.mjs";
export { DiscordModeration } from "./discord-moderation.mjs";
import { GITHUB_ISSUES_WEBHOOK_PATH, handleGitHubIssueClosure, retryDiscordIssueClosures } from "./discord-issue-closures.mjs";
import { DISCORD_INTERACTIONS_PATH, handleDiscordInteractionsRequest } from "./discord-interactions.mjs";
import { runReleaseAnnouncements } from "./discord-releases.mjs";

/** A permanent discord.gg invite only; anything else is ignored rather than redirected to. */
const INVITE = /^https:\/\/discord\.gg\/[A-Za-z0-9-]{2,32}$/;

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);
    if (url.pathname === DISCORD_INTERACTIONS_PATH) {
      return handleDiscordInteractionsRequest(request, env, context);
    }
    if (url.pathname === GITHUB_ISSUES_WEBHOOK_PATH) {
      return handleGitHubIssueClosure(request, env, context);
    }
    // The bare host is a stable, short link to the community server.
    const invite = typeof env.DISCORD_INVITE_URL === "string" ? env.DISCORD_INVITE_URL.trim() : "";
    if (url.pathname === "/" && (request.method === "GET" || request.method === "HEAD") && INVITE.test(invite)) {
      return new Response(null, { status: 302, headers: { Location: invite, "Cache-Control": "public, max-age=300" } });
    }
    return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } });
  },

  scheduled(event, env, context) {
    if (event.cron === "* * * * *") context.waitUntil(runDiscordModeration(env));
    else if (event.cron === "*/5 * * * *") context.waitUntil(retryDiscordIssueClosures(env));
    else context.waitUntil(runReleaseAnnouncements(env));
  },
};
