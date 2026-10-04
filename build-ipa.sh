#!/usr/bin/env bash
# Builds an unsigned Station.ipa for LiveContainer / sideloading tools that re-sign it.
set -euo pipefail
cd "$(dirname "$0")"
npx cap sync ios
cd ios/App
xcodebuild -workspace App.xcworkspace -scheme App -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
rm -rf Payload Station.ipa && mkdir Payload
cp -R build/Build/Products/Release-iphoneos/App.app Payload/
zip -qr Station.ipa Payload && rm -rf Payload
echo "Built: $(pwd)/Station.ipa"
