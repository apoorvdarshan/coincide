#!/bin/bash
# Prints the app's version, MARKETING_VERSION in project.yml (CFBundleShortVersionString). A release's tag is v<this>.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$root/project.yml")"
# Three numeric components, no leading zeros: what the in-app updater accepts (UpdateVersion in AppUpdate.swift).
if ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: MARKETING_VERSION in project.yml (\"$version\") isn't a version like 1.2.3" >&2
    exit 1
fi
echo "$version"
