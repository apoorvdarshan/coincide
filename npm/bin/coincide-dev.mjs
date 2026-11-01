#!/usr/bin/env node
// `npx coincide-dev`: downloads a notarized Coincide release from GitHub Releases, checks it and installs Coincide.app.
// It uses only Node's own modules and the Mac's own tools (ditto, codesign, spctl), and never asks for elevated rights.
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { constants, createWriteStream, existsSync, readFileSync } from "node:fs";
import { access, mkdtemp, rename, rm, stat } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import {
  ARCHIVE, BUNDLE_ID, CHECKSUMS, MINIMUM_MACOS, REPOSITORY, REQUIREMENT, USAGE, UsageError,
  checksumFor, formatBytes, macOSMajor, parseArguments, releaseURL, tagFromLatestRedirect,
} from "../lib/installer.mjs";

const run = promisify(execFile);
const packageVersion = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
const userAgent = `coincide-dev/${packageVersion}`;

class InstallError extends Error {}

function say(message) {
  process.stderr.write(`${message}\n`);
}

async function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    say(`coincide-dev: ${error.message}\n`);
    process.stderr.write(USAGE);
    return 2;
  }
  if (options.command === "help") {
    process.stdout.write(USAGE);
    return 0;
  }
  if (options.command === "version") {
    process.stdout.write(`${packageVersion}\n`);
    return 0;
  }
  if (process.platform !== "darwin") {
    throw new InstallError(
      `Coincide is a Mac app, and this installer runs only on macOS (this is ${process.platform}). ` +
        "Coincide Remote for iPhone and iPad is coming; see https://coincide.dev.",
    );
  }
  if (options.command === "where") return where();
  return install(options);
}

async function install(options) {
  const { stdout: productVersion } = await run("/usr/bin/sw_vers", ["-productVersion"]);
  const major = macOSMajor(productVersion);
  if (major !== null && major < MINIMUM_MACOS) {
    throw new InstallError(`Coincide needs macOS ${MINIMUM_MACOS} or later; this Mac runs ${productVersion.trim()}.`);
  }
  const folder = resolve(options.dir ?? "/Applications");
  const destination = join(folder, "Coincide.app");
  try {
    await access(folder, constants.W_OK);
  } catch {
    throw new InstallError(
      `Can't write to ${folder}. Choose a folder you can write to, such as --dir ~/Applications.`,
    );
  }

  const tag = options.version ? `v${options.version}` : await latestTag();
  const version = tag.slice(1);
  const checksums = await fetchText(releaseURL(tag, CHECKSUMS), `Coincide ${version} has no ${CHECKSUMS}`);
  const expected = checksumFor(checksums, ARCHIVE);
  if (!expected) throw new InstallError(`${CHECKSUMS} of Coincide ${version} doesn't list ${ARCHIVE}.`);

  const work = await mkdtemp(join(tmpdir(), "coincide-dev-"));
  try {
    const archive = join(work, ARCHIVE);
    const digest = await download(releaseURL(tag, ARCHIVE), archive, `Coincide ${version}`);
    if (digest !== expected) {
      throw new InstallError(`The download doesn't match its SHA-256 checksum (${CHECKSUMS}); nothing was installed.`);
    }
    say("Checksum verified. Checking the signature and notarization…");
    const extracted = join(work, "extracted");
    await run("/usr/bin/ditto", ["-x", "-k", archive, extracted]);
    const app = join(extracted, "Coincide.app");
    await verify(app, version);

    await waitUntilNotRunning(destination, options.yes);
    // Copied beside the destination first, so the swap below is a rename on one volume.
    const staged = join(folder, `.Coincide-${randomUUID()}.app`);
    await run("/usr/bin/ditto", [app, staged]);
    try {
      await replace(staged, destination, folder);
    } finally {
      await rm(staged, { recursive: true, force: true });
    }
  } finally {
    await rm(work, { recursive: true, force: true });
  }
  process.stdout.write(`Installed Coincide ${version} at ${destination}\n`);
  say(`Open it from ${folder === "/Applications" ? "Applications" : folder}, or run: open "${destination}"`);
  return 0;
}

/** The newest published release, from the redirect github.com/<repo>/releases/latest answers with. */
async function latestTag() {
  const response = await request(`https://github.com/${REPOSITORY}/releases/latest`, { redirect: "manual" });
  const tag = tagFromLatestRedirect(response.headers.get("location"));
  if (!tag) throw new InstallError(`No release of Coincide is published yet; see https://github.com/${REPOSITORY}/releases.`);
  return tag;
}

async function request(url, init = {}) {
  try {
    return await fetch(url, { ...init, headers: { "User-Agent": userAgent }, signal: init.signal ?? AbortSignal.timeout(30_000) });
  } catch (error) {
    throw new InstallError(`Couldn't reach GitHub (${error.cause?.code ?? error.message}). Check your connection and try again.`);
  }
}

async function fetchText(url, missing) {
  const response = await request(url);
  if (response.status === 404) throw new InstallError(`${missing} (${url}).`);
  if (!response.ok) throw new InstallError(`GitHub answered ${response.status} for ${url}.`);
  return response.text();
}

