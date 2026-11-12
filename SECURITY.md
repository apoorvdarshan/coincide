# Security Policy

Coincide is a native desktop app that runs the coding agent CLIs you install (Claude Code, Codex, Cursor, Grok Build, OpenCode and Antigravity) on your Mac, with your own logins. It can run commands, edit files and drive git in the folders you open, so security reports are very welcome.

## Supported Versions

Coincide is in early development. Security fixes go into `main` and ship in the next release; only the latest release is supported. Older releases do not get fixes, so please update before reporting.

| Version | Supported |
|---|---|
| Latest release and `main` | Yes |
| Older releases | No |

## Reporting a Vulnerability

Please report vulnerabilities **privately**, not in a public issue, pull request or discussion.

Use GitHub's [private vulnerability reporting](https://github.com/apoorvdarshan/coincide/security/advisories/new) (the repository's **Security** tab → **Report a vulnerability**). Only the maintainer can see the report, and we can work on a fix and an advisory together there. If you cannot use it, open an issue that only asks for a private contact, with no details of the problem.

Please include:

- What the vulnerability is and what an attacker could do with it
- Steps to reproduce; a minimal proof of concept is ideal
- Your macOS version, Coincide version (**Coincide → About Coincide**, or the commit if you built from source), and the agent CLI and its version if one is involved
- Whether it needs a particular access mode (**Full access** or **Ask for approval**), setting or repository state
- Whether you want to be credited, and under which name

Never include real API keys, tokens, cookies or private code. Use placeholders, or a throwaway account and repository.

## What to Expect

Coincide has a single maintainer, so timelines are best effort:

- An acknowledgement within **7 days**.
- A first assessment (whether it is in scope, how severe it is, and a rough plan) within **14 days**.
- Updates at least every **14 days** until it is resolved. Critical issues come before everything else.

If you hear nothing within 7 days, add a comment to the advisory. Please keep the details private until a fixed release is out, or for **90 days** after your report if we have not agreed on another date. We will publish a GitHub security advisory for confirmed issues and, where it applies, request a CVE.

## Scope

**In scope:**

- The Rust desktop and core (`crates/`), and the iOS companion (`CoincideRemote/`, `CoincideRemoteKit/`).
- How Coincide starts and talks to agent CLI processes: the arguments and environment it passes (including the login shell environment it reads), and how it parses their output (Claude stream-json, Codex and ACP JSON-RPC, the OpenCode HTTP API and event stream). For example, agent output that crashes Coincide, runs code, or makes Coincide act outside the project folder.
- Access modes: anything that lets an agent run a command or change a file without asking while **Ask for approval** is selected, or that approves a request the user did not approve.
- File and terminal requests agents make through Coincide (ACP file system and terminal requests), such as reading or writing outside the working directory.
- The local OpenCode server Coincide starts, and anything that exposes it to other users or machines.
- Mid-thread handoff: a recap reaching an agent or session it was not meant for.
- Git features: worktrees, checkpoints and reverts, commits, pushes and pull requests (through `git` and `gh`). For example, branch names, paths or repository contents that inject options or commands, or a revert that deletes data it should not.
- The integrated terminal, attachments and `@` file mentions.
- Local data in the platform-specific Coincide Rust data directory: threads, drafts and settings. For example, other users or apps being able to read it, secrets being written there unexpectedly, or a damaged or crafted file crashing Coincide or running code.
- This repository's build and release tooling: GitHub Actions workflows and `scripts/`.

**Out of scope:**

- Vulnerabilities in the agent CLIs themselves or their services (report them to the agent's maker), and in T3 Code (report them upstream).
- What an agent does within the access you gave it. In **Full access**, running commands and editing files without asking is the documented behavior.
- Prompt injection that makes an agent misbehave within the access you gave it, unless Coincide itself grants more access than you chose.
- Attacks that need an already compromised Mac or a process already running as your user, which can read your files anyway.
- Using up your own agent subscription or API quota.
- Social engineering, and reports from automated scanners without a demonstrated impact.

## Safe Harbor

If you make a good-faith effort to follow this policy, we will not pursue or support legal action over your research. Only test against your own accounts, machines and repositories, do not access or change other people's data, and give us reasonable time to fix the issue before disclosing it.

## Credit

With your permission, we credit reporters of valid vulnerabilities in the advisory and the release notes of the fix.

## Supply Chain

GitHub Actions in this repository are pinned to full commit SHAs and kept current by Dependabot. Pull requests get dependency review and CodeQL analysis of the workflows, the Swift code gets a weekly CodeQL analysis, the retired Swift desktop parsers are fuzzed against a frozen legacy commit (not the current Rust code), and OpenSSF Scorecard checks the repository weekly.
