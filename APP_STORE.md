# Submitting omw! to the App Store

What Apple checks, and where omw! covers it.

| Apple's rule | In omw! |
|---|---|
| **Sign in with Apple** when you offer Google sign-in (4.8) | "Continue with Apple" on the sign-in screen in the app |
| **Delete your account inside the app** (5.1.1) | Me -> **Delete account**: deletes everything right away (`account.py`); Apple sign-ins are revoked too |
| **Not just a website in a box** (4.2) | The screens ship inside the app; native sign-in, push notifications, Live Activity / Dynamic Island, haptics |
| **People's posts: report, block, rules** (1.2) | Every feed post has ⋯ -> Report / Block / Hide; Terms say zero tolerance; reports land in Firestore `reports` |
| **Privacy policy and support links work** (5.1.1, 1.5) | `https://YOUR-SERVER/privacy`, `/terms`, `/support` (set `SUPPORT_EMAIL` on the server first) |
| **A working demo login** (2.1) | `python demo/seed_demo.py` makes it and prints the email and password |
| **iPad** (2.4.1) | The app runs on iPad: feed in one column, map with the planner beside it |
| **Up-to-date screenshots** (2.3.3) | Take them from the current build (below) |

## Before you submit
1. **Server:** `SUPPORT_EMAIL`, `PUSH_ENABLED=1` and `FIREBASE_SERVICE_ACCOUNT_JSON` set; open `/privacy`, `/terms`,
   `/support` in a browser and check the contact address shows.
2. **Firebase:** rules published and the feed index made (`DEPLOY.md`, step 0).
3. **Demo account:** `python demo/seed_demo.py` the day you submit (it refreshes the plan and statuses). Sign in with it
   on your phone once to check.
4. **Build:** `cd mobile && npm run sync`, then in Xcode: Product -> Archive -> Distribute App -> App Store Connect.

## App Store Connect
- **App Review Information -> Sign-in required:** the demo email and password. In **Notes**:
  > Sign in with "Use email" and the account above. Alex has friends, a plan tomorrow, an invite (Plans), group photos in
  > the feed and a chat. To see the Live Activity: Map -> plan something starting within the hour. Delete account: Me ->
  > Delete account (please don't delete the demo account, or run it on a new sign-up).
- **Privacy Policy URL:** `https://YOUR-SERVER/privacy`. **Support URL:** `https://YOUR-SERVER/support`.
- **App Privacy** ("nutrition label"), all **linked to the user**, none used for tracking:
  Contact info (name, email), User content (photos, messages, other: plans), Location (precise), Identifiers (user ID),
  Usage data: none. Purpose: App functionality.
- **Age rating:** answer "Yes" to user-generated content / messaging; that gives 12+ or 13+.
- **Screenshots:** iPhone 6.9" (1320 x 2868) and iPad 13" (2064 x 2752). Easiest: run the app in the Simulator on
  iPhone 17 Pro Max and iPad Pro 13", sign in with the demo account, and press **Cmd + S** on each screen
  (feed, a photo post, Places, the map with a plan, the leaderboard).
