#!/bin/bash
# Adds omw!'s Live Activity (Dynamic Island + lock screen). Run once from mobile/, AFTER you made the widget target in Xcode:
#   File > New > Target > Widget Extension > Product Name: OmwLive, tick "Include Live Activity" > Finish > "Don't Activate".
# See README.md. Safe to run again.
set -e
APP=ios/App/App
EXT=ios/App/OmwLive
PB=/usr/libexec/PlistBuddy
[ -d "$EXT" ] || { echo "Make the OmwLive widget target in Xcode first (see README.md, Dynamic Island)."; exit 1; }

# the widget: omw!'s Live Activity instead of Xcode's sample widget (reusing its files keeps them in the target)
for f in "$EXT"/*.swift; do echo "// Not used. omw!'s widget is OmwLiveBundle.swift and OmwLiveLiveActivity.swift." > "$f"; done
cp native/OmwLiveBundle.swift native/OmwLiveLiveActivity.swift "$EXT"/
cp native/OmwActivityAttributes.swift "$EXT"/OmwLive.swift

# the app: the plugin web/island.js talks to, at the end of AppDelegate.swift (already in the app target)
if ! grep -q "omw! Live Activity" $APP/AppDelegate.swift; then
  { echo; cat native/AppLiveActivity.swift; echo; sed '1,/^import Foundation$/d' native/OmwActivityAttributes.swift; } >> $APP/AppDelegate.swift
fi
# ...registered by our own view controller
sed -i '' 's/customClass="CAPBridgeViewController" customModule="Capacitor"/customClass="MainViewController" customModule="App" customModuleProvider="target"/' $APP/Base.lproj/Main.storyboard

# allow Live Activities, and omw://hangout/<id> links (tapping the Live Activity opens that plan)
$PB -c "Set :NSSupportsLiveActivities true" $APP/Info.plist 2>/dev/null || $PB -c "Add :NSSupportsLiveActivities bool true" $APP/Info.plist
if ! $PB -c "Print :CFBundleURLTypes" $APP/Info.plist | grep -q "omw$"; then
  N=$($PB -c "Print :CFBundleURLTypes" $APP/Info.plist | grep -c "Dict {" || true)
  $PB -c "Add :CFBundleURLTypes:$N dict" $APP/Info.plist
  $PB -c "Add :CFBundleURLTypes:$N:CFBundleURLSchemes array" $APP/Info.plist
  $PB -c "Add :CFBundleURLTypes:$N:CFBundleURLSchemes:0 string omw" $APP/Info.plist
fi

# the widget runs on iOS 16.2 and newer (Xcode picks the newest iOS for a new target)
sed -i '' -E '/OmwLive/,/};/ s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 16.2;/' ios/App/App.xcodeproj/project.pbxproj

echo
echo "Done. In Xcode, press Run. Then plan a hangout that starts soon: the Live Activity shows up 30 minutes before your leave time."
