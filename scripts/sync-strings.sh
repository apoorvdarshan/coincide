#!/bin/sh
# Builds the app and updates Coincide/Resources/Localizable.xcstrings with every localizable
# string used in the app and in CoincideKit (Kit strings resolve through the app bundle).
set -eu
cd "$(dirname "$0")/.."
DERIVED_DATA="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/coincide-mac-debug}"
xcodegen generate --quiet
xcodebuild -project Coincide.xcodeproj -scheme Coincide -configuration Debug -derivedDataPath "$DERIVED_DATA" build -quiet
find "$DERIVED_DATA/Build/Intermediates.noindex" -name '*.stringsdata' -path '*Debug*' -print0 \
  | xargs -0 xcrun xcstringstool sync Coincide/Resources/Localizable.xcstrings --stringsdata
