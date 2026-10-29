// Push notifications in the iPhone app (Capacitor + @capacitor-firebase/messaging).
// The server sends them (push.py): your leave-now alert, invites, and new chat messages. This file asks for permission
// once, keeps this phone's token on your private profile (private/{uid}.pushTokens, only you can read it), and opens the
// right screen when you tap one. On the website it does nothing.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, setDoc, arrayUnion, arrayRemove } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const native = !!window.Capacitor?.isNativePlatform?.();
const FM = () => window.Capacitor.Plugins?.FirebaseMessaging || window.Capacitor.registerPlugin("FirebaseMessaging");

// tapping a notification: go to what it's about
function openFrom(data = {}) {
  const go = () => {
    if (data.chat) return window.openDmChat?.(data.chat);
    if (data.hangout && data.kind === "chat") return window.openChat?.(data.hangout);
    if (data.hangout) return window.openPlanCard?.(data.hangout);
  };
  // the app may still be starting up: wait until the plans have loaded
  if (window.myHangouts) go(); else addEventListener("hangouts-changed", go, { once: true });
}

if (native && firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  const db = getFirestore(app);
  let uid = null, token = null;
  const save = t => uid && t && setDoc(doc(db, "private", uid), { pushTokens: arrayUnion(t) }, { merge: true }).catch(() => {});

  FM().addListener("notificationActionPerformed", e => openFrom(e.notification?.data || {}));
  FM().addListener("tokenReceived", e => { token = e.token; save(token); });

  onAuthStateChanged(getAuth(app), async user => {
    uid = user?.uid || null;
    if (!uid) return;
    try {
      let { receive } = await FM().checkPermissions();
      if (receive === "prompt" || receive === "prompt-with-rationale") ({ receive } = await FM().requestPermissions());
      if (receive !== "granted") return;
      ({ token } = await FM().getToken());
      await save(token);
    } catch (e) { console.warn("push:", e.message); }
  });

  // signing out: this phone stops getting your notifications (auth.js calls this before it signs out)
  window.omwPushSignOut = async () => {
    if (!uid) return;
    try {
      if (token) await setDoc(doc(db, "private", uid), { pushTokens: arrayRemove(token) }, { merge: true });
      await FM().deleteToken();
    } catch { /* offline: the server drops tokens that stop working */ }
    token = null;
  };
}
