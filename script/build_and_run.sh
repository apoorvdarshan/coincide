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
mkdir -p "$APP_BUNDLE/Contents/Resources/Notices"
/usr/bin/ditto "$BUILD_DIRECTORY/SwiftMath_SwiftMath.bundle" "$APP_BUNDLE/Contents/Resources/SwiftMath_SwiftMath.bundle"
for NOTICE_FILE in "$ROOT_DIR"/docs/*-LICENSE.txt "$ROOT_DIR"/docs/*-NOTICE.txt; do
  /usr/bin/install -m 644 "$NOTICE_FILE" "$APP_BUNDLE/Contents/Resources/Notices/"
done
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDocumentsFolderUsageDescription</key><string>Coincide and its coding agents access project files and the instructions you configure in Documents.</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Project Folder</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.folder</string></array>
</dict></array>
</dict></plist>
PLIST
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
