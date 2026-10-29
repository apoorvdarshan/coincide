#!/bin/sh
# Builds the apps and updates their string catalogs with every localizable string they use:
#   Coincide/Resources/Localizable.xcstrings   the Mac app, CoincideKit and CoincideRemoteKit (Kit strings resolve
#                                              through the app bundle)
#   CoincideRemote/Localizable.xcstrings       Coincide Remote on iOS and CoincideRemoteKit
# Pass `mac` or `ios` to sync only one of them.
set -eu
cd "$(dirname "$0")/.."
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/coincide-mac-debug}"
WHICH="${1:-all}"
xcodegen generate --quiet

if [ "$WHICH" = all ] || [ "$WHICH" = mac ]; then
  xcodebuild -project Coincide.xcodeproj -scheme Coincide -configuration Debug -derivedDataPath "$DERIVED_DATA" build -quiet
  find "$DERIVED_DATA/Build/Intermediates.noindex" -name '*.stringsdata' -path '*/Debug/*' -print0 \
    | xargs -0 xcrun xcstringstool sync Coincide/Resources/Localizable.xcstrings --stringsdata
fi

if [ "$WHICH" = all ] || [ "$WHICH" = ios ]; then
  xcodebuild -project Coincide.xcodeproj -scheme CoincideRemote -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" build -quiet CODE_SIGNING_ALLOWED=NO
  find "$DERIVED_DATA/Build/Intermediates.noindex" -name '*.stringsdata' -path '*/Debug-iphonesimulator/CoincideRemote*' -print0 \
    | xargs -0 xcrun xcstringstool sync CoincideRemote/Localizable.xcstrings --stringsdata
fi
