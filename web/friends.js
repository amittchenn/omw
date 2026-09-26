// Friends: add someone by their unique friend ID, they accept, and "My friends" stays in sync (Firebase Firestore).
//
// Firestore layout
//   codes/{ID}                  { uid, name }: claims a unique friend ID (the database refuses duplicates)
//   users/{uid}                 name, photo, code, travelMode, home {lat, lng}: readable by you and your friends only
//   users/{uid}/friends/{fid}   one doc per friend (both people get one, only by accepting a request)
//   requests/{from}_{to}        a pending friend request
//   private/{uid}               { calToken }: the secret in your personal calendar link (only you can read it)
//   hangouts/{id}               a planned hangout: invited = everyone asked, attendees = who accepted, rsvp = {uid: going|declined}
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import {
  getFirestore, doc, getDoc, setDoc, addDoc, updateDoc, arrayUnion, arrayRemove, collection, query, where, onSnapshot, writeBatch,
  deleteDoc, serverTimestamp,
} from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";
import { googleCalIcon, appleCalIcon, calendarHangouts } from "./gcal.js";
import { checkInHtml, leaderboardHangouts } from "./leaderboard.js";
import { liveHangouts, sharingNow, shareStart } from "./live.js";
import { chatHangouts, unreadCount } from "./chat.js";

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const MODES = { driving: "🚗 Drive", walking: "🚶 Walk", cycling: "🚲 Bike", transit: "🚌 Transit" };
const ID_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";  // no 0/O or 1/I/L, so IDs are easy to read out loud

let me = null, profile = {}, friendIds = [], friends = {}, incoming = [], outgoing = [], hangouts = [], invites = [], calToken = "", stop = [];
let hangoutDocs = {};  // every hangout you're invited to or going to, by id

const say = (text, ok = false) => { $("addMsg").textContent = text; $("addMsg").className = ok ? "ok" : ""; };
const randomId = () => Array.from(crypto.getRandomValues(new Uint32Array(6)), n => ID_CHARS[n % ID_CHARS.length]).join("");
const cleanId = v => v.toUpperCase().replace(/[^A-Z0-9]/g, "");
// ---------- avatars: everyone gets a cartoon avatar they can restyle (like Snap Map), or their own photo ----------
const STYLES = [["avataaars", "Classic"], ["adventurer", "Adventurer"], ["lorelei", "Lorelei"], ["notionists", "Sketch"],
                ["micah", "Micah"], ["big-smile", "Smiley"], ["fun-emoji", "Emoji"], ["pixel-art", "Pixel"]];
const BGS = ["ffd000", "ffb3c7", "b9a8ff", "8fe3c0", "9fd4ff", "ffc49c", "f1f0f7", "2b2b3a"];
const avatarUrl = a => `https://api.dicebear.com/9.x/${a.style}/svg?seed=${encodeURIComponent(a.seed)}&backgroundColor=${a.bg}`;
const defaultAvatar = uid => ({ style: "avataaars", seed: uid, bg: "ffd000" });
// your Google/Facebook photo by default; a cartoon avatar once you pick one (or if you have no photo)
const usesPhoto = (a, user) => !!user?.photoURL && (a?.style ? !!a.usePhoto : true);
const photoFor = (a, user) => usesPhoto(a, user) ? user.photoURL : avatarUrl(a?.style ? a : defaultAvatar(user.uid));
let looks = [];  // the 8 options shown in the avatar editor

const pic = (p, cls = "") => p.photo
  ? `<div class="avatar ${cls}" style="background-image:url('${esc(p.photo)}')"></div>`
  : `<div class="avatar ${cls}" style="--c:#ffb000"><span>${esc((p.name || "?").slice(0, 2).toUpperCase())}</span></div>`;

// tell the planner who's in "My friends" (you + everyone who accepted)
function publish() {
  const toPerson = (uid, p) => ({ user_id: uid, name: p.name || "Friend", travel_mode: p.travelMode || "driving",
                                  home: p.home ? [p.home.lat, p.home.lng] : null, photo: p.photo || "", real: true, code: p.code || "",
                                  busy: p.busy || [],
                                  // how many minutes after their alert they really left, from their check-ins (the model learns from these)
                                  habits: (Array.isArray(p.habits) ? p.habits : []).filter(x => typeof x?.delay === "number").slice(-30).map(x => x.delay) });
  window.myFriends = me ? [{ ...toPerson(me.uid, profile), name: "You", realName: profile.name || "Me", isMe: true },
                           ...friendIds.filter(id => friends[id]).map(id => toPerson(id, friends[id]))] : [];
  window.myCategories = profile.categories || [];  // hangout categories you made (emoji + name)
  window.dispatchEvent(new Event("friends-changed"));
}

