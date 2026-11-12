#!/bin/sh
# Sync Coincide Remote's iOS string catalog. This does not install the app.
set -eu
cd "$(dirname "$0")/.."
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/coincide-remote-simulator-tests}"
case "${1:-ios}" in ios|all) ;; *) echo 'usage: sync-strings.sh [ios]' >&2; exit 2;; esac
xcodegen generate --spec project-remote.yml --quiet
xcodebuild -project CoincideRemote.xcodeproj -scheme CoincideRemote -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -derivedDataPath "$DERIVED_DATA" build -quiet CODE_SIGNING_ALLOWED=NO
find "$DERIVED_DATA/Build/Intermediates.noindex" -name '*.stringsdata' -path '*/Debug-iphonesimulator/CoincideRemote*' -print0 \
  | xargs -0 xcrun xcstringstool sync CoincideRemote/Localizable.xcstrings --stringsdata
