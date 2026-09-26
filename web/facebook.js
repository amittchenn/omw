// Facebook: sign in with Facebook, and find your Facebook friends who are already on omw (Meta Graph API).
//
// The Graph API's /me/friends only returns friends who ALSO signed in to omw with Facebook, so every match is someone
// you can add in one tap. We store each person's Facebook ID on their friend-ID doc (codes/{ID}.fbId) to match them.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, FacebookAuthProvider, signInWithPopup, linkWithPopup, reauthenticateWithPopup, updateProfile,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getFirestore, doc, getDoc, setDoc, collection, query, where, getDocs,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const GRAPH = "https://graph.facebook.com/v21.0";
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const MESSAGES = {
  "auth/account-exists-with-different-credential":
    "You already have an omw account with this email. Sign in with Google or email, then tap “Connect Facebook” in your profile.",
  "auth/credential-already-in-use": "That Facebook account is already connected to a different omw account.",
  "auth/popup-closed-by-user": "Facebook sign-in was closed before it finished.",
  "auth/cancelled-popup-request": "Facebook sign-in was closed before it finished.",
  "auth/operation-not-allowed": "Facebook sign-in is turned off in Firebase: enable it under Authentication → Sign-in method.",
  "auth/unauthorized-domain": "This website isn't allowed in Firebase yet: add it under Authentication → Settings → Authorized domains.",
};
const message = e => MESSAGES[e.code] || e.message;

const provider = () => {
  const p = new FacebookAuthProvider();
  p.addScope("user_friends");  // lets us see which of your Facebook friends also use omw
  return p;
};

// Facebook's access token only comes back at sign-in, so keep it for this browser tab
let token = null;
try { token = sessionStorage.getItem("fbToken"); } catch { /* private mode: we'll just ask again */ }
function keepToken(result) {
  token = FacebookAuthProvider.credentialFromResult(result)?.accessToken || token;
  try { sessionStorage.setItem("fbToken", token || ""); } catch { /* fine */ }
}

async function graph(path) {
  const res = await fetch(`${GRAPH}${path}${path.includes("?") ? "&" : "?"}access_token=${encodeURIComponent(token)}`);
  const data = await res.json();
  if (data.error) throw Object.assign(new Error(data.error.message), { expired: data.error.code === 190 });
  return data;
}

// ---------- the "Friends from Facebook" section in your profile ----------
let auth, db, found = [], state = "idle";  // idle | loading | ready | error
const requested = new Set();  // friend IDs you tapped "Add" on
const linked = () => auth.currentUser?.providerData.some(p => p.providerId === "facebook.com");
const myFriendIds = () => new Set((window.myFriends || []).map(p => p.user_id));

function render(note = "") {
  const box = $("fbBox");
  if (!box) return;
  if (!auth.currentUser) return box.innerHTML = "";
  if (!linked()) {
    box.innerHTML = `<button class="wide fb" id="fbConnect">${FB_ICON} Connect Facebook</button>
      <div class="note">${note || "Find friends who are already on omw, and use your Facebook photo."}</div>`;
    return $("fbConnect").onclick = () => act(async () => keepToken(await linkWithPopup(auth.currentUser, provider())));
  }
  if (!token) {
    box.innerHTML = `<button class="wide fb" id="fbFind">${FB_ICON} Find my Facebook friends</button><div class="note">${note}</div>`;
    return $("fbFind").onclick = () => act(async () => keepToken(await reauthenticateWithPopup(auth.currentUser, provider())));
  }
  if (state === "loading") return box.innerHTML = `<div class="nobody">Checking Facebook…</div>`;
  const mine = myFriendIds();
  box.innerHTML = (found.length
    ? found.map(f => `<div class="person"><div class="avatar" style="background-image:url('${esc(f.photo)}')"></div>
        <div class="who"><b>${esc(f.name)}</b><small>Facebook friend on omw</small></div>
        ${mine.has(f.uid) ? `<span class="mini-note">${icon("check")} Friends</span>`
          : requested.has(f.code) ? `<span class="mini-note">Requested</span>`
          : f.code ? `<button class="mini yes" data-fb-add="${esc(f.code)}">Add</button>`
          : `<span class="mini-note">Still setting up</span>`}</div>`).join("")
    : `<div class="nobody">None of your Facebook friends are on omw yet. When they sign in with Facebook, they'll show up here.</div>`) +
    (note ? `<div class="note">${note}</div>` : "");
  box.querySelectorAll("[data-fb-add]").forEach(b => b.onclick = () => {
    $("addInput").value = b.dataset.fbAdd;  // same request/accept flow as typing their friend ID
    $("addBtn").click();
    requested.add(b.dataset.fbAdd);
    render();
  });
}

