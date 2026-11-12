#!/bin/sh
# Refreshes the Rust app's Mozilla Public Suffix List (MPL 2.0), used by passkey sign-in.
set -eu
cd "$(dirname "$0")/.."
DEST=crates/coincide-core/resources/public_suffix_list.dat
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# The list's maintainers ask that it be pulled from this address only.
curl --fail --silent --show-error --location --proto '=https' https://publicsuffix.org/list/public_suffix_list.dat -o "$TMP"
grep -q '===BEGIN ICANN DOMAINS===' "$TMP" && grep -q '===END PRIVATE DOMAINS===' "$TMP" || { echo "error: not the full list" >&2; exit 1; }
mv "$TMP" "$DEST"
trap - EXIT
grep -m1 '^// VERSION:' "$DEST"
