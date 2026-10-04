#!/usr/bin/env bash
# Run once on the Mac: ./setup.sh   (needs Node 18+, CocoaPods, Xcode 15.x)
set -euo pipefail
cd "$(dirname "$0")"
command -v node >/dev/null || { echo "Install Node first: brew install node"; exit 1; }
command -v pod  >/dev/null || { echo "Install CocoaPods first: brew install cocoapods"; exit 1; }

npm install
[ -d ios ] || npx cap add ios
cp ios-src/*.swift ios/App/App/

PL=ios/App/App/Info.plist
PB=/usr/libexec/PlistBuddy
$PB -c "Add :NSLocalNetworkUsageDescription string 'Used to control your Yandex Station on the local network.'" "$PL" 2>/dev/null || true
$PB -c "Add :NSAppTransportSecurity dict" "$PL" 2>/dev/null || true
$PB -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PL" 2>/dev/null || true

# Use our view controller (registers the socket plugin)
sed -i '' 's/customClass="CAPBridgeViewController" customModule="Capacitor"/customClass="ViewController" customModule="App"/' \
  ios/App/App/Base.lproj/Main.storyboard

# Add the Swift files to the Xcode target (uses the xcodeproj gem that ships with CocoaPods)
ADD_FILES='
require "xcodeproj"
p = Xcodeproj::Project.open("ios/App/App.xcodeproj"); t = p.targets.first
g = p.main_group.find_subpath("App", true)
%w[StationSocketPlugin.swift ViewController.swift].each { |f|
  next if g.files.any? { |x| x.path == f }
  t.add_file_references([g.new_file(f)]) }
p.save'
ruby -e "$ADD_FILES" 2>/dev/null \
  || GEM_PATH="$(brew --prefix cocoapods 2>/dev/null)/libexec" ruby -e "$ADD_FILES" 2>/dev/null \
  || echo "!! Could not add the Swift files automatically: in Xcode, drag StationSocketPlugin.swift and ViewController.swift from ios/App/App into the App group (tick the App target)."

npx cap sync ios
echo "Done. Open with: npx cap open ios   |  unsigned IPA: ./build-ipa.sh"
