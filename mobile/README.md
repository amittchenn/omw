# omw! for iPhone

A native iOS app made with [Capacitor](https://capacitorjs.com). It loads the live site (`server.url` in
`capacitor.config.json`), so **every deploy updates the app too**. You only rebuild in Xcode when something native changes.

What's native:
- **Google and Apple sign-in.** Popups don't work in iPhone apps, and Apple requires "Sign in with Apple" when you offer Google.
- **Push notifications:**
  - "Time to leave" at your alert;
  - invites, and "Priya is in";
  - new messages in plan chats and DMs.

  Tapping one opens that plan or chat. The server sends them (`push.py`).
- **Permission messages** for location, camera and photos, plus the **icon** and **splash screen**.

## What you need
- A Mac with **Xcode 16.3+** and **Node 22+** (`brew install node`).
- An **Apple Developer account** ($99/year) for Sign in with Apple, push notifications and TestFlight.
  With a free Apple ID you can still run the app on your own phone: skip those two capabilities and sign in with Google or email.

## One-time setup

### Firebase
1. Project settings → Your apps → **Add app → iOS**. Bundle ID `com.amittchenn.omw` (or your own, and the same in
   `capacitor.config.json` → `appId`). Download **GoogleService-Info.plist** into this `mobile/` folder.
2. Authentication → Sign-in method → **Apple** → Enable.
3. **Push key:**
   - [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) → Keys → **+** → tick
     **Apple Push Notifications service (APNs)** → download the `.p8` file, and note the **Key ID** and your **Team ID**.
   - Firebase → Project settings → **Cloud Messaging** → Apple app configuration → **APNs Authentication Key → Upload**.
4. **Firestore rules:** phones save their notification token on `private/{uid}`. Your rules must let people write their
   own private doc. They already do if this line is there:
   ```
   match /private/{uid} { allow read, write: if request.auth != null && request.auth.uid == uid; ... }
   ```

### Build
```bash
npm install
npx cap add ios
./setup-ios.sh
npx cap open ios
```
In Xcode:
1. If **GoogleService-Info.plist** isn't in the left sidebar under App → App, drag it in from `ios/App/App/` and tick the **App** target.
2. **App** target → **Signing & Capabilities**:
   - pick your **Team**;
   - **+ Capability** → **Sign in with Apple**;
   - **+ Capability** → **Push Notifications**.
3. Plug in your iPhone, pick it at the top, press **▶ Run**. The first time, trust the developer on the phone
   (Settings → General → VPN & Device Management).

Notifications only work on a real iPhone, not the simulator, and only with `PUSH_ENABLED=1` on the live server (see `../DEPLOY.md`).

## Day to day
- **Web changes:** push as usual. The app picks them up on its next launch.
- **Native changes** (config, icon, plugins): run `npx cap sync ios`, then Run again.

## TestFlight (friends install it)
1. Xcode → Product → **Archive** → Distribute App → **TestFlight & App Store**.
2. [App Store Connect](https://appstoreconnect.apple.com) → your app → **TestFlight** → add testers by email.

## Still needed before the public App Store
- **Delete account** inside the app (Apple requires it).
- **Report / block** for chats and photos (user-generated content rule).
- A **privacy policy** page.
