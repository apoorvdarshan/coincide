#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---build-for-testing}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/coincide-desktop-ui-tests"
PROJECT="$ROOT_DIR/UITests/macOS/CoincideDesktopUITests.xcodeproj"
SCHEME="CoincideDesktopUITests"
case "$MODE" in
  --build-for-testing) ;;
  --ci)
    if [[ "${GITHUB_ACTIONS:-}" != "true" || "${CI:-}" != "true" ]]; then
      echo "Native GUI execution is limited to GitHub Actions; use --build-for-testing for a local compile." >&2
      exit 2
    fi
    ;;
  *) echo "usage: $0 [--build-for-testing | --ci <SwiftPM-app-bundle>]" >&2; exit 2 ;;
esac
FREE_KIB="$(df -k /System/Volumes/Data | awk 'NR == 2 { print $4 }')"
if [[ "$FREE_KIB" -lt 31457280 ]]; then
  echo "Less than 30 GB free. Native UI compilation stopped without deleting user data." >&2
  exit 1
fi
build_runner() {
  xcodebuild build-for-testing -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  # Built outside the runner sandbox, then sealed into the signed test bundle.
  # The runner only creates symlinks to these immutable executable bytes.
  local helper="$DERIVED_DATA/Build/Products/Debug/CoincideOfflineCLI"
  local embedded="$DERIVED_DATA/Build/Products/Debug/CoincideDesktopUITests-Runner.app/Contents/PlugIns/CoincideDesktopUITests.xctest/Contents/Resources/CoincideOfflineCLI"
  codesign --verify --strict "$helper"
  codesign --verify --strict "$embedded"
  cmp "$helper" "$embedded"
  codesign -d --entitlements :- "$embedded" 2>/dev/null | python3 -c 'import plistlib,sys; data=sys.stdin.buffer.read(); value=plistlib.loads(data) if data.strip() else {}; forbidden={"com.apple.security.app-sandbox","com.apple.security.inherit","com.apple.security.get-task-allow"}; assert not forbidden.intersection(value), "Unexpected entitlements on the test-only offline CLI helper."'
  local fixture_python
  fixture_python="$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')"
  python3 "$ROOT_DIR/UITests/macOS/verify_offline_launcher.py" "$embedded" "$fixture_python"
}
if [[ "$MODE" == "--build-for-testing" ]]; then
  build_runner
  echo "Native UI runner compiled without launching any app: $DERIVED_DATA"
  exit 0
fi
ARTIFACTS="${COINCIDE_UI_ARTIFACTS:-$RUNNER_TEMP/coincide-desktop-ui-artifacts}"
mkdir -p "$ARTIFACTS"
build_runner 2>&1 | tee "$ARTIFACTS/xcodebuild-build.log"
SOURCE_APP="${2:?Provide the SwiftPM-built application bundle.}"
[[ -d "$SOURCE_APP/Contents/MacOS" && -f "$SOURCE_APP/Contents/Info.plist" ]]
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" != "com.apoorvdarshan.coincide" || \
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_APP/Contents/Info.plist")" != "Coincide" ]]; then
  echo "The source bundle must be the verified SwiftPM Coincide app." >&2
  exit 1
fi
codesign --verify --strict "$SOURCE_APP"
codesign --verify --deep --strict "$DERIVED_DATA/Build/Products/Debug/CoincideDesktopUITests-Runner.app"
SCRATCH="$(mktemp -d "$RUNNER_TEMP/coincide-desktop-ui.XXXXXX")"
chmod 700 "$SCRATCH"
STAGED_APP="$SCRATCH/CoincideUITestApp.app"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.apoorvdarshan.coincide.uitesting' "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
mkdir -m 700 "$SCRATCH/coincide-ui-testing-bootstrap"
# Resolve Apple's developer-tool shim before entering the sandboxed UI runner.
GIT_EXECUTABLE="$(xcrun --find git)"
PYTHON_EXECUTABLE="$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))')"
XCTESTRUN="$(python3 - "$DERIVED_DATA/Build/Products" <<'PY'
from pathlib import Path
import sys
files = list(Path(sys.argv[1]).glob('CoincideDesktopUITests_*.xctestrun'))
if len(files) != 1:
    raise SystemExit('Expected exactly one generated native UI xctestrun file.')
print(files[0])
PY
)"
python3 "$ROOT_DIR/script/macos_ui_ci.py" prepare --xctestrun "$XCTESTRUN" --app "$STAGED_APP" \
  --bootstrap "$SCRATCH/coincide-ui-testing-bootstrap" --git "$GIT_EXECUTABLE" --python "$PYTHON_EXECUTABLE"
set +e
xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' \
  -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$ARTIFACTS/Results.xcresult" \
  2>&1 | tee "$ARTIFACTS/xcodebuild-test.log"
PIPE_RESULTS=("${PIPESTATUS[@]}")
set -e
STATUS="${PIPE_RESULTS[0]}"
if [[ "${PIPE_RESULTS[1]}" != 0 ]]; then STATUS=1; fi
if [[ -d "$ARTIFACTS/Results.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$ARTIFACTS/Results.xcresult" > "$ARTIFACTS/summary.json" || STATUS=1
  xcrun xcresulttool export attachments --path "$ARTIFACTS/Results.xcresult" --output-path "$ARTIFACTS/attachments" || STATUS=1
  python3 "$ROOT_DIR/script/macos_ui_ci.py" verify-results "$ARTIFACTS/summary.json" || STATUS=1
else
  echo "No native UI test result bundle was produced." >&2
  STATUS=1
fi
# Only this staged app may be stopped. Preserve scratch if it cannot close cleanly.
if swift "$ROOT_DIR/script/stop_app.swift" "$STAGED_APP" > "$ARTIFACTS/app-cleanup.log" 2>&1; then
  rm -rf "$SCRATCH"
else
  echo "The task-owned test app is still running; scratch was preserved at $SCRATCH" >&2
  STATUS=1
fi
exit "$STATUS"