// ---------- drawing the panel ----------
function renderMe() {
  $("meAvatar").outerHTML = pic(profile, "big").replace('class="avatar', 'id="meAvatar" title="Change your avatar" class="avatar');
  $("meAvatar").onclick = () => { $("avatarEditor").hidden = !$("avatarEditor").hidden; renderAvatarEditor(); };
  if (profile.photo) { $("userPic").style.backgroundImage = `url("${profile.photo}")`; $("userPic").textContent = ""; }
  if (!$("avatarEditor").hidden) renderAvatarEditor();
  if (document.activeElement !== $("meName")) $("meName").value = profile.name || "";
  $("meCode").textContent = profile.code || "······";
  $("meModes").querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.mode === (profile.travelMode || "driving")));
  $("meHome").innerHTML = profile.home
    ? `✅ <b>${esc(profile.homeName || "Home set")}</b>${profile.homeAddress ? `<small>${esc(profile.homeAddress)}</small>` : ""}`
    : `⚠️ Not set yet. The planner needs it to time your alerts.`;
  if ($("setHome").dataset.busy !== "1") $("setHome").textContent = profile.home ? "📍 Update to where I am now" : "📍 Use my current location";
  if (document.activeElement !== $("schedText")) $("schedText").value = profile.scheduleText || "";
  renderBusy(profile.busy || []);
}

function renderAvatarEditor() {
  const a = profile.avatar?.style ? profile.avatar : defaultAvatar(me.uid);
  if (!looks.length || looks[0].style !== a.style) looks = [a.seed, ...Array.from({ length: 7 }, () => Math.random().toString(36).slice(2, 8))]
    .map(seed => ({ style: a.style, seed }));
  const accountPhoto = me.photoURL, onPhoto = usesPhoto(profile.avatar, me);
  $("avatarEditor").innerHTML = `
    <div class="av-styles">${STYLES.map(([s, n]) => `<button class="${s === a.style && !onPhoto ? "on" : ""}" data-style="${s}">
      <img src="${avatarUrl({ style: s, seed: a.seed, bg: a.bg })}" alt=""><small>${n}</small></button>`).join("")}</div>
    <div class="av-looks">${looks.map(l => `<button class="${l.seed === a.seed && !onPhoto ? "on" : ""}" data-seed="${esc(l.seed)}">
      <img src="${avatarUrl({ ...l, bg: a.bg })}" alt=""></button>`).join("")}</div>
    <div class="av-row"><div class="av-bgs">${BGS.map(c => `<button style="background:#${c}" class="${c === a.bg ? "on" : ""}" data-bg="${c}" title="Background"></button>`).join("")}</div>
      <button class="mini" data-shuffle="1">🎲 More</button></div>
    ${accountPhoto ? `<button class="wide av-photo ${onPhoto ? "on" : ""}" data-photo="1">📷 ${onPhoto ? "Using" : "Use"} my ${me.providerData.some(p => p.providerId === "facebook.com") && !me.providerData.some(p => p.providerId === "google.com") ? "Facebook" : "Google"} photo</button>` : ""}`;
}
async function saveAvatar(change) {
  const avatar = { ...(profile.avatar?.style ? profile.avatar : defaultAvatar(me.uid)), usePhoto: false, ...change };
  const photo = photoFor(avatar, me);
  profile = { ...profile, avatar, photo };  // show it right away
  renderMe();
  await saveProfile({ avatar, photo });
}

const DAY_ORDER = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const ampm = hhmm => { const [h, m] = hhmm.split(":").map(Number); return `${(h + 11) % 12 + 1}${m ? ":" + String(m).padStart(2, "0") : ""}${h < 12 ? "am" : "pm"}`; };
function renderBusy(blocks) {
  const sorted = [...blocks].sort((a, b) => DAY_ORDER.indexOf(a.day) - DAY_ORDER.indexOf(b.day) || a.start.localeCompare(b.start));
  $("schedChips").innerHTML = sorted.length
    ? sorted.map(b => `<span class="busy-chip"><b>${esc(b.day)}</b> ${ampm(b.start)}–${ampm(b.end)} · ${esc(b.label)}</span>`).join("")
    : `<div class="note">No busy times saved yet, so the planner assumes you're always free.</div>`;
}

function updateBadge() {  // friend requests on your avatar, hangout invitations on 📅
  $("reqBadge").textContent = incoming.length;
  $("reqBadge").hidden = !incoming.length;
  const n = invites.length + hangouts.reduce((sum, h) => sum + unreadCount(h.id), 0);  // invitations + unread chat messages
  $("planBadge").textContent = n;
  $("planBadge").hidden = !n;
}

