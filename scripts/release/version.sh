#!/bin/bash
# Prints the Rust workspace version. A release tag is v<this>.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(awk '/^\[workspace.package\]/ { section=1; next } /^\[/ { section=0 } section && /^version = / { gsub(/[^0-9.]/, "", $0); print; exit }' "$root/Cargo.toml")"
# Three numeric components with no leading zeros.
if ! [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: workspace version in Cargo.toml (\"$version\") isn't a version like 1.2.3" >&2
    exit 1
fi
echo "$version"
