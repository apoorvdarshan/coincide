# Changelog

Notable changes in each Coincide release. A release's notes on GitHub are its section here, so a version's section must exist before its tag is pushed (see [docs/releasing.md](docs/releasing.md)).

## 0.1.0

The first public release of Coincide, a native macOS app for the coding agents you already pay for.

- **Every agent, one window:** Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity, each through its own command-line tool and your existing sign-in, with one model picker across them.
- **Switch agents mid-thread:** the next agent gets a recap of the turns it missed and continues in the same folder.
- Projects and threads with search, pinning, archiving, snoozing and a ⌘K command palette, plus chats without a project.
- Plan mode, approvals or full access, questions answered inline, attachments, `@` file mentions and `/` commands.
- Git built in: diffs, per-turn checkpoints, worktrees, commits, pushes and pull requests, and a GitHub PR workspace.
- An integrated terminal and a browser in every thread, which agents can drive when you allow it.
- Computer Use (off by default), scheduled tasks, bots, dictation, Keep Awake, a usage dashboard and the `coincide` command-line tool.
- 19 languages (machine-translated; corrections are welcome).
- Ships as a notarized universal DMG for Apple silicon and Intel Macs, with `brew install --cask apoorvdarshan/tap/coincide` and `npx coincide-dev` as other ways to install. Coincide → Check for Updates installs later releases.