function renderRequests() {
  updateBadge();
  $("requests").innerHTML =
    incoming.map(r => `<div class="person">${pic({ name: r.fromName, photo: r.fromPhoto })}
        <div class="who"><b>${esc(r.fromName)}</b><small>wants to be friends</small></div>
        <button class="mini yes" data-accept="${esc(r.from)}">Accept</button>
        <button class="mini" data-decline="${esc(r.from)}" title="Decline">✕</button></div>`).join("") +
    outgoing.map(r => `<div class="person">${pic({ name: r.toName })}
        <div class="who"><b>${esc(r.toName)}</b><small>waiting for them to accept</small></div>
        <button class="mini" data-cancel="${esc(r.to)}">Cancel</button></div>`).join("");
}

function renderFriends() {
  $("friendCount").textContent = friendIds.length ? `(${friendIds.length})` : "";
  $("friendList").innerHTML = friendIds.length
    ? friendIds.filter(id => friends[id]).map(id => {
        const f = friends[id];
        return `<div class="person">${pic(f)}<div class="who"><b>${esc(f.name)}</b>
          <small>${MODES[f.travelMode || "driving"]} · ${f.home ? "home set" : "no home yet"}</small></div>
          <button class="mini" data-remove="${esc(id)}" title="Remove friend">✕</button></div>`;
      }).join("")
    : `<div class="nobody">No friends yet. Share your ID or add someone's 👆</div>`;
}

// ---------- calendars ----------
const feedPath = () => `${location.host}/calendar/${calToken}.ics`;
const icsTime = iso => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const endOf = h => new Date(new Date(h.start).getTime() + (h.durationMin || 120) * 6e4).toISOString();
const whenText = h => new Date(h.start).toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

function renderCalendar() {
  if (!calToken) return;
  $("calApple").href = `webcal://${feedPath()}`;
  $("appleIcon").innerHTML = appleCalIcon(24);
  $("calNote").textContent = "Apple adds all your hangouts the moment you subscribe, then checks for new ones on its own. "
    + "On a Mac, set the calendar's Auto-refresh to “Every 5 minutes”.";
}

function googleLink(h) {  // one-tap "add this one event" link
  const q = new URLSearchParams({ action: "TEMPLATE", text: h.title, dates: `${icsTime(h.start)}/${icsTime(endOf(h))}`,
                                  location: [h.venueName, h.address].filter(Boolean).join(", "),
                                  details: `Planned in omw with ${h.attendees.map(u => nameOf(h, u)).join(", ")}.` });
  return `https://calendar.google.com/calendar/render?${q}`;
}

function appleFile(h) {  // a one-event .ics file; opening it on a Mac or iPhone adds it to Apple Calendar
  const e = s => String(s).replace(/[\\;,]/g, m => "\\" + m);
  const alert = h.alerts?.[me.uid];
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Hangout//EN", "BEGIN:VEVENT", `UID:${h.id}@hangout`,
    `DTSTAMP:${icsTime(new Date().toISOString())}`, `DTSTART:${icsTime(h.start)}`, `DTEND:${icsTime(endOf(h))}`,
    `SUMMARY:${e(h.title)}`, `LOCATION:${e([h.venueName, h.address].filter(Boolean).join(", "))}`,
    ...(alert ? ["BEGIN:VALARM", "ACTION:DISPLAY", `DESCRIPTION:${e("Time to leave for " + h.venueName)}`,
                 `TRIGGER;VALUE=DATE-TIME:${icsTime(alert)}`, "END:VALARM"] : []),
    "END:VEVENT", "END:VCALENDAR"];
  return URL.createObjectURL(new Blob([lines.join("\r\n")], { type: "text/calendar" }));
}

// names: newer hangouts keep a {uid: name} map; older ones kept a list next to attendees
const nameOf = (h, u) => u === me?.uid ? "You" : h.names?.[u] || h.attendeeNames?.[h.attendees.indexOf(u)] || "A friend";
const leaveTime = (h, u = me.uid) => h.alerts?.[u] ? new Date(h.alerts[u]).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "";
function whoIsComing(h) {  // "Going: You, Priya · Waiting: Sam · Can't: Leo"
  const invited = h.invited || h.attendees, rsvp = h.rsvp || {};
  const list = us => us.map(u => esc(nameOf(h, u))).join(", ");
  const waiting = invited.filter(u => !h.attendees.includes(u) && rsvp[u] !== "declined");
  const declined = invited.filter(u => rsvp[u] === "declined");
  return [`Going: ${list(h.attendees)}`, waiting.length && `Waiting: ${list(waiting)}`, declined.length && `Can't: ${list(declined)}`]
    .filter(Boolean).join(" · ");
}

