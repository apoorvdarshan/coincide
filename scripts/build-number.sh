#!/bin/bash
# Writes BuildNumber.xcconfig (gitignored), which Signing.xcconfig includes: CURRENT_PROJECT_VERSION, every target's
# CFBundleVersion, set to the number of commits in HEAD's history. It grows with each commit, so a build of a newer
# main installs with a higher CFBundleVersion. macOS keys what it caches about an app (the icon Notification Center
# shows, Launch Services' choice among copies with one bundle ID) on that version, and the agent host is replaced by
# the app's own once it sees another build. `xcodegen generate` runs this (preGenCommand in project.yml). Without
# git history, or in a shallow clone, the number is 1 or the clone's depth.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
count="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
file="$root/BuildNumber.xcconfig"
content="// Written by scripts/build-number.sh when the project is generated; not tracked.
CURRENT_PROJECT_VERSION = $count"
# Rewritten only when the number changes, so Xcode doesn't rebuild for nothing.
if [ ! -f "$file" ] || [ "$(cat "$file")" != "$content" ]; then printf '%s\n' "$content" >"$file"; fi
