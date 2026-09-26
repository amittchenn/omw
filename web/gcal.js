// Google Calendar, synced directly: once you connect, every hangout you're part of is written straight into your
// Google Calendar (with a reminder at YOUR leave-now time) within seconds, and changes/cancellations follow while omw is open.
// Also the Google Calendar and Apple Calendar icons used around the app.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, GoogleAuthProvider, reauthenticateWithPopup, linkWithPopup,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";

const SCOPE = "https://www.googleapis.com/auth/calendar.events";
const EVENTS = "https://www.googleapis.com/calendar/v3/calendars/primary/events";
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const store = { get: k => { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
                set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } } };

// ---------- icons ----------
export const googleCalIcon = (size = 22) => `<svg width="${size}" height="${size}" viewBox="0 0 48 48" aria-hidden="true">
  <rect x="10" y="10" width="28" height="28" fill="#fff"/>
  <path fill="#1967D2" d="M0 10V5a5 5 0 0 1 5-5h5v10z"/><path fill="#4285F4" d="M10 0h28v10H10zM0 10h10v28H0z"/>
  <path fill="#FBBC04" d="M38 0h5a5 5 0 0 1 5 5v33H38z"/><path fill="#188038" d="M0 38h10v10H5a5 5 0 0 1-5-5z"/>
  <path fill="#34A853" d="M10 38h28v10H10z"/><path fill="#EA4335" d="M38 38h10L38 48z"/>
  <text x="24" y="31" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" fill="#4285F4">31</text></svg>`;

export const appleCalIcon = (size = 22, day = new Date()) => `<svg width="${size}" height="${size}" viewBox="0 0 48 48" aria-hidden="true">
  <rect x=".5" y=".5" width="47" height="47" rx="11" fill="#fff" stroke="#dcdce2"/>
  <text x="24" y="15.5" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="9.5" font-weight="700"
        fill="#FF3B30">${day.toLocaleDateString("en-US", { weekday: "short" }).toUpperCase()}</text>
  <text x="24" y="40" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="25" fill="#111">${day.getDate()}</text></svg>`;

// ---------- syncing ----------
let auth, user = null, hangouts = [], status = "", busy = false;
let token = store.get("gcalToken");  // { value, expires }: Google access tokens last an hour
const hasToken = () => token && token.value && token.expires > Date.now() && token.uid === user?.uid;
const turnedOn = () => user && store.get(`gcalOn:${user.uid}`);
const eventId = id => "om" + [...id].map(c => c.charCodeAt(0).toString(16).padStart(2, "0")).join("");  // Google allows 0-9 a-v
const endOf = h => new Date(new Date(h.start).getTime() + (h.durationMin || 120) * 6e4).toISOString();
const time = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

function eventFor(h) {
  const alert = h.alerts?.[user.uid];
  const minutes = alert ? Math.min(40320, Math.max(0, Math.round((new Date(h.start) - new Date(alert)) / 6e4))) : null;
  const others = h.attendees.filter(u => u !== user.uid).map(u => h.names?.[u] || h.attendeeNames?.[h.attendees.indexOf(u)]).filter(Boolean);
  return {
    summary: h.title,
    location: [h.venueName, h.address].filter(Boolean).join(", "),
    description: [`Planned by ${h.createdByName || "a friend"} in omw.`, others.length && `With ${others.join(", ")}.`,
                  alert && `Leave at ${time(alert)}: timed to your habits, not just the trip.`].filter(Boolean).join(" "),
    start: { dateTime: h.start }, end: { dateTime: endOf(h) },
    // Google rings at your personal leave-now time
    reminders: minutes === null ? { useDefault: true } : { useDefault: false, overrides: [{ method: "popup", minutes }] },
  };
}

async function call(method, url, body) {
  const res = await fetch(url, { method, headers: { Authorization: `Bearer ${token.value}`, "Content-Type": "application/json" },
                                 body: body && JSON.stringify(body) });
  if (res.status === 401) { token = null; store.set("gcalToken", null); throw Object.assign(new Error("expired"), { expired: true }); }
  return res;
}

async function sync() {
  if (!user || !turnedOn() || !hasToken() || busy) return render();
  busy = true; status = "Syncing…"; render();
  const syncedKey = `gcalSynced:${user.uid}`, before = new Set(store.get(syncedKey) || []), now = new Set();
  try {
    for (const h of hangouts.filter(h => new Date(endOf(h)) > new Date())) {
      const id = eventId(h.id), body = eventFor(h);
      let res = await call("PUT", `${EVENTS}/${id}`, body);                                  // update if it's already there
      if (res.status === 404) res = await call("POST", EVENTS, { ...body, id });             // otherwise add it
      if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error?.message || res.statusText);
      now.add(id);
    }
    for (const id of before) {  // hangouts that were cancelled (or you left) come off your calendar too
      if (!now.has(id)) await call("DELETE", `${EVENTS}/${id}`);
    }
    store.set(syncedKey, [...now]);
    status = `${now.size ? `${now.size} hangout${now.size === 1 ? "" : "s"} in your Google Calendar` : "Connected. New hangouts will appear here"} · synced ${time(new Date().toISOString())}`;
  } catch (e) {
    status = e.expired ? "" : `Couldn't sync: ${e.message}`;
  } finally {
    busy = false;
  }
  render();
}

async function connect() {
  const provider = new GoogleAuthProvider();
  provider.addScope(SCOPE);
  const current = auth.currentUser;
  try {
    // signed in with Google already? just ask for calendar access. Otherwise link a Google account to this one.
    const result = current.providerData.some(p => p.providerId === "google.com")
      ? await reauthenticateWithPopup(current, provider)
      : await linkWithPopup(current, provider);
    const value = GoogleAuthProvider.credentialFromResult(result)?.accessToken;
    token = { value, expires: Date.now() + 55 * 6e4, uid: current.uid };
    store.set("gcalToken", token);
    store.set(`gcalOn:${current.uid}`, true);
    await sync();
  } catch (e) {
    status = {
      "auth/popup-closed-by-user": "Google closed before it finished.",
      "auth/credential-already-in-use": "That Google account belongs to a different omw account.",
      "auth/user-mismatch": "Pick the same Google account you signed in with.",
    }[e.code] || e.message;
    render();
  }
}

function render() {
  const box = $("gcalBox");
  if (!box || !user) return;
  if (turnedOn() && hasToken()) {
    box.innerHTML = `<div class="cal-status">${googleCalIcon(28)}<div><b>Google Calendar</b><small>${esc(status || "Connected")}</small></div>
      <button class="mini" id="gcalOff" title="Stop syncing">Turn off</button></div>`;
    $("gcalOff").onclick = () => { store.set(`gcalOn:${user.uid}`, false); token = null; store.set("gcalToken", null); status = ""; render(); };
    return;
  }
  const again = turnedOn();
  box.innerHTML = `<button class="cal-btn" id="gcalConnect">${googleCalIcon(22)} ${again ? "Sync Google Calendar" : "Connect Google Calendar"}</button>
    <div class="note">${esc(status) || (again ? "Google asks you to confirm about once an hour. Tap to add any new hangouts."
                                             : "Hangouts appear in seconds, with a reminder at your personal leave-now time.")}</div>`;
  $("gcalConnect").onclick = connect;
}

// friends.js calls this whenever your hangouts change (someone plans, edits or cancels one)
export function calendarHangouts(list) {
  hangouts = list;
  sync();
}

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  auth = getAuth(getApps().length ? getApp() : initializeApp(firebaseConfig));
  onAuthStateChanged(auth, u => { user = u; hangouts = []; status = ""; render(); });
}
