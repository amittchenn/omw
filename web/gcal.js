// Google Calendar, synced directly: connecting adds a separate "omw!" calendar to your Google Calendar, and every hangout
// you're part of goes into it (with a reminder at YOUR leave-now time) within seconds; changes and cancellations follow
// while omw! is open. omw! only asks for access to calendars it creates, so it can't see or change your own calendars.
// Also the Google Calendar icon.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import {
  getAuth, onAuthStateChanged, GoogleAuthProvider, reauthenticateWithPopup, linkWithPopup,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";

const SCOPE = "https://www.googleapis.com/auth/calendar.app.created";  // only calendars omw! makes itself
const API = "https://www.googleapis.com/calendar/v3";
const CAL_NAME = "omw!";
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

// ---------- syncing ----------
let auth, user = null, hangouts = [], status = "", busy = false, pending = false;
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
    description: [`Planned by ${h.createdByName || "a friend"} on omw!`, others.length && `With ${others.join(", ")}.`,
                  alert && `Leave at ${time(alert)}: timed to your habits, not just the trip.`].filter(Boolean).join(" "),
    start: { dateTime: h.start }, end: { dateTime: endOf(h) },
    // Google rings at your personal leave-now time
    reminders: minutes === null ? { useDefault: true } : { useDefault: false, overrides: [{ method: "popup", minutes }] },
  };
}

const expired = () => Object.assign(new Error("expired"), { expired: true });

async function call(method, url, body) {
  if (!token?.value) throw expired();  // Google's permission ran out (or you turned syncing off) partway through
  const res = await fetch(url, { method, headers: { Authorization: `Bearer ${token.value}`, "Content-Type": "application/json" },
                                 body: body && JSON.stringify(body) });
  if (res.status === 401) { token = null; store.set("gcalToken", null); throw expired(); }
  return res;
}

// the omw! calendar: the one saved on this device, or one omw! made before (another device), or a new one.
// Only ever one: extra omw! calendars (left by an earlier failed try) are removed, so you're never looking at an empty copy.
let checked = false;
async function omwCalendar() {
  const key = `gcalCal:${user.uid}`, saved = store.get(key);
  if (checked && saved) return saved;
  const list = await call("GET", `${API}/users/me/calendarList?minAccessRole=owner`);
  const ours = list.ok ? ((await list.json()).items || []).filter(c => c.summary === CAL_NAME).map(c => c.id) : [];
  let id = ours.includes(saved) ? saved : ours[0]
    || (saved && (await call("GET", `${API}/calendars/${encodeURIComponent(saved)}`)).ok ? saved : null);
  if (!id) {
    const made = await call("POST", `${API}/calendars`, { summary: CAL_NAME, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      description: "Hangouts planned with omw!, with a reminder at your leave-now time. Added by omw!; your other calendars aren't touched." });
    if (!made.ok) throw new Error((await made.json().catch(() => ({}))).error?.message || made.statusText);
    id = (await made.json()).id;
    store.set(key, id);  // saved right away, so a hiccup below never makes a second omw! calendar
    // omw! yellow, so the hangouts stand out. Only a nice-to-have: if Google says no, it doesn't stop the sync
    await fetch(`${API}/users/me/calendarList/${encodeURIComponent(id)}?colorRgbFormat=true`, { method: "PATCH",
      headers: { Authorization: `Bearer ${token.value}`, "Content-Type": "application/json" },
      body: JSON.stringify({ backgroundColor: "#ffe600", foregroundColor: "#000000", selected: true }) }).catch(() => {});
  }
  for (const extra of ours.filter(c => c !== id)) {  // Google only lets omw! delete calendars omw! made
    await call("DELETE", `${API}/calendars/${encodeURIComponent(extra)}`).catch(e => { if (e.expired) throw e; });
  }
  if (id !== saved) store.set(`gcalSynced:${user.uid}:${id}`, null);  // new to this device: add everything again
  store.set(key, id); checked = true;
  return id;
}

