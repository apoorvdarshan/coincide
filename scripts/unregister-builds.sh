#!/bin/bash
# Removes every app bundle under the given folders or apps from Launch Services, helpers nested in Coincide.app (such
# as CoincideAgentHost.app) included. Xcode registers each app it builds, and macOS can pick any registered copy with an
# app's bundle ID for that app's notification icon or to open a notification click, so a build that isn't installed
# should be unregistered once it's done. Never touches /Applications.
#
# Usage: scripts/unregister-builds.sh <DerivedData folder, build products folder or .app>...
set -euo pipefail

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for root in "$@"; do
    [ -e "$root" ] || continue
    find "$root" -name '*.app' -type d -print0 | while IFS= read -r -d '' app; do
        case "$app" in /Applications/*) continue ;; esac
        "$lsregister" -u "$app" 2>/dev/null || true
    done
done
