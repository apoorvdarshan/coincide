#!/bin/bash
# Runs the checks GitHub Actions ran, on this Mac, and reports "Build and test" on the PR's head commit so main's
# ruleset can merge it. Usage: scripts/local-ci.sh <PR number>, or no argument to test the checked-out commit
# without reporting. Up to COINCIDE_MAX_BUILDS xcodebuilds (default 3) run at once on this Mac; each concurrent run
# takes its own slot, with its own DerivedData, so runs never share build products.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
pr="${1:-}"
max_builds="${COINCIDE_MAX_BUILDS:-3}"
context="Build and test"
log="$(mktemp -t coincide-ci).log"

if [ -n "$pr" ]; then
    # Test exactly the PR's head in a throwaway worktree, so local edits can't leak into the result.
    sha="$(gh pr view "$pr" --json headRefOid -q .headRefOid)"
    work="$(mktemp -d -t coincide-ci)"
    git fetch -q origin "$sha" 2>/dev/null || git fetch -q origin "pull/$pr/head"
    git worktree add -q --detach "$work" "$sha"
    # Signing settings are local and untracked; the worktree needs them to build like the main checkout.
    if [ -f "$root/Local.xcconfig" ]; then cp "$root/Local.xcconfig" "$work/"; fi
    cd "$work"
else
    sha="$(git rev-parse HEAD)"
fi

report() {
    [ -n "$pr" ] || return 0
    gh api -X POST "repos/{owner}/{repo}/statuses/$sha" -f state="$1" -f context="$context" \
        -f description="$2 on $(scutil --get LocalHostName)" >/dev/null
}

report pending "Running local CI"
# Wait for a free slot (a lock directory per slot) and for this Mac to have fewer than max_builds xcodebuilds running.
slot=""
while [ -z "$slot" ]; do
    if [ "$(pgrep -x xcodebuild | wc -l)" -lt "$max_builds" ]; then
        for i in $(seq 1 "$max_builds"); do
            if mkdir "${TMPDIR:-/tmp}/coincide-local-ci-slot-$i" 2>/dev/null; then slot="$i"; break; fi
        done
    fi
    [ -n "$slot" ] || sleep 5
done
cleanup() {
    rmdir "${TMPDIR:-/tmp}/coincide-local-ci-slot-$slot" 2>/dev/null || true
    # Every app the run built (Coincide.app, its nested agent host, the standalone host) registered with Launch
    # Services, passed or failed; unregistered, none can show up for a notification's icon or click.
    if [ -n "${derived:-}" ]; then "$root/scripts/unregister-builds.sh" "$derived/Build/Products" || true; fi
    if [ -n "$pr" ]; then git -C "$root" worktree remove --force "$work"; fi
}
trap cleanup EXIT
derived="$HOME/Library/Developer/Xcode/DerivedData/coincide-local-ci"
[ "$slot" = 1 ] || derived="$derived-$slot"

status=0
run_checks() {
    echo "== Fuzz sources"
    Fuzz/fuzz.sh check || return $?
    fuzzers="$(Fuzz/fuzz.sh list)" || return $?
    for fuzzer in $fuzzers; do (cd Fuzz && swift build -q --target "$fuzzer") || return $?; done
    echo "== Unit tests"
    xcodegen generate -q || return $?
    # -skipPackagePluginValidation runs SwiftTerm's build plug-in without Xcode's interactive trust prompt (project.yml).
    xcodebuild -project Coincide.xcodeproj -scheme Coincide -destination 'platform=macOS' -skipPackagePluginValidation \
        -derivedDataPath "$derived" test -collect-test-diagnostics never -quiet
}
run_checks >"$log" 2>&1 || status=$?

if [ "$status" -eq 0 ]; then
    report success "Local CI passed"
    echo "Passed: $sha"
else
    report failure "Local CI failed"
    grep -E "error:|failed|✘" "$log" | head -40 || true
    echo "Failed: $sha (log: $log)"
fi
exit "$status"
