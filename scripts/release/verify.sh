#!/bin/bash
# Checks what scripts/release/build.sh produces; any failure exits non-zero.
#
#   verify.sh app <Coincide.app> <version> <team ID>
#       Before notarization: bundle identifier and version; every Mach-O file universal (arm64 + x86_64), signed by the
#       team (Cua Driver keeps Cua AI's signature) with a secure timestamp and no get-task-allow; every executable with
#       the hardened runtime; the whole bundle valid with `codesign --verify --deep --strict`.
#   verify.sh release <output folder> <version> <team ID>
#       After notarization: the stapled DMG passes Gatekeeper (`spctl -t install`) and holds Coincide.app and an
#       Applications link; the app inside it and the one in Coincide-macos-universal.zip pass the checks above,
#       Gatekeeper and stapler; and the in-app updater's own code accepts the ZIP (check-update-archive.swift).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
bundle_id=com.apoorvdarshan.coincide
cua_team=YCK386LBJ7

fail() { echo "error: $*" >&2; exit 1; }

check_app() {
    local app="$1" version="$2" team="$3" file info flags signer
    [ -d "$app" ] || fail "$app doesn't exist"
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = "$bundle_id" ] \
        || fail "$app isn't $bundle_id"
    [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version" ] \
        || fail "$app isn't version $version"
    local count=0
    while IFS= read -r -d '' file; do
        info="$(file -b "$file")"
        case "$info" in *Mach-O*) ;; *) continue ;; esac
        count=$((count + 1))
        local relative="${file#"$app"/}"
        local archs
        archs="$(lipo -archs "$file")"
        [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$relative has only: $archs"
        signer="$(codesign -dvv "$file" 2>&1)" || fail "$relative isn't signed"
        flags="$(sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-f]*\).*/\1/p' <<<"$signer")"
        local expected="$team"
        [ "$relative" = Contents/Helpers/cua-driver ] && expected="$cua_team"
        grep -qx "TeamIdentifier=$expected" <<<"$signer" || fail "$relative isn't signed by team $expected"
        grep -q '^Timestamp=' <<<"$signer" || fail "$relative has no secure timestamp"
        if [[ "$info" == *executable* ]] && (( (flags & 0x10000) == 0 )); then
            fail "$relative doesn't have the hardened runtime"
        fi
        if codesign -d --entitlements - --xml "$file" 2>/dev/null | grep -q get-task-allow; then
            fail "$relative has the get-task-allow entitlement, which notarization refuses"
        fi
    done < <(find "$app" -type f -print0)
    (( count > 0 )) || fail "no code found in $app"
    codesign --verify --deep --strict --verbose=2 "$app"
    echo "$app: $count Mach-O files, all universal, signed, timestamped; executables hardened"
}

check_notarized_app() {
    xcrun stapler validate "$1"
    spctl --assess --type execute -vvv "$1" 2>&1 | tee /dev/stderr | grep -q 'source=Notarized Developer ID' \
        || fail "Gatekeeper doesn't see $1 as notarized"
}

mode="${1:-}"
[ $# -eq 4 ] || fail "usage: verify.sh app|release <path> <version> <team ID>"
path="$2" version="$3" team="$4"
case "$mode" in
app)
    check_app "$path" "$version" "$team"
    ;;
release)
    dmg="$path/Coincide-$version.dmg"
    zip="$path/Coincide-macos-universal.zip"
    if [ ! -f "$dmg" ] || [ ! -f "$zip" ]; then fail "$path is missing Coincide-$version.dmg or Coincide-macos-universal.zip"; fi
    work="$(mktemp -d)"
    mount="$work/volume"
    trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rm -rf "$work"' EXIT

    codesign --verify --strict --verbose=2 "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type install -vvv "$dmg" 2>&1 | tee /dev/stderr | grep -q 'source=Notarized Developer ID' \
        || fail "Gatekeeper doesn't see $(basename "$dmg") as notarized"
    mkdir "$mount"
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg"
    [ "$(readlink "$mount/Applications")" = /Applications ] || fail "the DMG has no Applications link"
    [ "$(find "$mount" -mindepth 1 -maxdepth 1 ! -name '.*' | wc -l | tr -d ' ')" = 2 ] \
        || fail "the DMG should hold only Coincide.app and Applications"
    check_app "$mount/Coincide.app" "$version" "$team"
    check_notarized_app "$mount/Coincide.app"
    hdiutil detach -quiet "$mount"

    ditto -x -k "$zip" "$work/zip"
    [ "$(ls "$work/zip")" = Coincide.app ] || fail "the ZIP should hold only Coincide.app"
    check_app "$work/zip/Coincide.app" "$version" "$team"
    check_notarized_app "$work/zip/Coincide.app"

    swiftc -parse-as-library -O -swift-version 6 -default-isolation nonisolated -o "$work/check-update-archive" \
        "$root/scripts/release/check-update-archive.swift" "$root"/CoincideKit/Updates/*.swift
    "$work/check-update-archive" "$zip" "$version" "$team"
    ;;
*)
    fail "usage: verify.sh app|release <path> <version> <team ID>"
    ;;
esac