/** Streams the file to disk and returns its SHA-256, showing progress on a terminal. */
async function download(url, file, label) {
  const response = await request(url, { signal: AbortSignal.timeout(30 * 60_000) });
  if (response.status === 404) throw new InstallError(`${label} has no ${ARCHIVE} (${url}).`);
  if (!response.ok || !response.body) throw new InstallError(`GitHub answered ${response.status} for ${url}.`);
  const total = Number(response.headers.get("content-length")) || 0;
  const hash = createHash("sha256");
  let received = 0;
  let shown = -1;
  const meter = new Transform({
    transform(chunk, _encoding, callback) {
      hash.update(chunk);
      received += chunk.length;
      const percent = total ? Math.floor((received / total) * 100) : -1;
      if (process.stderr.isTTY && percent !== shown) {
        shown = percent;
        process.stderr.write(`\rDownloading ${label} (${formatBytes(total || received)})… ${percent >= 0 ? `${percent}%` : ""}`);
      }
      callback(null, chunk);
    },
  });
  if (!process.stderr.isTTY) say(`Downloading ${label}…`);
  try {
    await pipeline(Readable.fromWeb(response.body), meter, createWriteStream(file, { mode: 0o600 }));
  } catch (error) {
    throw new InstallError(`The download failed (${error.message}). Try again.`);
  } finally {
    if (process.stderr.isTTY) process.stderr.write("\n");
  }
  return hash.digest("hex");
}

/** The bundle must be Coincide at that version, Developer ID signed by its team, intact, and notarized. */
async function verify(app, version) {
  if (!existsSync(join(app, "Contents/Info.plist"))) throw new InstallError(`The download doesn't contain Coincide.app.`);
  const plist = (key) => run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", join(app, "Contents/Info.plist")]);
  const [{ stdout: identifier }, { stdout: shortVersion }] = await Promise.all([
    plist("CFBundleIdentifier"), plist("CFBundleShortVersionString"),
  ]);
  if (identifier.trim() !== BUNDLE_ID || shortVersion.trim() !== version) {
    throw new InstallError(`The download isn't Coincide ${version}; nothing was installed.`);
  }
  try {
    await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", `-R=${REQUIREMENT}`, app]);
  } catch (error) {
    throw new InstallError(`Coincide's Developer ID signature didn't verify; nothing was installed.\n${error.stderr ?? ""}`.trim());
  }
  try {
    await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app]);
  } catch (error) {
    throw new InstallError(`Gatekeeper rejected the download (not notarized?); nothing was installed.\n${error.stderr ?? ""}`.trim());
  }
}

/** Whether the copy at destination is running (another copy elsewhere, such as a build, doesn't matter). */
async function isRunning(destination) {
  const executable = join(destination, "Contents/MacOS/Coincide").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  try {
    const { stdout } = await run("/usr/bin/pgrep", ["-f", `^${executable}( |$)`]);
    return stdout.trim().length > 0;
  } catch {
    return false; // pgrep exits 1 when nothing matches
  }
}

/** Replacing Coincide while it runs would pull files from under it, so it has to quit first. */
async function waitUntilNotRunning(destination, yes) {
  if (!(await isRunning(destination))) return;
  if (!yes) {
    if (!process.stdin.isTTY) throw new InstallError("Coincide is running. Quit it and run this again, or pass --yes to quit it.");
    const prompt = createInterface({ input: process.stdin, output: process.stderr });
    const answer = await prompt.question("Coincide is running. Quit it to install the update? [y/N] ");
    prompt.close();
    if (!/^y(es)?$/i.test(answer.trim())) throw new InstallError("Nothing was installed; Coincide is still running.");
  }
  say("Asking Coincide to quit…");
  // A normal quit, so Coincide saves its state; macOS may ask once to let this terminal control Coincide.
  await run("/usr/bin/osascript", ["-e", `tell application ${JSON.stringify(destination)} to quit`]).catch(() => {
    say("Couldn't ask Coincide to quit. Quit it yourself (⌘Q); waiting…");
  });
  const deadline = Date.now() + 120_000;
  while (await isRunning(destination)) {
    if (Date.now() > deadline) throw new InstallError("Coincide is still running; quit it and run this again.");
    await new Promise((done) => setTimeout(done, 500));
  }
}

/** Puts the staged app at destination; the previous copy is removed only once the new one is in place. */
async function replace(staged, destination, folder) {
  if (!existsSync(destination)) {
    await rename(staged, destination);
    return;
  }
  const previous = join(folder, `.Coincide-previous-${randomUUID()}.app`);
  await rename(destination, previous);
  try {
    await rename(staged, destination);
  } catch (error) {
    await rename(previous, destination);
    throw new InstallError(`Couldn't replace ${destination} (${error.message}); the previous copy was kept.`);
  }
  await rm(previous, { recursive: true, force: true });
}

async function where() {
  const candidates = new Set(["/Applications/Coincide.app", join(homedir(), "Applications/Coincide.app")]);
  try {
    const { stdout } = await run("/usr/bin/mdfind", [`kMDItemCFBundleIdentifier == '${BUNDLE_ID}'`]);
    // Builds in DerivedData and copies the updater keeps under ~/Library aren't installations.
    for (const line of stdout.split("\n")) {
      if (line.endsWith(".app") && !line.includes("/Library/") && !line.includes("/.")) candidates.add(line);
    }
  } catch {
    // Spotlight can be off; the usual folders are still checked.
  }
  let found = 0;
  for (const app of candidates) {
    const info = join(app, "Contents/Info.plist");
    if (!existsSync(info) || !(await stat(app)).isDirectory()) continue;
    try {
      const read = (key) => run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", info]).then((r) => r.stdout.trim());
      if ((await read("CFBundleIdentifier")) !== BUNDLE_ID) continue;
      process.stdout.write(`${app} (${await read("CFBundleShortVersionString")})\n`);
      found++;
    } catch {
      // Not a readable bundle.
    }
  }
  if (found === 0) {
    say("Coincide isn't installed. Install it with: npx coincide-dev");
    return 1;
  }
  return 0;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    say(error instanceof InstallError ? `coincide-dev: ${error.message}` : `coincide-dev: ${error.stack ?? error}`);
    process.exit(1);
  },
);
