#!/bin/bash
# Fetches the Cua Driver release that Computer Use bundles in Coincide.app/Contents/Helpers (MIT License,
# github.com/trycua/cua), checks it against pinned checksums and Cua AI's Developer ID signature, and leaves only the
# driver in Vendor/CuaDriver (gitignored). `xcodegen generate` runs it first (preGenCommand in project.yml); the
# download is cached, so later runs and other checkouts work offline.
set -euo pipefail

version=0.38.0
asset="cua-driver-rs-$version-darwin-universal-binary.tar.gz"
archive_sha=2bb8dc4a7e69185ffd04c4a9c0eab590bd2c54b72c2c1be13ab675be4f487732
driver_sha=92067848d0eeb9de76929fbd06a137af801b0ff6caedbb3109bd7a6cc84a1f9f
team=YCK386LBJ7

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Vendor/CuaDriver"
driver="$dest/cua-driver"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

[ -f "$driver" ] && [ "$(sha "$driver")" = "$driver_sha" ] && exit 0

cache="$HOME/Library/Caches/Coincide/cua-driver/$version"
archive="$cache/$asset"
mkdir -p "$cache"
if [ ! -f "$archive" ] || [ "$(sha "$archive")" != "$archive_sha" ]; then
    echo "Downloading Cua Driver $version"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$archive.partial" \
        "https://github.com/trycua/cua/releases/download/cua-driver-rs-v$version/$asset"
    if [ "$(sha "$archive.partial")" != "$archive_sha" ]; then
        rm -f "$archive.partial"
        echo "error: the Cua Driver $version download doesn't match its pinned checksum" >&2
        exit 1
    fi
    mv "$archive.partial" "$archive"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work" cua-driver
if [ "$(sha "$work/cua-driver")" != "$driver_sha" ]; then
    echo "error: Cua Driver $version doesn't match its pinned checksum" >&2
    exit 1
fi
codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$work/cua-driver"
mkdir -p "$dest"
install -m 755 "$work/cua-driver" "$driver"