async function sync() {
  if (busy) { pending = true; return; }  // mid-sync: go round once more when it's done, with the newest list
  if (!user || !turnedOn() || !hasToken()) return render();
  busy = true; pending = false; status = "Syncing…"; render();
  const list = hangouts.slice();
  try {
    const cal = await omwCalendar(), EVENTS = `${API}/calendars/${encodeURIComponent(cal)}/events`;
    const syncedKey = `gcalSynced:${user.uid}:${cal}`, before = new Set(store.get(syncedKey) || []), now = new Set();
    for (const h of list.filter(h => new Date(endOf(h)) > new Date())) {
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
    status = `${now.size ? `${now.size} hangout${now.size === 1 ? "" : "s"} in your omw! calendar` : "Your omw! calendar is ready. New hangouts will appear there"} · synced ${time(new Date().toISOString())}`;
  } catch (e) {
    if (turnedOn()) status = e.expired ? "Google needs you to confirm again. Tap Sync Google Calendar." : friendly(e, "sync");
  } finally {
    busy = false;
  }
  render();
  if (pending) sync();
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
      "auth/credential-already-in-use": "That Google account belongs to a different omw! account.",
      "auth/user-mismatch": "Pick the same Google account you signed in with.",
    }[e.code] || e.message;
    render();
  }
}

// "Turn off" asks first: keep syncing, stop, or stop and delete the omw! calendar (it's omw!'s own; your other calendars are never touched)
function askTurnOff() {
  $("gcalBox").innerHTML = `<div class="cal-confirm"><b>Stop syncing to Google Calendar?</b>
    <small>New hangouts won't be added anymore. You can keep the omw! calendar in Google Calendar, or delete it.</small>
    <div class="cal-confirm-actions"><button class="mini" id="gcalKeep">Cancel</button>
      <button class="mini dark" id="gcalStop">Turn off</button>
      <button class="mini danger" id="gcalStopDelete">Turn off &amp; delete calendar</button></div></div>`;
  const off = async remove => {
    const cal = store.get(`gcalCal:${user.uid}`);
    if (remove && cal && hasToken()) {
      $("gcalStopDelete").disabled = true; $("gcalStopDelete").textContent = "Deleting…";
      await call("DELETE", `${API}/calendars/${encodeURIComponent(cal)}`).catch(() => {});
      store.set(`gcalCal:${user.uid}`, null);
    }
    store.set(`gcalOn:${user.uid}`, false); token = null; store.set("gcalToken", null);
    checked = false;
    status = remove ? "Turned off, and the omw! calendar was deleted." : "Turned off. Your omw! calendar is still in Google Calendar.";
    render();
  };
  $("gcalKeep").onclick = () => render();
  $("gcalStop").onclick = () => off(false);
  $("gcalStopDelete").onclick = () => off(true);
}

function render() {
  const box = $("gcalBox");
  if (!box || !user) return;
  if (turnedOn() && hasToken()) {
    box.innerHTML = `<div class="cal-status">${googleCalIcon(28)}<div><b>Google Calendar · omw! calendar</b><small>${esc(status || "Connected")}</small></div>
      <button class="mini" id="gcalOff" title="Stop syncing">Turn off</button></div>`;
    $("gcalOff").onclick = askTurnOff;
    return;
  }
  const again = turnedOn();
  box.innerHTML = `<button class="cal-btn" id="gcalConnect">${googleCalIcon(22)} ${again ? "Sync Google Calendar" : "Connect Google Calendar"}</button>
    ${status ? `<div class="note">${esc(status)}</div>` : ""}`;
  $("gcalConnect").onclick = connect;
}

// friends.js calls this whenever your hangouts change (someone plans, edits or cancels one)
export function calendarHangouts(list) {
  hangouts = list;
  sync();
}

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  auth = getAuth(getApps().length ? getApp() : initializeApp(firebaseConfig));
  onAuthStateChanged(auth, u => { if (u?.uid !== user?.uid) { hangouts = []; status = ""; checked = false; } user = u; render(); });
}
