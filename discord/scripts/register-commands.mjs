#!/usr/bin/env node

// Registers /ask, /bug and /feature in the Coincide server. Run from the repository root
// with Node 22+ and the bot token in an env file kept outside the repository:
//   node --env-file="$HOME/.config/coincide/discord.env" discord/scripts/register-commands.mjs
// --dry-run prints the command definitions without any network requests.

const APPLICATION_ID = "1566350650839797780";
const GUILD_ID = "1566352780862427258";

const commands = [
  {
    type: 1,
    name: "ask",
    description: "Ask Brulee about Coincide. Your question goes to Google Gemini; the answer is visible here.",
    options: [{
      type: 3,
      name: "question",
      description: "Your Coincide question. Do not include keys, tokens or private code.",
      required: true,
      min_length: 1,
      max_length: 1500,
    }],
  },
  {
    type: 1,
    name: "bug",
    description: "Publish a Coincide bug report as a PUBLIC GitHub issue. Do not include secrets.",
    options: [{
      type: 3,
      name: "report",
      description: "Public: Mac app or Remote, versions, steps, expected vs actual. Gemini may organize it.",
      required: true,
      min_length: 1,
      max_length: 4000,
    }],
  },
  {
    type: 1,
    name: "feature",
    description: "Publish a Coincide feature request as a PUBLIC GitHub issue. Do not include secrets.",
    options: [{
      type: 3,
      name: "report",
      description: "Public: what you want and why it would help. Gemini may organize it.",
      required: true,
      min_length: 1,
      max_length: 4000,
    }],
  },
];

async function discord(path, token, body) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    let response;
    try {
      response = await fetch(`https://discord.com/api/v10${path}`, {
        method: body ? "POST" : "GET",
        headers: { Authorization: `Bot ${token}`, "Content-Type": "application/json" },
        body: body ? JSON.stringify(body) : undefined,
        redirect: "error",
        signal: AbortSignal.timeout(20000),
      });
    } catch {
      // Do not log request headers, raw API responses or error causes with credentials.
      throw new Error("Discord request failed or timed out. Rerun registration to resume safely.");
    }
    if (response.status === 429 && attempt < 2) {
      const limit = await response.json().catch(() => null);
      const seconds = Number(limit?.retry_after);
      if (Number.isFinite(seconds) && seconds >= 0 && seconds <= 15) {
        await new Promise((resolve) => setTimeout(resolve, Math.ceil(seconds * 1000) + 250));
        continue;
      }
    }
    if (!response.ok) {
      throw new Error(`Discord returned HTTP ${response.status}. Check the bot token, server installation and permissions.`);
    }
    const data = await response.json().catch(() => null);
    if (!data || typeof data !== "object") throw new Error("Discord returned an unexpected response.");
    return data;
  }
  throw new Error("Discord rate limit persists. Retry registration later.");
}

async function main() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--dry-run")) throw new Error("Usage: node register-commands.mjs [--dry-run]");
  if (args.includes("--dry-run")) {
    console.log(JSON.stringify(commands, null, 2));
    return;
  }
  const token = process.env.DISCORD_BOT_TOKEN?.trim();
  if (!token) throw new Error("Set DISCORD_BOT_TOKEN (Brulee's bot token) in the env file.");

  // Verify the token belongs to Brulee and can see the Coincide server before changing anything.
  const app = await discord("/oauth2/applications/@me", token);
  if (app.id !== APPLICATION_ID) throw new Error("DISCORD_BOT_TOKEN belongs to a different application. No commands were changed.");
  const guild = await discord(`/guilds/${GUILD_ID}`, token);
  if (guild.id !== GUILD_ID) throw new Error("The Coincide server could not be verified. No commands were changed.");

  console.log(`Verified application ${APPLICATION_ID} and server ${GUILD_ID}.`);
  for (const command of commands) {
    // POST upserts this command by name; a bulk PUT would erase unrelated commands.
    const registered = await discord(`/applications/${APPLICATION_ID}/guilds/${GUILD_ID}/commands`, token, command);
    if (registered.name !== command.name || registered.application_id !== APPLICATION_ID || registered.guild_id !== GUILD_ID) {
      throw new Error(`Discord returned an unexpected registration result for /${command.name}.`);
    }
    console.log(`Registered /${command.name} in server ${GUILD_ID}.`);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
