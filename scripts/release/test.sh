#!/bin/bash
# Tests of the release scripts that run anywhere (Linux included), before release.yml builds anything:
# ShellCheck, then the version, release notes and cask scripts on fixtures, and the npm installer's own tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

shellcheck scripts/release/*.sh
pass "shellcheck"

version="$(scripts/release/version.sh)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version.sh printed \"$version\""
[ "$(node -p 'require("./npm/package.json").version')" = "$version" ] || fail "npm/package.json isn't version $version"
pass "version $version, the npm package's too"

scripts/release/notes.sh "$version" >"$work/notes" || fail "CHANGELOG.md has no notes for $version"
[ -s "$work/notes" ] || fail "empty notes"
printf '# Changelog\n\n## 1.2.0\n\n- New.\n\n## 1.1.0\n- Old.\n\n## 1.0.0\n' >"$work/CHANGELOG.md"
[ "$(scripts/release/notes.sh 1.2.0 "$work/CHANGELOG.md")" = "- New." ] || fail "notes.sh 1.2.0"
[ "$(scripts/release/notes.sh 1.1.0 "$work/CHANGELOG.md")" = "- Old." ] || fail "notes.sh 1.1.0"
! scripts/release/notes.sh 1.0.0 "$work/CHANGELOG.md" 2>/dev/null || fail "notes.sh accepted an empty section"
! scripts/release/notes.sh 1.3.0 "$work/CHANGELOG.md" 2>/dev/null || fail "notes.sh accepted a missing section"
! scripts/release/notes.sh 1.2 "$work/CHANGELOG.md" 2>/dev/null || fail "notes.sh matched a version prefix"
pass "release notes"

cat >"$work/coincide.rb" <<'CASK'
cask "coincide" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/apoorvdarshan/coincide/releases/download/v#{version}/Coincide-#{version}.dmg"
end
CASK
sha="$(printf 'x' | shasum -a 256 | cut -d' ' -f1)"
scripts/release/update-cask.sh "$work/coincide.rb" 1.4.2 "$sha"
grep -qx '  version "1.4.2"' "$work/coincide.rb" || fail "update-cask.sh didn't set the version"
grep -qx "  sha256 \"$sha\"" "$work/coincide.rb" || fail "update-cask.sh didn't set the sha256"
cp "$work/coincide.rb" "$work/before.rb"
! scripts/release/update-cask.sh "$work/coincide.rb" 1.4 "$sha" 2>/dev/null || fail "update-cask.sh took a bad version"
! scripts/release/update-cask.sh "$work/coincide.rb" 1.4.3 nothex 2>/dev/null || fail "update-cask.sh took a bad sha256"
sed 's/Coincide-#{version}.dmg/Other.dmg/' "$work/before.rb" >"$work/other.rb"
! scripts/release/update-cask.sh "$work/other.rb" 1.4.3 "$sha" 2>/dev/null || fail "update-cask.sh took another download"
cmp -s "$work/coincide.rb" "$work/before.rb" || fail "a refused update changed the cask"
pass "cask update"

(cd npm && node --test "test/*.test.mjs")
pass "npm installer"
