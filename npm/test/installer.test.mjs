import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  ARCHIVE, MINIMUM_MACOS, UsageError, checksumFor, macOSMajor, parseArguments, releaseURL, tagFromLatestRedirect,
} from "../lib/installer.mjs";

const cli = fileURLToPath(new URL("../bin/coincide-dev.mjs", import.meta.url));
const repository = fileURLToPath(new URL("../..", import.meta.url));

test("installs the latest release into /Applications by default", () => {
  assert.deepEqual(parseArguments([]), { command: "install", version: null, dir: null, yes: false });
  assert.deepEqual(parseArguments(["install"]), { command: "install", version: null, dir: null, yes: false });
});

test("pins a version, with or without the tag's v", () => {
  assert.equal(parseArguments(["install", "0.2.0"]).version, "0.2.0");
  assert.equal(parseArguments(["v1.10.3"]).version, "1.10.3");
  for (const bad of ["0.2", "01.2.3", "latest", "1.2.3-beta"]) {
    assert.throws(() => parseArguments(["install", bad]), UsageError, bad);
  }
});

test("reads options and commands", () => {
  assert.deepEqual(parseArguments(["--dir", "/tmp/apps", "-y"]), { command: "install", version: null, dir: "/tmp/apps", yes: true });
  assert.equal(parseArguments(["--dir=/x"]).dir, "/x");
  assert.equal(parseArguments(["where"]).command, "where");
  assert.equal(parseArguments(["help"]).command, "help");
  assert.equal(parseArguments(["install", "--help"]).command, "help");
  assert.equal(parseArguments(["-v"]).command, "version");
  assert.throws(() => parseArguments(["--dir"]), UsageError);
  assert.throws(() => parseArguments(["--force"]), UsageError);
  assert.throws(() => parseArguments(["where", "now"]), UsageError);
  assert.throws(() => parseArguments(["uninstall"]), UsageError);
});

test("finds the tag github.com/…/releases/latest redirects to", () => {
  assert.equal(tagFromLatestRedirect("https://github.com/apoorvdarshan/coincide/releases/tag/v0.1.0"), "v0.1.0");
  assert.equal(tagFromLatestRedirect("/apoorvdarshan/coincide/releases/tag/v2.3.4"), "v2.3.4");
  // With no release yet, GitHub redirects to the releases page.
  assert.equal(tagFromLatestRedirect("https://github.com/apoorvdarshan/coincide/releases"), null);
  assert.equal(tagFromLatestRedirect(null), null);
  assert.equal(tagFromLatestRedirect("https://github.com/someone/else/releases/tag/v1.0.0"), null);
  assert.equal(tagFromLatestRedirect("https://example.com/apoorvdarshan/coincide/releases/tag/v1.0.0"), null);
  assert.equal(tagFromLatestRedirect("https://github.com/apoorvdarshan/coincide/releases/tag/nightly"), null);
});

test("downloads from the release's own tag", () => {
  assert.equal(releaseURL("v0.1.0", ARCHIVE),
    "https://github.com/apoorvdarshan/coincide/releases/download/v0.1.0/Coincide-macos-universal.zip");
});

test("takes the archive's checksum from SHA256SUMS.txt", () => {
  const a = "a".repeat(64), b = "B".repeat(64);
  const sums = `${a}  Coincide-0.1.0.dmg\n${a}  Coincide.dmg\n${b}  Coincide-macos-universal.zip\n`;
  assert.equal(checksumFor(sums, ARCHIVE), "b".repeat(64));
  assert.equal(checksumFor(`${a} *${ARCHIVE}\r\n`, ARCHIVE), a);
  assert.equal(checksumFor(`${a}  Coincide-macos-universal.zip.old\n`, ARCHIVE), null);
  assert.equal(checksumFor("not a checksum file", ARCHIVE), null);
});

test("reads the macOS major version", () => {
  assert.equal(macOSMajor("26.1\n"), 26);
  assert.equal(macOSMajor("15.7.2"), 15);
  assert.equal(macOSMajor("unknown"), null);
});

test("requires the app's deployment target", () => {
  const project = readFileSync(`${repository}/project.yml`, "utf8");
  assert.match(project, new RegExp(`macOS: "${MINIMUM_MACOS}\\.0"`));
});

test("the package version is a release version", () => {
  const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  assert.match(version, /^\d+\.\d+\.\d+$/);
});

test("prints help and rejects unknown options", () => {
  const help = spawnSync(process.execPath, [cli, "--help"], { encoding: "utf8" });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /npx coincide-dev/);
  const bad = spawnSync(process.execPath, [cli, "--nope"], { encoding: "utf8" });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /Unknown option --nope/);
});

test("explains that it runs only on macOS", { skip: process.platform === "darwin" }, () => {
  const result = spawnSync(process.execPath, [cli], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Coincide is a Mac app/);
});
