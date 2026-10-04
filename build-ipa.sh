#!/usr/bin/env bash
# Builds an unsigned Station.ipa (re-sign it with your sideloading tool). Needs Xcode 26 for Liquid Glass.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
xcodebuild -project Station.xcodeproj -scheme Station -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
rm -rf Payload Station.ipa && mkdir Payload
cp -R build/Build/Products/Release-iphoneos/Station.app Payload/
zip -qr Station.ipa Payload && rm -rf Payload
echo "Built Station.ipa"
