// The pieces of `coincide-dev` that don't touch the network or the disk, kept apart so test/installer.test.mjs can
// check them. bin/coincide-dev.mjs does the rest.

export const REPOSITORY = "apoorvdarshan/coincide";
export const BUNDLE_ID = "com.apoorvdarshan.coincide";
export const TEAM_ID = "23RV7FYH36";
// The asset the in-app updater installs too (docs/app-updates.md), and the checksum file every release carries.
export const ARCHIVE = "Coincide-macos-universal.zip";
export const CHECKSUMS = "SHA256SUMS.txt";
// The published legacy Swift release's deployment target.
export const MINIMUM_MACOS = 26;

// codesign's check that a bundle is Coincide, signed with the Developer ID of its maintainer's team.
export const REQUIREMENT =
  `anchor apple generic and identifier "${BUNDLE_ID}" and ` +
  `certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "${TEAM_ID}"`;

export const USAGE = `coincide-dev installs Coincide (https://coincide.dev), the native Mac app for your coding agents.

Usage:
  npx coincide-dev [install] [version] [options]
  npx coincide-dev where

Commands:
  install [version]  Download the latest release, or the given one (like 0.2.0), check its
                     SHA-256 checksum, Developer ID signature and notarization, and install
                     Coincide.app. This is the default.
  where              Print where Coincide is installed, with its version.
  help               Show this help.

Options:
  --dir <folder>     Install into this folder instead of /Applications.
  -y, --yes          Quit a running Coincide without asking first.
  -v, --version      Print this installer's version.
`;

export class UsageError extends Error {}

const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

export function isVersion(value) {
  return VERSION.test(value);
}

/** Parses the command line (without node and the script). Throws UsageError for anything it doesn't know. */
export function parseArguments(argv) {
  const options = { command: "install", version: null, dir: null, yes: false };
  const positional = [];
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "-h" || argument === "--help") options.command = "help";
    else if (argument === "-v" || argument === "--version") options.command = "version";
    else if (argument === "-y" || argument === "--yes") options.yes = true;
    else if (argument === "--dir" || argument.startsWith("--dir=")) {
      const value = argument === "--dir" ? argv[++index] : argument.slice("--dir=".length);
      if (!value) throw new UsageError("--dir needs a folder");
      options.dir = value;
    } else if (argument.startsWith("-")) throw new UsageError(`Unknown option ${argument}`);
    else positional.push(argument);
  }
  if (options.command === "help" || options.command === "version") return options;
  if (["install", "where", "help"].includes(positional[0])) options.command = positional.shift();
  if (options.command === "install" && positional.length > 0) {
    const version = positional.shift().replace(/^v/, "");
    if (!isVersion(version)) throw new UsageError(`"${version}" isn't a version like 0.2.0`);
    options.version = version;
  }
  if (positional.length > 0) throw new UsageError(`Unexpected ${positional.join(" ")}`);
  return options;
}

/** The release tag github.com/<repo>/releases/latest redirects to, or null when no release is published yet. */
export function tagFromLatestRedirect(location) {
  if (!location) return null;
  const url = new URL(location, "https://github.com");
  const match = url.pathname.match(new RegExp(`^/${REPOSITORY}/releases/tag/(v[^/]+)$`));
  if (!match || url.hostname !== "github.com") return null;
  return isVersion(match[1].slice(1)) ? match[1] : null;
}

export function releaseURL(tag, asset) {
  return `https://github.com/${REPOSITORY}/releases/download/${tag}/${asset}`;
}

/** The SHA-256 the checksum file (`shasum -a 256` output) lists for a file, or null. */
export function checksumFor(text, file) {
  for (const line of text.split(/\r?\n/)) {
    const match = line.trim().match(/^([0-9a-f]{64}) [ *](.+)$/i);
    if (match && match[2] === file) return match[1].toLowerCase();
  }
  return null;
}

/** The major version of a `sw_vers -productVersion` string such as "26.1". */
export function macOSMajor(productVersion) {
  const major = Number.parseInt(String(productVersion).trim().split(".")[0], 10);
  return Number.isFinite(major) ? major : null;
}

export function formatBytes(bytes) {
  return bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`;
}
