#!/bin/bash
# Prints the release notes of a version: its "## <version>" section of CHANGELOG.md, without the heading. Fails when the
# section is missing or empty, so a tag never publishes without notes.
#
#   scripts/release/notes.sh <version> [changelog]
set -euo pipefail
version="${1:?usage: notes.sh <version> [changelog]}"
changelog="${2:-$(cd "$(dirname "$0")/../.." && pwd)/CHANGELOG.md}"
notes="$(awk -v heading="## $version" '
    $0 == heading || index($0, heading " ") == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$changelog" | sed -e '/./,$!d')"
# Trailing blank lines too.
notes="$(printf '%s\n' "$notes" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
if [ -z "${notes//[[:space:]]/}" ]; then
    echo "error: $changelog has no notes under \"## $version\"" >&2
    exit 1
fi
printf '%s\n' "$notes"
