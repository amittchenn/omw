// The Live Activity in the iPhone app: the Dynamic Island and lock screen show your next hangout from 30 minutes before
// your leave time until everyone's there: a countdown to when to leave (then to the start), and who's arrived.
// The native side is mobile/native/ (LiveActivityPlugin). While the app is closed, the server keeps it up to date (push.py),
// using the token saved here on private/{uid}.live[hangout id]. On the website this file does nothing.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, setDoc } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const native = !!window.Capacitor?.isNativePlatform?.();
const BEFORE_LEAVE_MIN = 30;   // shows up this long before your leave time
const AFTER_ALL_HERE_MIN = 5;  // and goes away this long after the last person arrives
const store = { get: k => { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
                set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } } };

const plugin = () => window.Capacitor.Plugins?.LiveActivity || window.Capacitor.registerPlugin("LiveActivity");
let me = null, db = null, shown = {}, busy = false;  // shown: hangout id -> the state we last sent

const time = iso => new Date(iso).getTime() / 1000;
const first = n => String(n || "Friend").split(" ")[0];

// the same numbers push.py sends (keep them in step)
function stateOf(h) {
  const att = h.attendees || [], arr = h.arrivals || {};
  const leave = h.alerts?.[me.uid] ? time(h.alerts[me.uid]) : time(h.start) - 30 * 60;
  const latest = att.filter(u => u !== me.uid && arr[u]).sort((a, b) => arr[b].localeCompare(arr[a]))[0];
  return { leaveAt: leave, startAt: time(h.start), here: att.filter(u => arr[u]).length, total: att.length,
           arrived: !!arr[me.uid], note: latest ? `${first(h.names?.[latest])} is here` : "" };
}

// which hangout to show now, if any
function current() {
  const now = Date.now() / 1000;
  return (window.myHangouts || []).filter(h => {
    const s = stateOf(h), end = time(h.start) + (h.durationMin || 120) * 60;
    const allHere = s.here === s.total && s.total > 0, lastIn = allHere ? Math.max(...h.attendees.map(u => time(h.arrivals[u]))) : 0;
    return now >= s.leaveAt - BEFORE_LEAVE_MIN * 60 && now < end && !(allHere && now > lastIn + AFTER_ALL_HERE_MIN * 60);
  }).sort((a, b) => a.start.localeCompare(b.start))[0];
}

async function sync() {
  if (!me || busy) return;
  busy = true;
  try {
    const la = plugin();
    if (!(await la.isAvailable()).available) return;  // turned off in Settings, or an older iPhone
    const h = current(), running = (await la.running()).ids || [];
    for (const id of running) if (id !== h?.id) { await la.end({ id }); delete shown[id]; }
    if (!h) return;
    const state = stateOf(h), key = JSON.stringify(state);
    // you swiped it away: don't bring it back for this hangout
    if (store.get(`live:${me.uid}:${h.id}`) && !running.includes(h.id) && !shown[h.id]) return;
    if (shown[h.id] === key && running.includes(h.id)) return;
    await la.start({ id: h.id, title: plainTitle(h.title), venue: h.venueName || "", ...state });
    shown[h.id] = key;
    store.set(`live:${me.uid}:${h.id}`, true);
  } catch (e) { console.warn("live activity:", e.message || e); }
  finally { busy = false; }
}

if (native && firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    me = u; shown = {};
    if (!u) plugin().end({}).catch(() => {});  // signed out: take it off the lock screen
  });
  // the server needs this to update it while the app is closed
  plugin().addListener("token", ({ id, token }) => {
    if (me) setDoc(doc(db, "private", me.uid), { live: { [id]: { token, fcm: window.omwPushToken || "" } } }, { merge: true }).catch(() => {});
  });
  window.addEventListener("hangouts-changed", sync);
  setInterval(sync, 30000);
  document.addEventListener("visibilitychange", () => document.hidden || sync());
  // tapping the Live Activity opens omw://hangout/<id>: show that plan
  const appPlugin = window.Capacitor.Plugins?.App;
  appPlugin?.addListener("appUrlOpen", ({ url }) => {
    const id = /^omw:\/\/hangout\/([\w-]+)/.exec(url || "")?.[1];
    if (id) setTimeout(() => window.openPlanCard?.(id), 300);
  });
}