// ---------- My plans: every hangout you said yes to stays here, coming up and past ----------
const timeOf = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const MODE_ICON = { driving: "🚗", walking: "🚶", cycling: "🚲", transit: "🚌" };
function arrivedText(h, u) {
  const t = h.arrivals?.[u];
  if (!t) return "";
  const late = Math.round((new Date(t) - new Date(h.start)) / 6e4);
  return late < -1 ? `arrived ${-late} min early` : late <= 5 ? "arrived on time" : `arrived ${late} min late`;
}
function personLine(h, u, past) {  // "🚗 Priya · leaves 6:40pm" (or how it went, once it's over)
  const status = arrivedText(h, u) || (past ? "no check-in" : h.alerts?.[u] ? `leaves ${timeOf(h.alerts[u])}` : "");
  return `<div><b>${MODE_ICON[h.modes?.[u]] || ""} ${esc(nameOf(h, u))}</b><span>${esc(status)}</span></div>`;
}
function planCard(h, { past = false, next = false } = {}) {
  const invited = h.invited || h.attendees, rsvp = h.rsvp || {};
  const waiting = invited.filter(u => !h.attendees.includes(u) && rsvp[u] !== "declined");
  const declined = invited.filter(u => rsvp[u] === "declined");
  const names = us => us.map(u => esc(nameOf(h, u))).join(", ");
  const mine = h.createdBy === me.uid;
  return `<div class="plan-card ${past ? "past" : ""} ${next ? "next" : ""}" data-show="${esc(h.id)}" title="Tap to see it on the map">
    <div class="plan-head"><div class="who"><b>${esc(h.title)}</b>
        <small>${esc(whenText(h))}${h.address ? ` · ${esc(h.address)}` : ""}</small>
        <small>Planned by ${mine ? "you" : esc(h.createdByName || "a friend")}</small></div>
      ${past ? "" : mine ? `<button class="mini" data-cancel-hangout="${esc(h.id)}" title="Cancel for everyone">✕</button>`
                         : `<button class="mini" data-leave="${esc(h.id)}" title="I can't make it">✕</button>`}</div>
    ${!past && leaveTime(h) ? `<div class="plan-you">🔔 You leave at ${leaveTime(h)}</div>` : ""}
    ${past ? "" : modeChips(h, myModeFor(h), "data-my-mode")}
    <div class="plan-people">${h.attendees.map(u => personLine(h, u, past)).join("")}</div>
    ${waiting.length || declined.length ? `<small class="note">${[waiting.length && `Waiting on ${names(waiting)}`,
                                                                   declined.length && `Can't make it: ${names(declined)}`].filter(Boolean).join(" · ")}</small>` : ""}
    ${past ? "" : sharingNow(h) ? `<small class="note">📡 Sharing your location with the people going until you get there</small>`
      : `<small class="note">📡 Your location is shared with the group from ${timeOf(new Date(shareStart(h)).toISOString())} (when you should leave) until you arrive</small>`}
    ${past ? "" : checkInHtml(h)}
    <div class="plan-actions">
      ${h.venue ? `<button class="mini dark" data-show="${esc(h.id)}">${past ? "🗺️ Show on map" : "📍 Where is everyone?"}</button>` : ""}
      <button class="mini" data-chat="${esc(h.id)}">💬 Chat${unreadCount(h.id) ? ` <span class="unread">${unreadCount(h.id)}</span>` : ""}</button>
      ${past ? "" : `<a class="mini" href="${googleLink(h)}" target="_blank" rel="noopener" title="Add to Google Calendar">${googleCalIcon(20)}</a>
        <a class="mini" href="${appleFile(h)}" download="hangout.ics" title="Add to Apple Calendar">${appleCalIcon(20, new Date(h.start))}</a>`}
    </div>
  </div>`;
}

// "This week" on the main screen: your plans in the next 7 days, tap one to see it on the map
function renderWeek(upcoming) {
  const soon = upcoming.filter(h => new Date(h.start) - Date.now() < 7 * 864e5);
  const day = h => { const d = new Date(h.start), today = new Date();
    const diff = Math.round((new Date(d.toDateString()) - new Date(today.toDateString())) / 864e5);
    return diff === 0 ? "Today" : diff === 1 ? "Tomorrow" : d.toLocaleDateString([], { weekday: "short" }); };
  $("weekSection").hidden = !soon.length;
  $("weekList").innerHTML = soon.map(h => `<button class="week-card" data-week="${esc(h.id)}">
      <b>${esc(h.title)}</b><small>${day(h)} · ${timeOf(h.start)}</small>
      ${leaveTime(h) ? `<small class="leave">🔔 leave ${leaveTime(h)}</small>` : ""}</button>`).join("");
}

