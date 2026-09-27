// Sign in with Google or email/password (Firebase Authentication).
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, GoogleAuthProvider, signInWithPopup, signInWithEmailAndPassword,
  createUserWithEmailAndPassword, updateProfile, sendPasswordResetEmail, signOut,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";

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
  const auth = getAuth(initializeApp(firebaseConfig));

  const greeting = name => {
    const h = new Date().getHours();
    return `${h < 5 ? "Hey night owl" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"}, ${name.split(" ")[0]}`;
  };
  onAuthStateChanged(auth, user => {
    document.body.classList.remove("checking");
    document.body.classList.toggle("signed-in", !!user);
    if (!user) { setMode("signin"); $("password").value = ""; return; }
    const name = user.displayName || user.email.split("@")[0];
    $("userName").textContent = greeting(name);
    if (!$("userPic").style.backgroundImage) $("userPic").textContent = name.slice(0, 1).toUpperCase();  // until your avatar loads
    window.currentUser = user;  // the rest of the page can read who's signed in
  });

  $("googleBtn").onclick = () => run(() => signInWithPopup(auth, new GoogleAuthProvider()));

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

  $("signOut").onclick = () => signOut(auth);
}
