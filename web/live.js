// Live locations for a hangout, like Life360 but only for the people going and only while they're on their way.
// From your leave-now time until you arrive (or it ends), omw shares where you are with the others going.
// Stored at hangouts/{id}/where/{uid} = { lat, lng, at }: only people going can read it (see the Firestore rules).
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, setDoc, collection, onSnapshot } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const NO_ALERT_MIN = 30;  // someone without a leave-now time shares from 30 minutes before the start
const MOVED_M = 30, EVERY_MS = 45000;  // write when you've moved 30 m, or at least every 45 seconds

let db, uid = null, hangouts = [], watch = null, sent = {};  // sent[hangoutId] = { here, at }

const endOf = h => new Date(h.start).getTime() + (h.durationMin || 120) * 6e4;
// when someone's location starts showing: the moment they're supposed to leave
export const shareStart = (h, who = uid) => h.alerts?.[who] ? new Date(h.alerts[who]).getTime() : new Date(h.start) - NO_ALERT_MIN * 6e4;
export const sharingNow = (h, who = uid) => {
  const now = Date.now();
  return now >= shareStart(h, who) && now < endOf(h) && !h.arrivals?.[who];
};
window.shareStart = shareStart;  // the map uses the same rule
const meters = ([a, b], [c, d]) => {
  const r = Math.PI / 180, x = Math.sin((c - a) * r / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin((d - b) * r / 2) ** 2;
  return 12742000 * Math.asin(Math.sqrt(x));
};

function share() {
  const active = () => hangouts.filter(h => sharingNow(h));
  if (!uid || !navigator.geolocation || !active().length) {
    if (watch !== null) navigator.geolocation.clearWatch(watch);
    watch = null;
    return;
  }
  if (watch !== null) return;
  watch = navigator.geolocation.watchPosition(pos => {
    const here = [pos.coords.latitude, pos.coords.longitude];
    for (const h of active()) {
      const last = sent[h.id];
      if (last && Date.now() - last.at < EVERY_MS && meters(last.here, here) < MOVED_M) continue;
      sent[h.id] = { here, at: Date.now() };
      setDoc(doc(db, "hangouts", h.id, "where", uid), { lat: here[0], lng: here[1], at: new Date().toISOString() }).catch(() => {});
    }
  }, () => {}, { enableHighAccuracy: true, maximumAge: 20000 });
}
setInterval(share, 60000);  // a hangout's sharing window can open while the page is sitting there

// friends.js calls this whenever your hangouts change
export function liveHangouts(list) {
  hangouts = list;
  share();
}

// the map calls this while it shows a hangout: cb({ uid: { lat, lng, at } }) now and on every move
window.watchHangoutPeople = (id, cb) => db
  ? onSnapshot(collection(db, "hangouts", id, "where"), s => cb(Object.fromEntries(s.docs.map(d => [d.id, d.data()]))), () => cb({}))
  : () => {};

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => { uid = u?.uid || null; hangouts = []; sent = {}; share(); });
}