function renderHangouts() {
  const over = h => new Date(endOf(h)) <= new Date();
  const upcoming = hangouts.filter(h => !over(h)).sort((a, b) => a.start.localeCompare(b.start));
  const past = hangouts.filter(over).sort((a, b) => b.start.localeCompare(a.start));  // newest first
  $("hangoutList").innerHTML = upcoming.length
    ? upcoming.map((h, i) => planCard(h, { next: i === 0 })).join("")
    : `<div class="nobody">Nothing planned yet. Plan one with your friends and tap "Send invites", or accept an invitation.</div>`;
  $("pastSection").hidden = !past.length;
  renderWeek(upcoming);
  $("pastList").innerHTML = past.map(h => planCard(h, { past: true })).join("");
}

function renderInvites() {
  $("inviteSection").hidden = !invites.length;
  $("inviteCount").textContent = invites.length ? `(${invites.length})` : "";
  $("inviteList").innerHTML = invites.map(h => `<div class="invite">
      <b>${esc(h.title)}</b>
      <small>${esc(whenText(h))} · from ${esc(h.createdByName || "a friend")}</small>
      <small>${whoIsComing(h)}</small>
      ${leaveTime(h) ? `<small>🔔 Your leave-now alert would be ${leaveTime(h)}</small>` : ""}
      <small>How are you getting there?</small>${modeChips(h, inviteMode[h.id] || myModeFor(h), "data-inv-mode")}
      <div class="rsvp"><button class="mini yes" data-going="${esc(h.id)}">✓ I'm in</button>
        <button class="mini" data-decline-invite="${esc(h.id)}">Can't make it</button></div>
    </div>`).join("");
  updateBadge();
}

// ---------- how you're getting there (you pick when accepting, and can change it later) ----------
const inviteMode = {};  // hangout id -> the way you picked on an invitation, before accepting
const myModeFor = h => h.modes?.[me.uid] || profile.travelMode || "driving";
const modeChips = (h, current, attr) => `<div class="modes">${Object.entries(MODES).map(([m, label]) =>
  `<button class="mode-chip ${m === current ? "on" : ""}" ${attr}="${esc(h.id)}" data-mode="${m}">${label}</button>`).join("")}</div>`;
const localIso = iso => { const d = new Date(iso); return new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); };

// your leave-now time for this hangout if you go this way (same model and Google trip time as the planner used)
async function myAlert(h, mode) {
  const res = await fetch("/plan", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
    user_ids: [me.uid], venue: h.venue, start_time: localIso(h.start), hangout_type: h.type || "food", modes: { [me.uid]: mode },
    utc_offset_min: -new Date().getTimezoneOffset(),
    guests: [{ user_id: me.uid, name: profile.name || "Me", travel_mode: mode, home: profile.home ? [profile.home.lat, profile.home.lng] : null,
               habits: window.myFriends?.find(p => p.isMe)?.habits || [] }] }) });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).detail || res.statusText);
  const [r] = await res.json();
  return { alert: new Date(r.alert_time).toISOString(), travel: Math.round(r.travel_minutes * 10) / 10 };
}
async function myWayThere(h, mode) {  // { modes.me, alerts.me } to save; keeps the old alert if the planner can't be reached
  const update = { [`modes.${me.uid}`]: mode };
  if (h.venue && (mode !== h.modes?.[me.uid] || !h.alerts?.[me.uid])) {
    try {
      const { alert, travel } = await myAlert(h, mode);
      update[`alerts.${me.uid}`] = alert; update[`travel.${me.uid}`] = travel;
    } catch { /* keep the planner's alert */ }
  }
  return update;
}

// accepting adds you to the hangout (your calendar, alerts and the leaderboard follow); declining takes you off.
// Only people who accept are ever added: the planner's invite just lists you under "invited".
const rsvp = async (id, answer) => updateDoc(doc(db, "hangouts", id), {
  attendees: answer === "going" ? arrayUnion(me.uid) : arrayRemove(me.uid),
  [`rsvp.${me.uid}`]: answer,
  ...(answer === "going" ? await myWayThere(hangoutDocs[id], inviteMode[id] || myModeFor(hangoutDocs[id])) : {}),
});
const changeMode = async (id, mode) => updateDoc(doc(db, "hangouts", id), await myWayThere(hangoutDocs[id], mode));

