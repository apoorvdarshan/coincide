#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Coincide"
BUNDLE_ID="com.apoorvdarshan.coincide"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
cd "$ROOT_DIR"
case "$MODE" in run|--debug|--logs|--telemetry|--verify|--build-only) ;; *) echo "usage: $0 [--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;; esac
if [[ "$MODE" != "--build-only" ]]; then swift "$ROOT_DIR/script/stop_app.swift" "$APP_BUNDLE"; fi
swift build
BUILD_DIRECTORY="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_DIRECTORY/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
cp "$BUILD_DIRECTORY/CoincideScriptHelper" "$APP_BUNDLE/Contents/Helpers/CoincideScriptHelper"
cp "$BUILD_DIRECTORY/CoincideEnvironment" "$APP_BUNDLE/Contents/Helpers/CoincideEnvironment"
mkdir -p "$APP_BUNDLE/Contents/Resources/Notices"
/usr/bin/ditto "$BUILD_DIRECTORY/SwiftMath_SwiftMath.bundle" "$APP_BUNDLE/Contents/Resources/SwiftMath_SwiftMath.bundle"
for NOTICE_FILE in "$ROOT_DIR"/docs/*-LICENSE.txt "$ROOT_DIR"/docs/*-NOTICE.txt "$ROOT_DIR/docs/third-party-notices.json"; do
  /usr/bin/install -m 644 "$NOTICE_FILE" "$APP_BUNDLE/Contents/Resources/Notices/"
done
# The icon is drawn from vector geometry by script/generate_app_icon.swift and cached by its hash.
ICON_SOURCE="$ROOT_DIR/script/generate_app_icon.swift"
ICON_CACHE="$ROOT_DIR/.build/coincide-app-icon"
ICON_FILE="$ICON_CACHE/AppIcon-$(/usr/bin/shasum -a 256 "$ICON_SOURCE" | /usr/bin/awk '{ print $1 }').icns"
if [[ ! -s "$ICON_FILE" ]]; then
  ICON_WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/coincide-icon.XXXXXX")"
  swift "$ICON_SOURCE" "$ICON_WORK/AppIcon.iconset"
  mkdir -p "$ICON_CACHE"
  /usr/bin/iconutil -c icns -o "$ICON_WORK/AppIcon.icns" "$ICON_WORK/AppIcon.iconset"
  /bin/mv -f "$ICON_WORK/AppIcon.icns" "$ICON_FILE"
  /bin/rm -rf "$ICON_WORK"
fi
/usr/bin/install -m 644 "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
APP_VERSION="$(/usr/bin/tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="${COINCIDE_BUILD_NUMBER:-1}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "VERSION or COINCIDE_BUILD_NUMBER is invalid." >&2; exit 1; }
/usr/bin/sed -e "s/@APP_NAME@/$APP_NAME/g" -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@VERSION@/$APP_VERSION/g" -e "s/@BUILD@/$BUILD_NUMBER/g" \
  "$ROOT_DIR/script/Info.plist.template" > "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -lint -s "$APP_BUNDLE/Contents/Info.plist"
# A stable development identity preserves macOS file-access consent between builds.
# Hosted CI has no identity and uses ad-hoc signing. An explicit override wins.
SIGN_IDENTITY="${COINCIDE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/"Apple Development:/ && !found { print $2; found=1 }')"
fi
PROFILE_PATH="${COINCIDE_PROVISIONING_PROFILE:-}"
DEFAULT_PROFILE="$HOME/Library/Application Support/Coincide/Signing/development.provisionprofile"
if [[ -z "$PROFILE_PATH" && "$SIGN_IDENTITY" != "-" && ( -e "$DEFAULT_PROFILE" || -L "$DEFAULT_PROFILE" ) ]]; then PROFILE_PATH="$DEFAULT_PROFILE"; fi
SIGNING_TEMP=""
cleanup_signing() { if [[ -n "$SIGNING_TEMP" ]]; then /bin/rm -rf "$SIGNING_TEMP"; fi; }
trap cleanup_signing EXIT
if [[ -n "$PROFILE_PATH" ]]; then
  SIGNING_TEMP="$(/usr/bin/mktemp -d /private/tmp/coincide-signing.XXXXXX)"
  /bin/chmod 700 "$SIGNING_TEMP"
  python3 "$ROOT_DIR/script/prepare_macos_signing.py" \
    --profile "$PROFILE_PATH" --bundle-id "$BUNDLE_ID" --identity "${SIGN_IDENTITY:--}" \
    --output-entitlements "$SIGNING_TEMP/entitlements.plist" --output-profile "$SIGNING_TEMP/embedded.provisionprofile"
  # Embed the bytes actually validated, rather than reopening a mutable source.
  /bin/rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
  /usr/bin/install -m 600 "$SIGNING_TEMP/embedded.provisionprofile" "$APP_BUNDLE/Contents/embedded.provisionprofile"
else
  # This bundle is rebuilt by this script. Remove its stale prior profile only;
  # the user's source profile, other apps and signing setup are untouched.
  /bin/rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE/Contents/Helpers/CoincideScriptHelper" >/dev/null
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE/Contents/Helpers/CoincideEnvironment" >/dev/null
if [[ -n "$SIGNING_TEMP" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --entitlements "$SIGNING_TEMP/entitlements.plist" "$APP_BUNDLE" >/dev/null
else
  codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE" >/dev/null
fi
cleanup_signing; SIGNING_TEMP=""
case "$MODE" in
  --build-only) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Coincide"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.apoorvdarshan.coincide"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
