# omw! in SwiftUI

The native iPhone app. It uses the **same Firebase project, data and security rules** as the web app (`web/`) and the
current Capacitor app (`mobile/`), so the same accounts, friends, posts and plans show up in both while this one grows.

## What's in it so far

| Screen | Status |
|---|---|
| Sign in (Apple, email) | Done |
| Feed: friends row with statuses, posts with photo swipe, likes, double-tap to like, report/hide/delete | Done |
| Comments sheet (hold a comment to delete or report) | Done |
| Profiles (yours and friends'), posts grid, post on its own | Done |
| Map (Apple Maps): friends sharing their location, you, 3D buildings | Done |
| Plans: coming up and past | Done |
| Settings: sign out | Started |
| + planner, new post, add friends, chats, ranking places, Live Activity | Next (still in the current app) |

`Sources/`:
- `OmwApp.swift`: app start; signed out → sign in, signed in → tabs
- `Session.swift`: who's signed in and the live data
- `Models.swift`: the Firestore documents
- `Components.swift`: colors, pictures, avatars
- the screens: `SignInView`, `MainTabView`, `FeedView`, `CommentsSheet`, `ProfileView`, `FriendsMapView`, `PlansView`

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
4. **Firebase's file.** Drag `GoogleService-Info.plist` into the `omw` folder in the sidebar (check "Copy items if needed").
   It's the same one the current app uses: `~/omw-git/mobile/ios/App/App/GoogleService-Info.plist`.
5. **Settings** (click the blue `omw` project at the top of the sidebar → target `omw`):
   - General → Minimum Deployments: **iOS 17.0**
   - Signing & Capabilities → Team: your Apple developer team → **+ Capability** → **Sign in with Apple**
   - Info → hover any row → **+** → `Privacy - Location When In Use Usage Description` →
     `omw! shows you on the map with your friends.`
6. Pick an iPhone simulator at the top and press **▶**.

Both apps use the bundle ID `com.amittchenn.omw`, so installing this one replaces the Capacitor app on that device or
simulator. That's fine: the data lives in Firebase, not on the phone.

If Xcode shows an error, copy the red message (and the file and line) and send it over.