// both listeners feed this: split into hangouts you're going to and invitations waiting on you
function sortHangouts() {
  const all = Object.values(hangoutDocs), upcoming = h => new Date(endOf(h)) > new Date();
  hangouts = all.filter(h => h.attendees.includes(me.uid));
  invites = all.filter(h => !h.attendees.includes(me.uid) && !h.rsvp?.[me.uid] && upcoming(h))
    .sort((a, b) => a.start.localeCompare(b.start));
  renderHangouts(); renderInvites();
  calendarHangouts(hangouts);  // push them straight into Google Calendar if connected
  leaderboardHangouts(hangouts);  // check-ins and the "who's always late" board
  liveHangouts(hangouts);  // share your location with the group around hangout time
  chatHangouts(hangouts, profile.name);  // the group chat for each one (arrivals get announced there)
  window.hangoutsChanged?.(hangoutDocs);  // the map, if it's showing one of them
}

// the planner calls this when you tap "Send invites": you're going, everyone else gets an invitation
window.lockInHangout = async details => {
  if (!me) throw new Error("Sign in first.");
  const invited = [...new Set([me.uid, ...details.invited])];
  const ref = await addDoc(collection(db, "hangouts"), {
    ...details, invited, attendees: [me.uid], rsvp: { [me.uid]: "going" },
    createdBy: me.uid, createdByName: profile.name || "A friend", createdAt: serverTimestamp(),
    tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
  });
  return ref.id;
};

// ---------- your unique friend ID ----------
async function ensureId(user) {
  // keep your ID if you already own it; otherwise claim a random unused one
  if (profile.code) {
    const mine = await getDoc(doc(db, "codes", profile.code));
    if (mine.exists() && mine.data().uid === user.uid) return;
  }
  for (let tries = 0; tries < 5; tries++) {
    const code = randomId();
    try {
      await setDoc(doc(db, "codes", code), { uid: user.uid, name: profile.name });  // refused if someone owns it
      await saveProfile({ code });
      return;
    } catch { /* taken: try another */ }
  }
}

async function ensureCalToken(user) {
  const ref = doc(db, "private", user.uid);
  const snap = await getDoc(ref);
  calToken = snap.exists() && snap.data().calToken;
  if (!calToken) {
    calToken = Array.from(crypto.getRandomValues(new Uint8Array(24)), b => "abcdefghijkmnpqrstuvwxyz23456789"[b % 32]).join("");
    await setDoc(ref, { calToken });
  }
  renderCalendar();
}

// ---------- actions ----------
async function sendRequest() {
  const code = cleanId($("addInput").value);
  if (code.length !== 6) return say("Friend IDs are 6 characters, like K7P2QX.");
  if (code === profile.code) return say("That's your own ID! 😄");
  const owner = await getDoc(doc(db, "codes", code));
  if (!owner.exists()) return say("No one has that ID. Double-check it with your friend.");
  const { uid, name } = owner.data();
  if (friendIds.includes(uid)) return say(`You're already friends with ${name}.`);
  if (outgoing.some(r => r.to === uid)) return say(`You already asked ${name}. Waiting for them to accept.`);
  if (incoming.some(r => r.from === uid)) return say(`${name} already sent you a request. Accept it below 👇`);
  await setDoc(doc(db, "requests", `${me.uid}_${uid}`), {
    from: me.uid, to: uid, fromName: profile.name, fromPhoto: profile.photo || "", toName: name, createdAt: serverTimestamp(),
  });
  $("addInput").value = "";
  say(`Request sent to ${name} ✨ You'll be friends once they accept.`, true);
}

async function accept(from) {
  // the database only allows these two writes because a request from them to you exists
  const batch = writeBatch(db);
  batch.set(doc(db, "users", me.uid, "friends", from), { since: serverTimestamp() });
  batch.set(doc(db, "users", from, "friends", me.uid), { since: serverTimestamp() });
  batch.delete(doc(db, "requests", `${from}_${me.uid}`));
  await batch.commit();
  say("You're now friends 🎉", true);
}

async function removeFriend(id) {
  if (!confirm(`Remove ${friends[id]?.name || "this friend"}?`)) return;
  const batch = writeBatch(db);
  batch.delete(doc(db, "users", me.uid, "friends", id));
  batch.delete(doc(db, "users", id, "friends", me.uid));
  await batch.commit();
  delete friends[id];
}

const saveProfile = data => setDoc(doc(db, "users", me.uid), data, { merge: true });
window.saveCategories = categories => saveProfile({ categories });  // the planner's "＋ New" and ✕ call this

