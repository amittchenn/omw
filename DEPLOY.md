# Deploying omw! (Railway + Cloudflare)

The server runs on **Railway** from this repo's `Dockerfile`. It doesn't sleep, so there's no 30-second cold start like on
Render's free plan. Your domain lives on **Cloudflare**. Sign-in, data, chat and photos stay on **Firebase**.
Staying on Render instead? Everything below works there too: add the same variables under Environment, and pick a paid
instance so it doesn't sleep (notifications and the Dynamic Island need the server awake).

## 0. Firebase: database rules and one index (5 minutes, do this first)
1. Firebase console -> **Firestore Database -> Rules** -> replace everything with the contents of `firestore.rules` -> **Publish**.
   These decide who can read and change what: everyone only reaches their own data, their friends' profiles, and the plans,
   chats and photos they're in, and on shared things they can only change their own part. (Tests: `tests/rules.test.mjs`.)
2. **Firestore Database -> Indexes -> Composite -> Create index**: collection `feed`, fields `viewers` *Arrays* and
   `at` *Descending*. (Or open the app once: the browser console prints a link that creates it.) Until it's built the feed
   still shows, just not newest-first.
3. **Authentication -> Settings -> User actions**: turn on **Email enumeration protection**. Firebase already hashes
   passwords and slows down repeated wrong logins.
4. Recommended once the app is live: **App Check** (Build -> App Check) with App Attest for iOS and reCAPTCHA for the
   website, so only the real app can use your Firebase project.

## 1. Railway (about 10 minutes)
1. [railway.com](https://railway.com) → sign in with GitHub → **New Project → Deploy from GitHub repo** → `amittchenn/omw`.
   Railway finds `railway.json` and builds the `Dockerfile`. The **Hobby** plan (about $5/month) keeps it always on.
2. Open the service → **Variables** → **Raw Editor**, and paste the same variables you have on Render, plus `PUSH_ENABLED=1`:
   ```
   GOOGLE_MAPS_API_KEY=...
   GOOGLE_MAPS_BROWSER_KEY=...
   MAPBOX_TOKEN=...
   OPENAI_API_KEY=...
   MUSE_BASE_URL=...
   MUSE_API_KEY=...
   MUSE_MODEL=...
   FIREBASE_SERVICE_ACCOUNT_JSON={...the whole JSON on one line...}
   PUSH_ENABLED=1
   SUPPORT_EMAIL=you@example.com
   ```
   Don't set `PORT`: Railway sets it.
3. **Settings → Networking → Generate Domain**. You get something like `omw-production.up.railway.app`.
   Open it and check that `/health` says `{"ok": true}`.

Every push to `main` redeploys automatically.

## 2. Your domain on Cloudflare
1. Buy the domain in Cloudflare (Domain Registration → Register Domains), e.g. `omw.app` or `getomw.com`.
2. Railway → service → **Settings → Networking → Custom Domain** → type it (e.g. `getomw.com` or `app.getomw.com`).
   Railway shows a **CNAME** target.
3. Cloudflare → your domain → **DNS → Add record**:
   - Type **CNAME**, Name `@` (or `app`), Target = what Railway showed;
   - **Proxy status: DNS only** (grey cloud), so Railway can issue the HTTPS certificate.
   Wait until Railway shows the domain as active (usually a few minutes).

## 3. Point everything at the new address
- **Firebase** → Authentication → Settings → **Authorized domains** → add your domain.
- **Google Cloud console** → APIs & Services → Credentials:
  - open the **OAuth 2.0 web client** Firebase uses, and add `https://YOUR-DOMAIN/__/auth/handler` to **Authorized redirect URIs**.
    This is what keeps Google sign-in working in Safari.
  - open your **browser Maps key** (`GOOGLE_MAPS_BROWSER_KEY`), and add `https://YOUR-DOMAIN/*` to its website restrictions.
- **iPhone app:** in `mobile/capacitor.config.json` set `"server": { "url": "https://YOUR-DOMAIN" }`, then run `npx cap sync ios`.

## 4. Turn off Render
Once the new domain works, **suspend the Render service**. Two live servers would send every notification twice.

## Running the same container yourself
```bash
docker build -t omw . && docker run -p 8000:8000 --env-file .env omw
```
