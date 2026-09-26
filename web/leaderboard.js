// Leaderboard: who's always on time, and who's always "omw". Built from check-ins: when you get to a hangout, omw records
// the time (automatically once you're within 150 m, or you tap "I'm here"). Only you and your friends are on your board.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, updateDoc, setDoc, arrayUnion } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const LATE_AFTER_MIN = 5;           // more than 5 minutes after the start counts as late
const JUST_MS = 3 * 36e5;           // "just arrived" shows on the board for 3 hours
const AUTO_NEAR_M = 150, TAP_NEAR_M = 300;
const OPEN_BEFORE_MIN = 60, OPEN_AFTER_MIN = 120;  // when check-in is open, around the start time
const COLORS = ["#7b61ff", "#ff4f9a", "#ffb000", "#16c47f", "#1ea0ff", "#ff6a3d", "#00c2c7", "#a3d900"];
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const time = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

let db, uid = null, hangouts = [], watch = null, lastFix = null;

// ---------- check-ins ----------
const minutesLate = (h, t) => (new Date(t) - new Date(h.start)) / 6e4;
const checkInOpen = h => { const m = (Date.now() - new Date(h.start)) / 6e4; return m > -OPEN_BEFORE_MIN && m < OPEN_AFTER_MIN; };
const lateText = m => m < -1 ? `${Math.round(-m)} min early` : m <= LATE_AFTER_MIN ? "on time" : `${Math.round(m)} min late`;

function metersBetween([lat1, lng1], [lat2, lng2]) {
  const r = Math.PI / 180, a = Math.sin((lat2 - lat1) * r / 2) ** 2 +
    Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin((lng2 - lng1) * r / 2) ** 2;
  return 12742000 * Math.asin(Math.sqrt(a));
}

// friends.js puts this under each hangout in "Your hangouts"
export function checkInHtml(h) {
  const t = h.arrivals?.[uid];
  if (t) return `<small class="arrived">${icon("circle-check")} Arrived ${time(t)} · ${lateText(minutesLate(h, t))}</small>`;
  if (checkInOpen(h) && h.venue) return `<button class="mini yes checkin" data-checkin="${esc(h.id)}">${icon("map-pin-check-inside")} I'm here</button>`;
  return "";
}

// checking in saves your arrival on the hangout, and one more data point on your profile for the model to learn from:
// how many minutes after your leave-now alert you actually left (arrival − trip time − alert)
const recorded = new Set();  // so the auto check-in and "I'm here" can't both count the same arrival
async function record(h) {
  if (recorded.has(h.id) || h.arrivals?.[uid]) return;
  recorded.add(h.id);
  const now = new Date();
  try { await updateDoc(doc(db, "hangouts", h.id), { [`arrivals.${uid}`]: now.toISOString() }); }
  catch (e) { recorded.delete(h.id); throw e; }
  const alert = h.alerts?.[uid], travel = h.travel?.[uid];
  const habit = { id: h.id, late: Math.round(minutesLate(h, now) * 10) / 10 };
  if (alert && typeof travel === "number") habit.delay = Math.round(((now - new Date(alert)) / 6e4 - travel) * 10) / 10;
  await setDoc(doc(db, "users", uid), { habits: arrayUnion(habit) }, { merge: true }).catch(() => {});
  window.dispatchEvent(new CustomEvent("checked-in", { detail: { h, late: habit.late } }));  // the group chat announces it
}

async function checkIn(button) {
  const h = hangouts.find(x => x.id === button.dataset.checkin);
  if (!h) return;
  const reset = text => { button.textContent = text; setTimeout(() => (button.innerHTML = `${icon("map-pin-check-inside")} I'm here`), 3500); };
  button.textContent = "Finding you…";
  try {
    // reuse the auto check-in's latest location if it's fresh; otherwise ask for one
    const here = lastFix && Date.now() - lastFix.at < 60000 ? lastFix.here : await new Promise((ok, no) =>
      navigator.geolocation.getCurrentPosition(p => ok([p.coords.latitude, p.coords.longitude]), no, { enableHighAccuracy: true, timeout: 10000 }));
    const away = metersBetween(here, h.venue);
    if (away > TAP_NEAR_M) return reset(`You're ${away >= 1000 ? (away / 1000).toFixed(1) + " km" : Math.round(away) + " m"} away`);
    await record(h);
  } catch (e) {
    reset(e.code === 1 ? "Allow location to check in" : "Couldn't check in");
  }
}
document.addEventListener("click", e => {
  const b = e.target.closest("[data-checkin]");
  if (b) checkIn(b);
});

// while a hangout is about to start, check you in automatically when you arrive
function autoCheckIn() {
  const waiting = () => hangouts.filter(h => checkInOpen(h) && h.venue && !h.arrivals?.[uid]);
  if (!uid || !navigator.geolocation || !waiting().length) {
    if (watch !== null) navigator.geolocation.clearWatch(watch);
    watch = null;
    return;
  }
  if (watch !== null) return;
  watch = navigator.geolocation.watchPosition(pos => {
    const here = [pos.coords.latitude, pos.coords.longitude];
    lastFix = { here, at: Date.now() };
    waiting().filter(h => metersBetween(here, h.venue) <= AUTO_NEAR_M).forEach(h => record(h).catch(() => {}));
  }, () => {}, { enableHighAccuracy: true, maximumAge: 30000 });
}
setInterval(autoCheckIn, 60000);
function checkNow() {
  const waiting = hangouts.filter(h => checkInOpen(h) && h.venue && !h.arrivals?.[uid]);
  if (!uid || !navigator.geolocation || !waiting.length) return;
  navigator.geolocation.getCurrentPosition(pos => {
    const here = [pos.coords.latitude, pos.coords.longitude];
    lastFix = { here, at: Date.now() };
    waiting.filter(h => !h.arrivals?.[uid] && metersBetween(here, h.venue) <= AUTO_NEAR_M).forEach(h => record(h).catch(() => {}));
  }, () => {}, { enableHighAccuracy: true, maximumAge: 30000, timeout: 15000 });
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) { autoCheckIn(); checkNow(); } });  // a hangout's check-in window can open while the page is sitting there

