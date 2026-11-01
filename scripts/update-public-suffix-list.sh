#!/bin/sh
# Refreshes CoincideKit/Preview/WebAuthn/public_suffix_list.dat, Mozilla's Public Suffix List (MPL 2.0), which passkey
# sign-in uses to check which relying party IDs a site may claim. The file ships unmodified; commit the new copy.
set -eu
cd "$(dirname "$0")/.."
DEST=CoincideKit/Preview/WebAuthn/public_suffix_list.dat
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# The list's maintainers ask that it be pulled from this address only.
curl --fail --silent --show-error --location --proto '=https' https://publicsuffix.org/list/public_suffix_list.dat -o "$TMP"
grep -q '===BEGIN ICANN DOMAINS===' "$TMP" && grep -q '===END PRIVATE DOMAINS===' "$TMP" || { echo "error: not the full list" >&2; exit 1; }
mv "$TMP" "$DEST"
trap - EXIT
grep -m1 '^// VERSION:' "$DEST"