async function act(connect) {
  try { await connect(); await sync(); }
  catch (e) { render(message(e)); }
}

async function sync() {
  if (!auth.currentUser || !linked() || !token) return render();
  state = "loading"; render();
  try {
    const user = auth.currentUser;
    // who am I on Facebook? (their ID for this app, plus a proper profile photo)
    const me = await graph("/me?fields=id,name,picture.width(200).height(200)");
    const photo = me.picture?.data?.url;
    if (photo && !me.picture.data.is_silhouette && (!user.photoURL || /facebook|fbcdn|fbsbx/.test(user.photoURL))) {
      await updateProfile(user, { photoURL: photo });
      // your omw avatar stays unless you picked "Use my photo" in your profile
      const avatar = (await getDoc(doc(db, "users", user.uid))).data()?.avatar;
      if (!avatar?.style || avatar.usePhoto) {
        await setDoc(doc(db, "users", user.uid), { photo }, { merge: true });
      }
    }
    // put my Facebook ID on my friend ID, so my Facebook friends can find me
    const code = (await getDoc(doc(db, "users", user.uid))).data()?.code;
    if (code) await setDoc(doc(db, "codes", code), { fbId: me.id }, { merge: true });

    // which of my Facebook friends use omw? then look up their omw friend IDs
    const { data = [] } = await graph("/me/friends?fields=id,name,picture.width(100).height(100)&limit=500");
    const byFb = {};
    for (let i = 0; i < data.length; i += 30) {  // Firestore "in" queries take up to 30 values
      const snap = await getDocs(query(collection(db, "codes"), where("fbId", "in", data.slice(i, i + 30).map(f => f.id))));
      snap.docs.forEach(d => (byFb[d.data().fbId] = { code: d.id, uid: d.data().uid }));
    }
    found = data.map(f => ({ name: f.name, photo: f.picture?.data?.url || "", ...byFb[f.id] }));
    state = "ready"; render();
  } catch (e) {
    state = "error";
    if (e.expired) { token = null; try { sessionStorage.removeItem("fbToken"); } catch { /* fine */ } }
    render(e.expired ? "Facebook needs you to sign in again." : `Couldn't reach Facebook: ${esc(e.message)}`);
  }
}

const FB_ICON = `<svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M24 12.07C24 5.41 18.63 0 12 0S0 5.4 0 12.07C0 18.1 4.39 23.1 10.13 24v-8.44H7.08v-3.49h3.04V9.41c0-3.02 1.8-4.7 4.54-4.7 1.31 0 2.68.24 2.68.24v2.97h-1.5c-1.5 0-1.96.93-1.96 1.89v2.26h3.32l-.53 3.5h-2.8V24C19.62 23.1 24 18.1 24 12.07"/></svg>`;

// ---------- wiring ----------
if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  auth = getAuth(app);
  db = getFirestore(app);

  // "Continue with Facebook" on the sign-in screen
  $("fbBtn").onclick = async () => {
    $("authError").textContent = "";
    try { keepToken(await signInWithPopup(auth, provider())); }
    catch (e) { $("authError").textContent = message(e); }
  };

  onAuthStateChanged(auth, user => {
    found = []; state = "idle";
    if (!user) { token = null; try { sessionStorage.removeItem("fbToken"); } catch { /* fine */ } }
    // give friends.js a moment to create your profile and friend ID first
    setTimeout(sync, 1500);
  });
  window.addEventListener("friends-changed", () => state === "ready" && render());
}