function run(action) {
  return async (...args) => {
    try { await action(...args); }
    catch (e) {
      say(e.code === "permission-denied"
        ? "The database refused that. Check the Firestore rules (see setup steps)."
        : `Something went wrong: ${e.message}`);
    }
  };
}

// ---------- wiring ----------
let db;
const configured = firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE");

$("userPic").onclick = () => { $("drawer").hidden = false; };
window.addEventListener("chat-changed", () => { if (me) { renderHangouts(); updateBadge(); } });
$("drawerClose").onclick = () => { $("drawer").hidden = true; };
$("drawer").onclick = e => { if (e.target.id === "drawer") $("drawer").hidden = true; };

if (configured) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);

  $("addBtn").onclick = run(sendRequest);
  $("addInput").onkeydown = e => { if (e.key === "Enter") run(sendRequest)(); };
  $("copyCode").onclick = () => {
    navigator.clipboard?.writeText(profile.code || "");
    $("copyCode").textContent = "Copied!";
    setTimeout(() => ($("copyCode").textContent = "Copy"), 1500);
  };
  $("meName").onchange = run(async () => {
    const name = $("meName").value.trim() || profile.name;
    await saveProfile({ name });
    if (profile.code) await setDoc(doc(db, "codes", profile.code), { name }, { merge: true });
  });
  $("meModes").onclick = run(async e => { const b = e.target.closest("[data-mode]"); if (b) await saveProfile({ travelMode: b.dataset.mode }); });
  $("avatarEditor").onclick = run(async e => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.style) { looks = []; await saveAvatar({ style: b.dataset.style }); }
    if (b.dataset.seed) await saveAvatar({ seed: b.dataset.seed });
    if (b.dataset.bg) await saveAvatar({ bg: b.dataset.bg });
    if (b.dataset.shuffle) { const a = profile.avatar?.style ? profile.avatar : defaultAvatar(me.uid);
      looks = [a.seed, ...Array.from({ length: 7 }, () => Math.random().toString(36).slice(2, 8))].map(seed => ({ style: a.style, seed })); renderAvatarEditor(); }
    if (b.dataset.photo) await saveAvatar({ usePhoto: !usesPhoto(profile.avatar, me) });
  });
  $("readSched").onclick = async () => {
    const text = $("schedText").value.trim();
    $("readSched").disabled = true; $("readSched").textContent = "Reading…"; $("schedMsg").textContent = "";
    try {
      const res = await fetch("/parse-schedule", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || res.statusText);
      await saveProfile({ busy: data.blocks, scheduleText: text });
      const by = data.read_by ? ` (read by ${data.read_by})` : "";
      $("schedMsg").textContent = data.blocks.length ? `✅ Saved ${data.blocks.length} busy times${by}. Friends' planners will work around them.` : `✅ Saved: no busy times found${by}.`;
      $("schedMsg").className = "ok";
    } catch (e) {
      $("schedMsg").textContent = e.message; $("schedMsg").className = "";
    } finally {
      $("readSched").disabled = false; $("readSched").textContent = "✨ Read my schedule";
    }
  };
  $("setHome").onclick = () => {
    if (!navigator.geolocation) return say("This browser can't share location.");
    $("setHome").textContent = "Finding you…"; $("setHome").dataset.busy = "1";
    const done = () => { $("setHome").dataset.busy = ""; renderMe(); };
    const fix = window.myFix;  // the blue dot's latest spot, if fresh (asking again while it's tracking can stall)
    const locate = fix && Date.now() - fix.at < 60000
      ? (ok => ok({ coords: { latitude: fix.here[0], longitude: fix.here[1] } }))
      : ((ok, no) => navigator.geolocation.getCurrentPosition(ok, no, { enableHighAccuracy: true, timeout: 10000 }));
    locate(
      run(async p => {
        const home = { lat: p.coords.latitude, lng: p.coords.longitude };
        // a readable name for it ("266 Ferst Dr") instead of coordinates
        const place = await fetch(`/place-name?lat=${home.lat}&lng=${home.lng}`).then(r => r.json()).catch(() => ({}));
        await saveProfile({ home, homeName: place.name || "Home set", homeAddress: place.address || "" });
        done();
      }),
      () => { done(); say("Location blocked. Allow it in your browser's site settings."); },
    );
  };
  $("requests").onclick = run(async e => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.accept) await accept(b.dataset.accept);
    if (b.dataset.decline) await deleteDoc(doc(db, "requests", `${b.dataset.decline}_${me.uid}`));
    if (b.dataset.cancel) await deleteDoc(doc(db, "requests", `${me.uid}_${b.dataset.cancel}`));
  });
  $("plansBtn").onclick = () => { $("plans").hidden = false; };
  $("plansClose").onclick = () => { $("plans").hidden = true; };
  $("plans").onclick = e => { if (e.target.id === "plans") $("plans").hidden = true; };
  $("pastList").onclick = $("hangoutList").onclick = run(async e => {
    const b = e.target.closest("button, a");
    const show = e.target.closest("[data-show]");
    if (show && (!b || b.dataset.show)) { $("plans").hidden = true; return window.showHangout(hangoutDocs[show.dataset.show]); }
    if (b?.dataset.chat) { $("plans").hidden = true; return window.openChat(b.dataset.chat); }
    if (b?.dataset.myMode && !b.classList.contains("on")) { b.textContent = "…"; await changeMode(b.dataset.myMode, b.dataset.mode); }
    if (b?.dataset.cancelHangout && confirm("Cancel this hangout for everyone?")) await deleteDoc(doc(db, "hangouts", b.dataset.cancelHangout));
    if (b?.dataset.leave && confirm("Can't make it? You'll be taken off this hangout.")) await rsvp(b.dataset.leave, "declined");
  });
  $("weekList").onclick = e => {
    const card = e.target.closest("[data-week]");
    if (card) window.showHangout(hangoutDocs[card.dataset.week]);
  };
  $("inviteList").onclick = run(async e => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.invMode) { inviteMode[b.dataset.invMode] = b.dataset.mode; return renderInvites(); }
    b.disabled = true;
    if (b.dataset.going) b.textContent = "Timing your trip…";
    if (b.dataset.going) await rsvp(b.dataset.going, "going");
    if (b.dataset.declineInvite) await rsvp(b.dataset.declineInvite, "declined");
  });
  $("copyCal").onclick = () => {
    navigator.clipboard?.writeText(`${location.protocol}//${feedPath()}`);
    $("copyCal").textContent = "Copied!";
    setTimeout(() => ($("copyCal").textContent = "Copy link"), 1500);
  };
  $("friendList").onclick = run(async e => {
    const id = e.target.closest("button")?.dataset.remove;
    if (id) await removeFriend(id);
  });

  onAuthStateChanged(getAuth(app), run(async user => {
    stop.forEach(unsubscribe => unsubscribe());
    stop = []; me = user; profile = {}; friendIds = []; friends = {}; incoming = []; outgoing = []; hangouts = []; invites = [];
    hangoutDocs = {}; calToken = "";
    if (!user) return publish();

    // create your profile the first time, then make sure you own a unique friend ID
    const ref = doc(db, "users", user.uid);
    const existing = await getDoc(ref);
    if (!existing.exists()) {
      await setDoc(ref, { name: user.displayName || (user.email || "friend").split("@")[0], travelMode: "driving" });
    }
    profile = (await getDoc(ref)).data();
    const photo = photoFor(profile.avatar, user);  // your omw avatar (or your photo, if you chose that)
    if (profile.photo !== photo) await setDoc(ref, { photo }, { merge: true });
    profile = { ...profile, photo };
    await ensureId(user);
    await ensureCalToken(user);

    stop.push(onSnapshot(ref, s => { profile = s.data() || {}; renderMe(); publish(); }));
    stop.push(onSnapshot(collection(db, "users", user.uid, "friends"), async s => {
      friendIds = s.docs.map(d => d.id);
      await Promise.all(friendIds.map(async id => {
        const p = await getDoc(doc(db, "users", id)).catch(() => null);
        if (p?.exists()) friends[id] = p.data();
      }));
      renderFriends(); publish();
    }));
    stop.push(onSnapshot(query(collection(db, "requests"), where("to", "==", user.uid)), s => {
      incoming = s.docs.map(d => d.data()); renderRequests();
    }));
    stop.push(onSnapshot(query(collection(db, "requests"), where("from", "==", user.uid)), s => {
      outgoing = s.docs.map(d => d.data()); renderRequests();
    }));
    // hangouts you're going to, and hangouts you're invited to (two queries, merged by id)
    const seenBy = { attendees: new Set(), invited: new Set() };
    for (const field of Object.keys(seenBy)) {
      stop.push(onSnapshot(query(collection(db, "hangouts"), where(field, "array-contains", user.uid)), s => {
        seenBy[field] = new Set(s.docs.map(d => d.id));
        s.docs.forEach(d => (hangoutDocs[d.id] = { ...d.data(), id: d.id }));
        for (const id in hangoutDocs) {  // cancelled: gone from both lists
          if (!seenBy.attendees.has(id) && !seenBy.invited.has(id)) delete hangoutDocs[id];
        }
        sortHangouts();
      }));
    }
  }));
}
