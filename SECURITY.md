# Security policy

## Supported versions

Coincide is developed on the `main` branch and has no maintained release
branches. Security fixes land on the latest `main`; older commits and builds
do not receive backported fixes. Please check that a problem still occurs on
the latest `main` before reporting it.

## Reporting a vulnerability

Report security problems privately. Please do not open a public issue, pull
request or discussion about them.

- **Preferred:** GitHub private vulnerability reporting. Open the repository's
  **Security** tab and choose **Report a vulnerability**, or go directly to
  <https://github.com/apoorvdarshan/coincide/security/advisories/new>.
- **Email:** <apoorv@fud-ai.app>, with "Coincide security" in the subject.

Please include:

- the Coincide commit you tested (`git rev-parse HEAD`) and your macOS version;
- the Codex or Claude CLI version involved, if any (`codex --version`,
  `claude --version`);
- the steps to reproduce the problem and its impact: what an attacker can read,
  change or run;
- a proof of concept, if you have one.

Remove credentials before you send anything. Never include API keys, OAuth
tokens, provider configuration files, or the contents of Coincide's
`~/Library/Application Support/Coincide/` folder; describe them instead.

## What to expect

Coincide is maintained by one person in their spare time, so response times
vary. The maintainer aims to:

- acknowledge your report within 14 days;
- tell you whether the problem is confirmed after investigating it, and keep
  you updated while a fix is in progress;
- fix confirmed vulnerabilities on `main` with a priority that matches their
  severity;
- publish a GitHub security advisory for confirmed vulnerabilities, and credit
  you unless you prefer to stay anonymous.

There is no bug bounty. Please give the maintainer reasonable time to release
a fix before you disclose a problem publicly, and agree on a disclosure date
together if possible.

## Scope

In scope: code in this repository, including the macOS app, its libraries, the
`script/` tools and the GitHub Actions workflows.

Out of scope:

- vulnerabilities in the Codex or Claude CLIs, or in OpenAI or Anthropic
  services and accounts. Report those through
  [OpenAI's Codex security policy](https://github.com/openai/codex/blob/main/SECURITY.md)
  or [Anthropic's Claude Code security policy](https://github.com/anthropics/claude-code/blob/main/SECURITY.md);
- vulnerabilities in third-party dependencies, which should be reported
  upstream. Tell us as well if Coincide is affected;
- problems that require an attacker who already controls your macOS user
  account.
