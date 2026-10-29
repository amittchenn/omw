#!/bin/bash
# Run once after `npx cap add ios`, from the mobile/ folder, with GoogleService-Info.plist next to this script.
# Adds: permission messages, the Google sign-in URL scheme, push-notification hooks, the icon and splash screen.
set -e
PLIST=ios/App/App/Info.plist
DELEGATE=ios/App/App/AppDelegate.swift
PB=/usr/libexec/PlistBuddy
[ -f "$PLIST" ] || { echo "Run 'npx cap add ios' first."; exit 1; }
[ -f GoogleService-Info.plist ] || { echo "Download GoogleService-Info.plist from Firebase (see README) and put it in this folder."; exit 1; }

set_str() { $PB -c "Set :$1 $2" "$PLIST" 2>/dev/null || $PB -c "Add :$1 string $2" "$PLIST"; }
set_str NSLocationWhenInUseUsageDescription "omw! uses your location to work out when you need to leave, and to show friends you're on your way around hangout time."
set_str NSCameraUsageDescription "omw! uses the camera for your profile picture and group photos in Memories."
set_str NSPhotoLibraryUsageDescription "omw! lets you pick a profile picture or group photo from your library."
set_str NSPhotoLibraryAddUsageDescription "omw! can save group photos from Memories to your library."
set_str CFBundleDisplayName "omw!"

# notifications can arrive while the app is in the background
if ! $PB -c "Print :UIBackgroundModes" "$PLIST" 2>/dev/null | grep -q remote-notification; then
  $PB -c "Add :UIBackgroundModes array" "$PLIST" 2>/dev/null || true
  $PB -c "Add :UIBackgroundModes:0 string remote-notification" "$PLIST"
fi

# Google sign-in comes back to the app through this URL scheme (REVERSED_CLIENT_ID from GoogleService-Info.plist)
REV=$($PB -c "Print :REVERSED_CLIENT_ID" GoogleService-Info.plist)
if ! $PB -c "Print :CFBundleURLTypes" "$PLIST" 2>/dev/null | grep -q "$REV"; then
  $PB -c "Add :CFBundleURLTypes array" "$PLIST" 2>/dev/null || true
  N=$($PB -c "Print :CFBundleURLTypes" "$PLIST" | grep -c "Dict {" || true)
  $PB -c "Add :CFBundleURLTypes:$N dict" "$PLIST"
  $PB -c "Add :CFBundleURLTypes:$N:CFBundleURLSchemes array" "$PLIST"
  $PB -c "Add :CFBundleURLTypes:$N:CFBundleURLSchemes:0 string $REV" "$PLIST"
fi

# push notifications: hand the phone's notification token and incoming messages to the Firebase Messaging plugin
if ! grep -q capacitorDidRegisterForRemoteNotifications "$DELEGATE"; then
  perl -0pi -e 's/\}\s*\z/
    \/\/ push notifications (\@capacitor-firebase\/messaging)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: \@escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Notification.Name.init("didReceiveRemoteNotification"), object: completionHandler, userInfo: userInfo)
    }
}
/' "$DELEGATE"
fi

cp GoogleService-Info.plist ios/App/App/GoogleService-Info.plist
npx --yes @capacitor/assets@3 generate --ios  # icon + splash (run on demand: an old tool, kept out of the project)
node build-web.mjs && npx cap sync ios  # the app's screens from ../web, then the Xcode project
echo
echo "Done. Now in Xcode (npx cap open ios):"
echo "  1. Drag ios/App/App/GoogleService-Info.plist into the App folder in the left sidebar (tick the 'App' target) if it isn't listed."
echo "  2. App target > Signing & Capabilities: pick your Team, then + Capability: 'Sign in with Apple' and 'Push Notifications'."
echo "  3. Pick your iPhone at the top and press Run."
