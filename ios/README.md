# omw! in SwiftUI

The native iPhone app. It uses the **same Firebase project, data and security rules** as the web app (`web/`) and the
current Capacitor app (`mobile/`), so the same accounts, friends, posts and plans show up in both while this one grows.

## What's in it so far

| Screen | Status |
|---|---|
| Sign in (Google, Apple, email; forgot password) | Done |
| Feed: friends row with statuses, posts with photo swipe, likes, double-tap to like, report/hide/delete | Done |
| Comments sheet (hold a comment to delete or report) | Done |
| New post: Apple's photo picker (up to 4), caption, location search, tag friends | Done |
| Add friends: search usernames, requests, Quick Add (friends of friends), invite | Done |
| Profiles: yours and anyone's, Add / Requested / Accept, Friends ▾ → Remove, posts grid | Done |
| Map (Apple Maps): friends sharing their location, you, 3D buildings | Done |
| "I'm free": tap your picture for 1 hour / 2 hours / tonight; "till 9" bubbles over free friends | Done |
| Share my location: Never / While using the app / Always (auto check-in at the spot even with omw! closed) | Done |
| Plans: coming up and past | Done |
| Settings: location sharing, sign out, delete account (with Apple's confirm), privacy/terms/help | Done |
| + planner: what, who, where, when, everyone's leave time, send invites | Done |
| Plan details: Going / Can't make it, leave-by time, directions, I'm here, who's arrived | Done |
| Chats: DMs, group chats (name, add people, leave), every plan's group chat, unread badges, search | Done |
| Edit profile: picture, name, friend ID (checks it's free), how you get around | Done |
| New accounts: a friend ID, a public card and your Google/Apple picture, like the web app | Done |
| Ranking places, notifications, Live Activity | Next (still in the current app) |

`Sources/`:
- `OmwApp.swift`: app start; signed out → sign in, signed in → tabs
- `Session.swift`: who's signed in and the live data
- `Models.swift`: the Firestore documents
- `Components.swift`: colors, pictures, avatars
- `Session+Actions.swift`: adding friends and posting
- `Account.swift`: setting up your account (friend ID, public card) and Edit profile
- `Chats.swift`: the inbox, DMs, group chats and plan chats (same documents as web/dms.js and web/chat.js)
- `API.swift`: the omw! server (place search, deleting accounts; the planner next)
- `LocationService.swift`: sharing your location the way you chose, and checking you in when you arrive
- the screens: `SignInView`, `MainTabView`, `FeedView`, `CommentsSheet`, `NewPostView`, `AddFriendsView`, `ProfileView`,
  `FriendsMapView`, `PlansView`

## Set it up in Xcode (once)

1. **Create the project.** Xcode → File → New → Project → iOS → **App** → Next.
   - Product Name: `omw`
   - Organization Identifier: `com.amittchenn` (so the bundle ID is `com.amittchenn.omw`, the one Firebase knows)
   - Interface: **SwiftUI**, Language: **Swift**, Storage: None, no tests
   - Save it in `~/omw-git/ios` (you'll get `~/omw-git/ios/omw/omw.xcodeproj`)
2. **Swap in our code.** In the left sidebar, delete `ContentView.swift` and `omwApp.swift` (Move to Trash). Then drag the
   `~/omw-git/ios/Sources` folder from Finder onto the yellow `omw` folder in the sidebar. In the box: **uncheck** "Copy items
   if needed", pick "Create groups" (or "folders"), make sure the `omw` target is checked → Finish.
3. **Add Firebase.** File → Add Package Dependencies… → paste `https://github.com/firebase/firebase-ios-sdk` → Add Package.
   When it asks which products: check **FirebaseAuth** and **FirebaseFirestore** (target `omw`) → Add Package.
3b. **Google sign-in.** File → Add Package Dependencies… → paste `https://github.com/google/GoogleSignIn-iOS` → Add Package →
   check **GoogleSignIn** (target `omw`). Then target `omw` → Info → **URL Types** → **+** → URL Schemes:
   `com.googleusercontent.apps.1073392073956-svchks68h49563ot14rv0dqtsi0dg3nq` (the `REVERSED_CLIENT_ID` in
   GoogleService-Info.plist), so Google can hand you back to omw! after you sign in.
4. **Firebase's file.** Drag `GoogleService-Info.plist` into the `omw` folder in the sidebar (check "Copy items if needed").
   It's the same one the current app uses: `~/omw-git/mobile/ios/App/App/GoogleService-Info.plist`.
5. **Settings** (click the blue `omw` project at the top of the sidebar → target `omw`):
   - General → Minimum Deployments: **iOS 17.0**
   - Signing & Capabilities → Team: your Apple developer team → **+ Capability** → **Sign in with Apple**
   - Info → hover any row → **+** → `Privacy - Location When In Use Usage Description` →
     `omw! shows you on the map with your friends.`
   - Same way, add `Privacy - Location Always and When In Use Usage Description` →
     `With "Always", omw! checks you in when you arrive at a hangout, even when it's closed.`
   - Same way, add `Privacy - Photo Library Usage Description` → `Pick photos to post.`
     (Apple's photo picker doesn't strictly need it, but App Review likes it there)
6. Pick an iPhone simulator at the top and press **▶**.

Both apps use the bundle ID `com.amittchenn.omw`, so installing this one replaces the Capacitor app on that device or
simulator. That's fine: the data lives in Firebase, not on the phone.

If Xcode shows an error, copy the red message (and the file and line) and send it over.
