# Desktop shell

App-level macOS integration: environment, quitting, power, banners, links, the
`coincide` command, first-run setup, licenses and bundle metadata. The process-wide
pieces (login-shell capture, the ⌘Q monitor, power assertions and the automatic
welcome window) run only in the packaged app (`com.apoorvdarshan.coincide`). SwiftPM
tests and the synthetic UI-test copy keep their exact environment and a single-press ⌘Q.

## Login-shell environment

Finder and Dock launches inherit launchd's minimal environment, so CLIs installed with
nvm, fnm, volta, mise, asdf, bun or Homebrew, and variables set in `~/.zshrc` or
`~/.zprofile`, are otherwise missing. At launch Coincide runs `$SHELL -ilc`, then the
account's login shell, then `/bin/zsh`, in its own session and process group with stdin
from `/dev/null`. Each probe has a 5-second timeout and a 1 MiB output cap; on timeout
or overflow the whole group is killed and no further shells are tried. Only the
`/usr/bin/env -0` block between two random sentinels is parsed, so startup-file output
is ignored. If no shell reports `PATH`, `launchctl getenv PATH` (2 seconds) is used.

Captured names: `PATH`, `LANG`, `LC_ALL`, `LC_CTYPE`, `SSH_AUTH_SOCK`, `HOMEBREW_PREFIX`,
`HOMEBREW_CELLAR`, `HOMEBREW_REPOSITORY`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
`SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS` and `__MISE_DIFF`. `PATH` becomes
shell entries, then inherited entries, then the existing fixed fallbacks, without
duplicates. Other names fill only missing values; `__MISE_DIFF` follows the shell's
`PATH`. The locale names are one group: they are copied only when none is inherited, and
`LC_CTYPE=en_US.UTF-8` is set when the result still has no locale.

Launch waits at most 3 seconds for the capture before opening the workspace; a slower
shell is published when it finishes. Every provider, terminal and Git launch reads the
published snapshot through `ProcessChannel.environment()` when it starts, so running
conversations and terminals keep the environment they started with. Settings → General
→ Shell environment shows the source and `PATH` entry count, can refresh the capture or
turn it off. `COINCIDE_LOGIN_SHELL_ENV=0` disables it for a launch.

## Quitting

⌘Q follows T3's quit-hold behavior. In the default **Hold or press twice** mode, hold ⌘Q
for 1.2 seconds (key repeat proves the hold) or press it twice within 500 ms; a HUD
explains this after the first press. **Press twice** accepts only two presses, and
**Quit immediately** restores a single press. Choosing Quit from the Coincide menu always
quits at once. While a modal alert is open the shortcut is not intercepted.

Before the unsaved-attachment, unsaved-edit and remote-draft guards, Coincide asks once
when local conversations are running or awaiting approval, or when the connected remote
environment has active work. Quitting stops local turns (unfinished runs are marked
interrupted and queues wait for Resume) and disconnecting stops remote work. The alert
has a "Don't ask again" option, also available in Settings → General → Confirmations.

## Keeping the Mac awake

This is a native enhancement; T3 has no equivalent. While any local conversation or
remote active run is busy, Coincide holds a `ProcessInfo` activity that prevents App Nap.
Settings → General → While agents run → Keep Mac awake chooses whether it also prevents
idle system sleep: **While plugged in** (default), **Always** or **Never**. The display
can still sleep. Dropping to a lower level waits 30 seconds so a queue moving to its next
turn keeps the assertion; plugging in or unplugging is rechecked every 30 seconds while
work runs.

## In-app banners

Glass banners appear at the top trailing edge of the key window. At most three are kept;
ordinary banners expire after five seconds, errors stay until dismissed, and hovering
pauses expiry. VoiceOver announces each banner. When another conversation finishes,
fails or needs approval or input while Coincide is active, a banner with **Open**
appears; it is removed when the request is resolved or that conversation is selected.
Settings → General → Show banners for other conversations turns these off. System
notifications still cover the background case. Existing modal error alerts are unchanged.

## Links

| Link | Opens |
| --- | --- |
| `coincide://new?prompt=…` | A new conversation with the prompt as an unsent draft in the current project. |
| `…&repo=owner/name` | The most recently active project whose GitHub remote matches (forks match only their own owner). |
| `…&provider=codex&model=…` | That agent when it is installed here, and the model when its loaded list contains it; otherwise the default and a banner. |
| `coincide://new?pr=owner/name/123&prompt=…` | A draft in that repository's project and a note. Links never check out code. |
| `coincide://threads/<id>?prompt=…` | That conversation. An existing different draft is replaced or extended only after you confirm. |
| `coincide://open?path=/absolute/folder` | The folder as a project (added when needed) with an empty conversation; an existing empty one is reused. |

A link never sends, queues or steers anything and cannot change permissions, branches or
worktrees. Prompts are limited to 8,000 UTF-16 code units; zero-width, bidi, tag and other
invisible characters are removed with a warning, and a prompt made only of them is
refused. Edit → Copy Prompt Link copies the selected conversation's draft as a link;
Copy Prompt Link with Repository and Model adds the GitHub repository, agent and model;
Copy Conversation Link copies a `coincide://threads/…` link.

## The `coincide` command

Settings → General → Command-line tool installs a small POSIX script named `coincide`
into the first writable folder on your login-shell `PATH` among `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin` and `~/bin` (creating `~/.local/bin` when none can hold
it). It never replaces a file it did not write, reports another `coincide` earlier on
`PATH`, and Remove deletes only its own file. `coincide [folder]` resolves the folder and
opens a `coincide://open` link with the app; when the app has moved it falls back to the
bundle identifier and then explains how to reinstall. `COINCIDE_PRINT_LINK=1 coincide .`
prints the link instead of opening it.

## Welcome

A new installation with no projects or conversations opens the Welcome window after the
workspace loads; existing workspaces are marked as set up. **Agents** runs `codex login
status` and `claude auth status` (bounded, with the captured `PATH`) and shows Ready, Sign-in
needed, Not installed or the CLI's message, with the vendor's install command or the login
command to copy and an Open Terminal button. **Projects** adds a folder or opens Import
Agent Projects. Closing the window or finishing marks setup complete; Help → Welcome to
Coincide and Settings → Run Setup Again reopen it.

## Licenses and bundle metadata

`docs/third-party-notices.json` lists every shipped component with version, SPDX license,
the parts that use it, distribution (bundled, macOS system library or installed on demand)
and notice files. The build copies it with the notice texts into
`Contents/Resources/Notices`. Help → Open-Source Licenses and Settings → View Licenses open
a searchable viewer. Tests require every resolved package to have an entry with its pinned
version and every notice file to be referenced.

`script/Info.plist.template` is rendered by `script/build_and_run.sh` with the version from
`VERSION` and `COINCIDE_BUILD_NUMBER` (default 1). It adds the `coincide` URL scheme, the
developer-tools category, a copyright line and purpose strings for Desktop, Downloads,
removable and network volumes, the local network, camera, microphone and Apple Events that
explain they are used by commands run in terminals and by coding agents. The app icon is
drawn from vector geometry by `script/generate_app_icon.swift`, converted with `iconutil`
and cached under `.build/coincide-app-icon` by the generator's hash. The UI-test copy has its
URL types removed so it never handles real links.