// friends.js calls this whenever your hangouts change
export function leaderboardHangouts(list) {
  hangouts = list;
  autoCheckIn();
  if (!$("board").hidden) render();
}

// ---------- the board ----------
// Everyone's check-ins, from two places that update live: each person's profile (every hangout they've checked in to,
// even ones you weren't at) and the arrivals on your own hangouts (so a friend shows up the moment they arrive)
function friendsBoard() {
  const people = window.myFriends || [];  // you ("You") + everyone who accepted
  const byId = new Map(people.map(p => [p.user_id, { ...p, seen: new Map((p.checkins || []).map(c => [c.id, c.late])), just: null }]));
  for (const h of [...hangouts].sort((a, b) => a.start.localeCompare(b.start))) {
    for (const [who, t] of Object.entries(h.arrivals || {})) {
      const p = byId.get(who);
      if (!p) continue;
      p.seen.set(h.id, minutesLate(h, t));
      if (Date.now() - new Date(t) < JUST_MS && (!p.just || t > p.just.at)) p.just = { at: t, late: minutesLate(h, t), where: h.venueName || h.title };
    }
  }
  return [...byId.values()].map(p => {
    p.lates = [...p.seen.values()];
    const n = p.lates.length, avg = n ? p.lates.reduce((a, b) => a + b, 0) / n : 0;
    const trend = n >= 6 ? mean(p.lates.slice(-3)) - mean(p.lates.slice(-6, -3)) : 0;
    return { user_id: p.user_id, name: p.name, photo: p.photo, hangouts: n, on_time: p.lates.filter(m => m <= LATE_AFTER_MIN).length,
             avg_late_min: avg, trend_min: trend, just: p.just };
  }).sort((a, b) => (!!b.hangouts - !!a.hangouts) || (b.on_time / (b.hangouts || 1) - a.on_time / (a.hangouts || 1)) || a.avg_late_min - b.avg_late_min);
}
const mean = xs => xs.reduce((a, b) => a + b, 0) / xs.length;

function face(p, i) {
  const src = p.photo || `https://api.dicebear.com/9.x/avataaars/svg?seed=${encodeURIComponent(p.user_id)}&backgroundColor=${COLORS[i % COLORS.length].slice(1)}`;
  return `<div class="avatar" style="--c:${COLORS[i % COLORS.length]}"><span>${esc((p.name || "?").slice(0, 2).toUpperCase())}</span>` +
         `<img src="${esc(src)}" alt="" onerror="this.remove()"></div>`;
}

function rows(board) {
  const ranked = board.filter(b => b.hangouts);
  return board.map((b, i) => {
    if (!b.hangouts) return `<div class="rank-row quiet"><div class="rank">·</div>${face(b, i)}
      <div class="who"><b>${esc(b.name)}</b><small>No check-ins yet</small></div></div>`;
    const pct = Math.round(100 * b.on_time / b.hangouts), last = i === ranked.length - 1 && ranked.length > 1;
    const badge = i === 0 && pct >= 50 ? `${icon("crown")} Most on time` : last && pct < 50 ? `${icon("turtle")} Always “omw”`
      : b.trend_min < -1 ? `${icon("trending-up")} Getting better` : b.trend_min > 1 ? `${icon("trending-down")} Slipping lately` : "";
    const usually = b.avg_late_min < -1 ? `usually ${Math.round(-b.avg_late_min)} min early`
      : b.avg_late_min <= 1 ? "usually right on time" : `usually ${Math.round(b.avg_late_min)} min late`;
    return `<div class="rank-row ${i === 0 ? "first" : ""}"><div class="rank ${i < 3 ? `r${i + 1}` : ""}">${i + 1}</div>${face(b, i)}
      <div class="who"><b>${esc(b.name)}</b><small>On time ${b.on_time} of ${b.hangouts} · ${usually}</small>
        ${b.just ? `<small class="just">${icon("map-pin")} Just arrived${b.just.where ? ` at ${esc(b.just.where)}` : ""} · ${lateText(b.just.late)}</small>` : ""}
        ${badge ? `<span class="badge">${badge}</span>` : ""}</div>
      <div class="pct"><b>${pct}%</b><small>on time</small></div></div>`;
  }).join("");
}

function render() {
  const board = friendsBoard();
  $("boardList").innerHTML = board.some(b => b.hangouts) ? rows(board)
    : `<div class="nobody">No check-ins yet. When anyone gets to a hangout, omw checks them in automatically and they show up here.</div>`;
  $("boardNote").textContent = `Ranked by how often each person arrives within ${LATE_AFTER_MIN} minutes of the start. `
    + "Updates live: omw checks people in automatically when they get there (with omw open), or they can tap “I'm here”.";
}

$("boardBtn").onclick = () => { $("board").hidden = false; render(); };
window.addEventListener("friends-changed", () => { if (!$("board").hidden) render(); });  // someone checked in somewhere
$("boardClose").onclick = () => ($("board").hidden = true);
$("board").onclick = e => { if (e.target.id === "board") $("board").hidden = true; };

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => { uid = u?.uid || null; hangouts = []; autoCheckIn(); });
}
