#!/bin/bash
# Builds Coincide for distribution (see docs/releasing.md):
#
#   1. a universal (arm64 + x86_64) Release build, signed with Developer ID, the hardened runtime and secure timestamps;
#   2. the app notarized and stapled;
#   3. Coincide-macos-universal.zip, the asset the in-app updater (docs/app-updates.md) and `npx coincide-dev` install;
#   4. Coincide-<version>.dmg (the app and an Applications link), signed, notarized and stapled, and its copy
#      Coincide.dmg, the name coincide.dev links to through releases/latest/download;
#   5. SHA256SUMS.txt for those three files.
#
# Every artifact is verified (scripts/release/verify.sh) before the script succeeds. .github/workflows/release.yml
# runs it on GitHub Actions; on a Mac with the Developer ID identity in the login keychain it works the same.
#
#   scripts/release/build.sh [output folder]          default: build/release
#
# Environment:
#   SIGNING_IDENTITY  codesign identity, default "Developer ID Application: Apoorv Darshan (23RV7FYH36)"
#   TEAM_ID           its team, default 23RV7FYH36
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                     the App Store Connect API key (.p8 file) notarytool signs in with
#   NOTARIZE=0        skip notarization, for a local check of the build and signing only; such artifacts fail
#                     Gatekeeper and must never be published
#   DERIVED_DATA      DerivedData folder, default build/DerivedData-release
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
identity="${SIGNING_IDENTITY:-Developer ID Application: Apoorv Darshan (23RV7FYH36)}"
team="${TEAM_ID:-23RV7FYH36}"
notarize="${NOTARIZE:-1}"
output="${1:-$root/build/release}"
derived="${DERIVED_DATA:-$root/build/DerivedData-release}"
version="$(scripts/release/version.sh)"

log() { printf '\n==> %s\n' "$*"; }

if [ "$notarize" = 1 ]; then
    : "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH must name the App Store Connect API key (.p8), or set NOTARIZE=0}"
    : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required for notarization}"
    : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required for notarization}"
    [ -r "$NOTARY_KEY_PATH" ] || { echo "error: can't read $NOTARY_KEY_PATH" >&2; exit 1; }
fi
# CFBundleVersion is the commit count (scripts/build-number.sh), which a shallow clone gets wrong.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "error: this is a shallow clone; fetch the full history so the build number is right" >&2
    exit 1
fi
security find-identity -v -p codesigning | grep -qF "\"$identity\"" || {
    echo "error: the signing identity \"$identity\" isn't in the keychain search list" >&2
    exit 1
}

log "Generating the project for Coincide $version"
xcodegen generate --quiet

log "Building a universal Release"
rm -rf "$output"
mkdir -p "$output"
build_log="$output/xcodebuild.log"
# Command-line settings apply to every target: the app, its agent host and helper tools, CoincideKit and the Swift
# packages. Coincide.entitlements lets the hardened runtime keep the microphone and Apple Events (see the file).
# Outside `xcodebuild archive`, Xcode adds get-task-allow (debugging) to every signature unless told not to, and
# notarization refuses it.
xcodebuild -project Coincide.xcodeproj -scheme Coincide -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    COINCIDE_MAC_ENTITLEMENTS=Coincide/Coincide.entitlements COINCIDE_MAC_PROFILE= \
    clean build >"$build_log" 2>&1 || {
    grep -E ': error:|^error:' "$build_log" | head -50 >&2 || true
    tail -60 "$build_log" >&2
    echo "error: the build failed; the full log is $build_log" >&2
    exit 1
}
built="$derived/Build/Products/Release/Coincide.app"
[ -d "$built" ] || { echo "error: the build produced no Coincide.app" >&2; exit 1; }
app="$output/Coincide.app"
ditto "$built" "$app"
scripts/release/verify.sh app "$app" "$version" "$team"

# notarize FILE: submits it and waits; on rejection prints Apple's log, which lists each problem by path.
notarize() {
    local file="$1" result id status
    log "Notarizing $(basename "$file")"
    result="$(xcrun notarytool submit "$file" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" --wait --timeout 2h --output-format json)" || true
    id="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
    echo "Submission ${id:-?}: ${status:-no result}"
    if [ "$status" != Accepted ]; then
        [ -z "$id" ] || xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" || true
        echo "error: notarization of $(basename "$file") ended with ${status:-no result}" >&2
        exit 1
    fi
}

# staple FILE: right after acceptance the ticket can take a moment to reach Apple's CDN, so this retries.
staple() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if xcrun stapler staple "$1"; then xcrun stapler validate "$1"; return; fi
        sleep $((attempt * 15))
    done
    echo "error: couldn't staple $(basename "$1")" >&2
    exit 1
}

# zip_app APP ZIP: a plain archive of Coincide.app, without resource forks, extended attributes or ACLs, which the
# app's signature doesn't need and the in-app updater's archive reader doesn't accept.
zip_app() { ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$1" "$2"; }

if [ "$notarize" = 1 ]; then
    upload="$output/notarize-app.zip"
    zip_app "$app" "$upload"
    notarize "$upload"
    rm -f "$upload"
    staple "$app"
fi

log "Packaging"
zip="$output/Coincide-macos-universal.zip"
zip_app "$app" "$zip"

dmg="$output/Coincide-$version.dmg"
stage="$output/dmg"
mkdir "$stage"
ditto "$app" "$stage/Coincide.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Coincide -srcfolder "$stage" -fs HFS+ -format ULMO -ov -quiet "$dmg"
rm -rf "$stage"
codesign --sign "$identity" --timestamp "$dmg"
if [ "$notarize" = 1 ]; then
    notarize "$dmg"
    staple "$dmg"
fi
cp "$dmg" "$output/Coincide.dmg"

if [ "$notarize" = 1 ]; then
    scripts/release/verify.sh release "$output" "$version" "$team"
else
    echo "warning: not notarized; these artifacts fail Gatekeeper and must not be published" >&2
fi
(cd "$output" && shasum -a 256 "Coincide-$version.dmg" Coincide.dmg Coincide-macos-universal.zip >SHA256SUMS.txt)
rm -rf "$app"
log "Done"
ls -l "$output"
cat "$output/SHA256SUMS.txt"
