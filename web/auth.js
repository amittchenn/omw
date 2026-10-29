// Sign in with Google or email/password (Firebase Authentication).
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, GoogleAuthProvider, signInWithPopup, signInWithEmailAndPassword,
  createUserWithEmailAndPassword, updateProfile, sendPasswordResetEmail, signOut,
  initializeAuth, indexedDBLocalPersistence, signInWithCredential, OAuthProvider, revokeAccessToken,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";

// In the iPhone app (Capacitor) there are no popups: Google and Apple sign in natively (the
// @capacitor-firebase/authentication plugin), then hand Firebase the result here. On the website nothing changes.
const native = !!window.Capacitor?.isNativePlatform?.();
const nativeAuth = () => window.Capacitor.Plugins?.FirebaseAuthentication || window.Capacitor.registerPlugin("FirebaseAuthentication");

// Safari (iPhone and Mac) blocks sign-in that happens on another site, and Firebase's sign-in page lives on
// yourproject.firebaseapp.com. So on the live site the sign-in page comes from omw!'s own address instead
// (server.py passes /__/auth/... through to Firebase). On localhost Firebase's own address works fine.
// This runs before any other file starts Firebase, so every file uses it.
if (!["localhost", "127.0.0.1"].includes(location.hostname)) firebaseConfig.authDomain = location.host;

const $ = id => document.getElementById(id);
const MESSAGES = {
  "auth/invalid-credential": "Wrong email or password.",
  "auth/invalid-email": "That email doesn't look right.",
  "auth/missing-password": "Enter your password.",
  "auth/email-already-in-use": "There's already an account with this email. Try signing in.",
  "auth/weak-password": "Password needs at least 6 characters.",
  "auth/popup-closed-by-user": "Google sign-in was closed before it finished.",
  "auth/credential-already-in-use": "That account is already linked to someone else.",
  "auth/too-many-requests": "Too many tries. Wait a minute and try again.",
  "auth/unauthorized-domain": "This website isn't allowed in Firebase yet: add it under Authentication → Settings → Authorized domains.",
  "auth/operation-not-allowed": "This sign-in method is turned off in Firebase: enable it under Authentication → Sign-in method.",
};
const say = (text, ok = false) => { $("authError").textContent = text; $("authError").classList.toggle("ok", ok); };

// ---- sign in vs create account tabs ----
let mode = "signin";
function setMode(m) {
  mode = m;
  document.querySelectorAll(".tab").forEach(t => t.classList.toggle("on", t.dataset.mode === m));
  $("nameField").style.display = m === "signup" ? "block" : "none";
  $("authSubmit").textContent = m === "signup" ? "Create account" : "Sign in";
  $("password").autocomplete = m === "signup" ? "new-password" : "current-password";
  say("");
}
document.querySelectorAll(".tab").forEach(t => t.onclick = () => setMode(t.dataset.mode));

async function run(action) {
  say("");
  document.querySelectorAll(".gate button").forEach(b => b.disabled = true);
  try { await action(); }
  catch (e) { say(MESSAGES[e.code] || friendly(e, "sign you in")); }
  finally { document.querySelectorAll(".gate button").forEach(b => b.disabled = false); }
}

