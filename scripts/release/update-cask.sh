#!/bin/bash
# Sets the version and sha256 of the Homebrew cask (Casks/coincide.rb in apoorvdarshan/homebrew-tap) for a release.
# Fails, changing nothing, unless the file has exactly one of each line to replace.
#
#   scripts/release/update-cask.sh <coincide.rb> <version> <sha256 of Coincide-<version>.dmg>
set -euo pipefail
cask="${1:?usage: update-cask.sh <coincide.rb> <version> <sha256>}"
version="${2:?version missing}"
sha="${3:?sha256 missing}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: \"$version\" isn't a version" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "error: \"$sha\" isn't a SHA-256" >&2; exit 1; }
for pattern in '^  version "[^"]*"$' '^  sha256 "[0-9a-f]{64}"$'; do
    [ "$(grep -cE "$pattern" "$cask")" = 1 ] || { echo "error: $cask should have one line like /$pattern/" >&2; exit 1; }
done
grep -qF 'url "https://github.com/apoorvdarshan/coincide/releases/download/v#{version}/Coincide-#{version}.dmg"' "$cask" \
    || { echo "error: $cask doesn't download Coincide-#{version}.dmg from the release" >&2; exit 1; }
updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT
sed -E -e "s/^  version \"[^\"]*\"$/  version \"$version\"/" -e "s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$sha\"/" \
    "$cask" >"$updated"
cat "$updated" >"$cask"
