# Coincide

[![CI](https://github.com/apoorvdarshan/coincide/actions/workflows/ci.yml/badge.svg)](https://github.com/apoorvdarshan/coincide/actions/workflows/ci.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15854/badge)](https://www.bestpractices.dev/projects/15854)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/apoorvdarshan/coincide/badge)](https://scorecard.dev/viewer/?uri=github.com/apoorvdarshan/coincide)

A native macOS app for the coding agents you already pay for — **Claude Code, Codex, Cursor, Grok Build, OpenCode, Pi, Antigravity, fx and Muse Code**, plus any agent from the ACP Registry or a local ACP command — in one window, with one model picker, and the ability to **switch agents in the middle of a thread**.

Coincide is a native AppKit port of [T3 Code](https://github.com/pingdotgg/t3code). It drives each agent's own command-line tool with the login you already have, so your existing subscriptions keep working. Coincide never sells, proxies or meters tokens.

> Status: early development. Expect rough edges.

## Why native

T3 Code is an Electron app with a Node server behind a web UI. Coincide is built with AppKit (and SwiftUI where it fits, like Settings) and talks to the agents in-process, so it starts instantly, idles at a fraction of the memory, scrolls long streaming transcripts smoothly, and gets macOS 26 Liquid Glass, menus, shortcuts, accessibility and notifications for free.

## Features

- **Every agent, one picker.** Models from all installed and signed-in agents appear in one menu, grouped by agent, with reasoning effort where the model has it.
- **Switch mid-thread.** Each agent keeps its own native session for the thread. When you switch, the next agent gets a recap of the turns it missed and continues in the same working directory. Switch back and the earlier agent resumes its own session.
- **Projects and threads** in a sidebar with search, pinning and archiving, plus a ⌘K command palette.
- **Full access or approvals.** Let agents run freely, or approve each command and file edit. Agents can also ask you questions, which you answer inline.
- **Plan mode**, image attachments, `@` file mentions, `/` commands (including `/claude`, `/codex`, … to switch agents), `$` skills for fx, queued follow-up messages and per-thread drafts.
- **A native transcript** with Markdown, syntax-highlighted code, collapsible work logs per turn, and each reply labelled with the agent and model that wrote it.
- **Git built in:** a diff inspector for uncommitted changes, the branch and each turn; checkpoints to revert a turn; per-thread worktrees; commit, push and pull requests with agent-written messages.
- **Steer or queue.** While an agent works, steer the running turn (Claude Code, Codex, OpenCode, Pi, Muse Code) or queue a follow-up; Settings picks which one sending does. The composer shows your plan's usage limits for Claude Code, Codex, Cursor, OpenCode Go, Grok Build, Antigravity and Muse Code.
- **Fork and rewind.** Fork a thread from any turn, or edit an earlier message and continue from there.
- **Pull and merge requests** on GitHub, GitLab, Bitbucket, Azure DevOps and Forgejo/Codeberg, through each host's CLI or its web page.
- **Integrated terminal** per thread, with tabs and splits.
- **Custom keyboard shortcuts** for every menu command, with conflict warnings.
- Fast with long histories: thread lists load from a small index and transcripts load only when opened.
- Notifications when a turn finishes or needs you while Coincide is in the background.
- **19 languages:** English, Chinese (Simplified and Traditional), Dutch, French, German, Hindi, Indonesian, Italian, Japanese, Korean, Polish, Portuguese (Brazil), Russian, Spanish (Spain and Latin America), Turkish, Ukrainian and Vietnamese. The translations are machine-made and marked for review; corrections are welcome.

## Agents

Install and sign in to at least one:

| Agent | How Coincide talks to it | Install and sign in |
|---|---|---|
| Claude Code | `claude` stream-json control protocol (as the Agent SDK does) | [Install](https://claude.com/product/claude-code), then `claude auth login` |
| Codex | `codex app-server` (JSON-RPC) | [Install](https://developers.openai.com/codex/cli), then `codex login` |
| Cursor | `cursor-agent acp` (Agent Client Protocol) | [Install](https://cursor.com/cli), then `cursor-agent login` |
| Grok Build | `grok` over ACP | [Install](https://x.ai/cli), then `grok login` |
| OpenCode | `opencode serve` HTTP API | [Install](https://opencode.ai), then `opencode auth login` |
| Pi | `pi --mode rpc` | Install Pi and sign in |
| Antigravity | Antigravity's ACP runtime | Install Antigravity and sign in with Google |
| fx | `fx acp` (Agent Client Protocol) | [Install](https://fx.sh) with `curl -fsSL https://fx.sh/setup.sh \| bash`, then `fx login` |
| Muse Code | `muse serve` (MSP, JSON-RPC) | [Install](https://dev.meta.ai/docs/muse-code), then `muse login`; turn it on in Settings › Providers |

**Full access** runs agents without asking first (for Claude Code that is `--permission-mode bypassPermissions`, the same as T3 Code's full-access mode). Choose **Ask for approval** in the composer to approve each command and file change.

fx offers neither full access nor plan mode, so as in T3 Code its threads always run in fx's Supervised mode: fx asks before it changes files or runs commands. Its model picker starts with **Default**, the model `fx status` reports, and every fx model has an effort setting that starts at Medium. Type `$` in the composer to pick one of the skills fx finds in its skill folders. Another ready agent writes the commit messages and pull request text of an fx thread, since fx keeps every session it opens (with no other agent ready, Coincide falls back to its plain summary).

Muse Code is off until you turn it on, as in T3 Code. It uses the login `muse login` saves; to use an API key instead, add `META_API_KEY` to its environment variables in Settings (one set in your login shell is ignored). As in T3 Code, Muse has no Plan mode, so the composer doesn't offer one; when Muse writes commit messages or pull request text, it runs without its shell and file-writing tools.

### Any other ACP agent

Coincide also runs any agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com), as T3 Code does. Open **Settings › Providers** and choose **Add ACP Agent…**:

- **ACP Registry:** search the official [ACP Registry](https://agentclientprotocol.com/get-started/registry) and choose **Add**. Coincide installs the agent at the version the registry publishes, into `tools/acp/<agent-id>/<version>/` in its data folder: a download is checked against the registry's SHA-256 when it publishes one (otherwise only HTTPS vouches for it), and an npm or Python package installs with your own `npm` or `uv` into a prefix Coincide owns, never globally. The search only lists agents that can run on this Mac, and leaves out the agents Coincide has built in. Registry agents are third-party code that runs with your permissions: review an agent's source and license before you add it. The agent's page offers updates when the registry publishes a newer version; removing the agent deletes its files.
- **Local ACP command:** enter an installed executable (a name on your shell's PATH or a full path), one literal argument per row, a name and any environment variables. Coincide starts it directly, without a shell. For DeepSeek Harness, use `dsh` with the arguments `--profile` and `acp`.

Then sign in on the agent's page with the methods it advertises: Coincide asks the agent to sign in by itself (showing any page it wants opened before telling it to go on), runs a terminal sign-in in Terminal, or names the API key variables to set under **Environment Variables**. Credentials stay in the agent's own store. Models, modes and reasoning options come from the agent over ACP; add model IDs it doesn't list under **Models**. An added agent works like a built-in one: it appears in the model picker, threads can switch to it mid-thread (`/<agent-id>`), and approvals follow the thread's access mode. As in T3 Code, added agents don't write commit messages or pull request text; another ready agent does.

## Requirements

- macOS 26 or later
- To build: Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build from source

```sh
brew install xcodegen
git clone https://github.com/apoorvdarshan/coincide.git
cd coincide
xcodegen generate
open Coincide.xcodeproj
```

Run the unit tests:

```sh
xcodebuild -project Coincide.xcodeproj -scheme Coincide test
```

Live provider tests talk to the real agent CLIs with your own account, so they only run when you ask:

```sh
xcodebuild -project Coincide.xcodeproj -scheme Coincide test TEST_RUNNER_COINCIDE_LIVE_TESTS=1
```

After changing user-facing text, update the string catalog with `scripts/sync-strings.sh`.

## Project layout

| Path | What's there |
|---|---|
| `CoincideKit/` | Framework with everything that isn't UI: models, storage, the provider interface and each provider, the turn runner, mid-thread handoff, git, worktrees and checkpoints |
| `Coincide/` | The AppKit app: window, sidebar, command palette, transcript, composer, diff inspector, terminal, settings |
| `CoincideKitTests/` | Unit tests (Swift Testing) and opt-in live provider tests |

Data lives in `~/Library/Application Support/Coincide` (set `COINCIDE_DATA_DIR` to use another folder).

## Credits

Coincide ports the design and behavior of [T3 Code](https://github.com/pingdotgg/t3code) by T3 Tools Inc., released under the MIT License. The terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Coincide is released under the [MIT License](LICENSE).

Made by [Apoorv Darshan](https://github.com/apoorvdarshan) · X [@apoorvdarshan](https://x.com/apoorvdarshan) · Instagram [@apoorvcodes](https://instagram.com/apoorvcodes)