if (!firebaseConfig.apiKey || firebaseConfig.apiKey.startsWith("PASTE")) {
  document.body.classList.remove("checking");
  say("Login isn't set up yet: paste your Firebase config into web/firebase-config.js.");
} else {
  // the app keeps you signed in with on-device storage (and skips the web sign-in helpers, which need popups)
  const app = initializeApp(firebaseConfig);
  const auth = native ? initializeAuth(app, { persistence: indexedDBLocalPersistence }) : getAuth(app);

  const greeting = name => {
    const h = new Date().getHours();
    return `${h < 5 ? "Hey night owl" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"}, ${name.split(" ")[0]}`;
  };
  onAuthStateChanged(auth, user => {
    document.body.classList.remove("checking");
    document.body.classList.toggle("signed-in", !!user);
    window.currentUser = user;  // the rest of the page can read who's signed in (and requests to the server carry it)
    if (!user) { setMode("signin"); $("password").value = ""; return; }
    const name = user.displayName || user.email.split("@")[0];
    $("userName").textContent = greeting(name);
    if (!$("userPic").style.backgroundImage) $("userPic").textContent = name.slice(0, 1).toUpperCase();  // until your avatar loads
  });

  const cancelled = e => /cancel|closed|1001|12501/i.test(`${e?.code} ${e?.message}`);  // you backed out: say nothing
  $("googleBtn").onclick = () => run(async () => {
    if (!native) return signInWithPopup(auth, new GoogleAuthProvider());
    try {
      const r = await nativeAuth().signInWithGoogle({ skipNativeAuth: true });
      await signInWithCredential(auth, GoogleAuthProvider.credential(r.credential?.idToken, r.credential?.accessToken));
    } catch (e) { if (!cancelled(e)) throw e; }
  });
  $("appleBtn").onclick = () => run(async () => {
    try {
      const r = await nativeAuth().signInWithApple({ skipNativeAuth: true });
      await signInWithCredential(auth, new OAuthProvider("apple.com").credential({ idToken: r.credential?.idToken, rawNonce: r.credential?.nonce }));
    } catch (e) { if (!cancelled(e)) throw e; }
  });

  $("authForm").onsubmit = e => {
    e.preventDefault();
    const email = $("email").value.trim(), password = $("password").value;
    run(async () => {
      if (mode === "signin") return signInWithEmailAndPassword(auth, email, password);
      const name = $("displayName").value.trim();
      if (!name) throw { message: "Tell your friends who you are: add your name." };
      const { user } = await createUserWithEmailAndPassword(auth, email, password);
      await updateProfile(user, { displayName: name });
      $("userName").textContent = greeting(name);
      $("userPic").textContent = name.slice(0, 1).toUpperCase();
    });
  };

  $("forgot").onclick = () => {
    const email = $("email").value.trim();
    if (!email) return say("Type your email above first, then click “Forgot password?”.");
    run(async () => { await sendPasswordResetEmail(auth, email); say("Check your inbox for a reset link.", true); });
  };

  // Profile -> Delete account: the server deletes your data and sign-in (account.py), then you're signed out here
  $("deleteAccount").onclick = async () => {
    if (!confirm("Delete your omw! account?\n\nYour profile, friends, plans you made, photos and messages are deleted for good. This can't be undone.")) return;
    const b = $("deleteAccount"), user = auth.currentUser;
    b.disabled = true; b.textContent = "Deleting…";
    try {
      // signed up with Apple: Apple asks apps to cancel that sign-in too, which needs one more confirmation from Apple
      if (native && user.providerData.some(p => p.providerId === "apple.com")) {
        const r = await nativeAuth().signInWithApple({ skipNativeAuth: true });
        if (r.credential?.authorizationCode) await revokeAccessToken(auth, r.credential.authorizationCode).catch(() => {});
      }
      const token = await user.getIdToken(true);
      await window.omwPushSignOut?.();
      const res = await fetch("/account/delete", { method: "POST", headers: { Authorization: `Bearer ${token}` } });
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).detail || "Couldn't delete your account. Try again.");
      if (native) await nativeAuth().signOut().catch(() => {});
      await signOut(auth);
      alert("Your account and everything in it has been deleted.");
    } catch (e) {
      if (!cancelled(e)) alert(friendly(e, "delete your account"));
    } finally { b.disabled = false; b.textContent = "Delete account"; }
  };

  $("signOut").onclick = async () => {
    await window.omwPushSignOut?.();  // this phone stops getting your notifications
    if (native) await nativeAuth().signOut().catch(() => {});  // so the next Google sign-in asks which account
    return signOut(auth);
  };
}
