# omw! for iPhone and iPad

A native app made with [Capacitor](https://capacitorjs.com). The screens (`../web`) are packed **inside** the app, so it
opens instantly and works offline; plans, places and AI come from the omw! server (`build-web.mjs` sets which one).

What's native:
- **Google and Apple sign-in.** Apple requires "Sign in with Apple" when you offer Google.
- **Push notifications:** "Time to leave" at your alert, invites and "Priya is in", new messages. Tapping one opens that plan or chat.
- **The Dynamic Island and lock screen (Live Activity):** from 30 minutes before you need to leave until everyone's there,
  it counts down to your leave time, then to the start, and shows who has arrived ("2 of 4 there · Sam is here").
- **Light haptics** on taps, the **icon** and **splash screen**, and the permission messages for location, camera and photos.
- **iPad:** the feed in one centered column; the map with the planner beside it.

## What you need
- A Mac with **Xcode 16.3+** and **Node 22+**.
- An **Apple Developer account** ($99/year) for Sign in with Apple, push notifications and TestFlight.
  With a free Apple ID you can still run it on your own phone (the Live Activity works too); sign in with Google or email.

## One-time setup

### Firebase
1. Project settings -> Your apps -> **Add app -> iOS**, bundle ID `com.amittchenn.omw`. Download **GoogleService-Info.plist** into this folder.
2. Authentication -> Sign-in method -> **Apple** -> Enable.
3. **Push key:** developer.apple.com -> Keys -> **+** -> tick **Apple Push Notifications service (APNs)** -> download the `.p8`,
   note the Key ID and Team ID -> Firebase -> Project settings -> **Cloud Messaging** -> APNs Authentication Key -> **Upload**.
4. Publish the database rules (`../DEPLOY.md`, step 0).

### Build
```bash
npm install
npm run build         # packs ../web into www/ (the app's screens)
npx cap add ios       # only the very first time (skip it if the ios/ folder exists)
./setup-ios.sh        # permissions, Google sign-in link, notifications, icon; ends with `cap sync`
npx cap open ios
```
In Xcode, **App** target -> **Signing & Capabilities**: pick your **Team**, then **+ Capability** -> **Sign in with Apple**
and **+ Capability** -> **Push Notifications**. Pick your iPhone at the top and press **Run**.

### Dynamic Island (once)
1. Xcode: **File -> New -> Target -> Widget Extension** -> Product Name **`OmwLive`** (exactly), tick **Include Live Activity**,
   untick the others -> **Finish** -> **Don't Activate**.
2. Terminal, in this folder: `./setup-live-activity.sh`
3. Xcode: select the **OmwLive** target -> Signing & Capabilities -> pick the same **Team**. Press **Run**.

To see it: plan a hangout that starts in the next hour, then lock the phone (or look at the Dynamic Island on iPhone 14 Pro and newer).
With the paid account and `PUSH_ENABLED=1` on the server, it also updates while the app is closed (someone arrives).

## Day to day
- **Changed something in `web/`?** `npm run sync`, then Run in Xcode. (The website updates when you push, as before.)
- Another server address: `OMW_SERVER=https://your-domain npm run sync`.
- New icon or splash: `npm run assets`.

## Shipping it
See `../APP_STORE.md` for the App Store checklist (demo account, screenshots, privacy answers).
