# coincide-dev

Installs [Coincide](https://coincide.dev), the native Mac app for the coding agents you already pay for (Claude Code,
Codex, Cursor, Grok Build, OpenCode and Antigravity), from its
[GitHub releases](https://github.com/apoorvdarshan/coincide/releases).

```sh
npx coincide-dev
```

It downloads the latest release (or the one you name, as in `npx coincide-dev install 0.2.0`), checks its SHA-256
checksum against the release's `SHA256SUMS.txt`, verifies Coincide's Developer ID signature and notarization, and
installs `Coincide.app` into `/Applications`. If Coincide is running, it asks before quitting it.

```sh
npx coincide-dev where                  # where Coincide is installed, and its version
npx coincide-dev --dir ~/Applications   # install somewhere else
npm install -g coincide-dev             # keep the command around as `coincide-dev`
```

It needs macOS 26 or later and Node.js 18 or later, and uses only Node's own modules. Once installed, Coincide
updates itself (Coincide → Check for Updates). The package's version matches the Coincide release it was published with.

Other ways to install: the DMG from [coincide.dev](https://coincide.dev), or
`brew install --cask apoorvdarshan/tap/coincide`.

MIT License.
