// Leaderboard: who's always on time, and who's always "omw". Built from check-ins: when you get to a hangout, omw records
// the time (automatically once you're within 150 m, or you tap "I'm here"). Only you and your friends are on your board.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, updateDoc } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const LATE_AFTER_MIN = 5;           // more than 5 minutes after the start counts as late
const AUTO_NEAR_M = 150, TAP_NEAR_M = 300;
const OPEN_BEFORE_MIN = 60, OPEN_AFTER_MIN = 120;  // when check-in is open, around the start time
const COLORS = ["#7b61ff", "#ff4f9a", "#ffb000", "#16c47f", "#1ea0ff", "#ff6a3d", "#00c2c7", "#a3d900"];
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const time = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

let db, uid = null, hangouts = [], watch = null, lastFix = null, demoGroups = null;

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
  if (t) return `<small class="arrived">✅ Arrived ${time(t)} · ${lateText(minutesLate(h, t))}</small>`;
  if (checkInOpen(h) && h.venue) return `<button class="mini yes checkin" data-checkin="${esc(h.id)}">📍 I'm here</button>`;
  return "";
}

const record = h => updateDoc(doc(db, "hangouts", h.id), { [`arrivals.${uid}`]: new Date().toISOString() });

async function checkIn(button) {
  const h = hangouts.find(x => x.id === button.dataset.checkin);
  if (!h) return;
  const reset = text => { button.textContent = text; setTimeout(() => (button.textContent = "📍 I'm here"), 3500); };
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
setInterval(autoCheckIn, 60000);  // a hangout's check-in window can open while the page is sitting there

// friends.js calls this whenever your hangouts change
export function leaderboardHangouts(list) {
  hangouts = list;
  autoCheckIn();
  if (!$("board").hidden && $("boardPick").value === "mine") render();
}

// ---------- the board ----------
function friendsBoard() {
  const people = window.myFriends || [];  // you ("You") + everyone who accepted
  const byId = new Map(people.map(p => [p.user_id, { ...p, lates: [] }]));
  for (const h of [...hangouts].sort((a, b) => a.start.localeCompare(b.start))) {
    for (const [who, t] of Object.entries(h.arrivals || {})) byId.get(who)?.lates.push(minutesLate(h, t));
  }
  return [...byId.values()].map(p => {
    const n = p.lates.length, avg = n ? p.lates.reduce((a, b) => a + b, 0) / n : 0;
    const trend = n >= 6 ? mean(p.lates.slice(-3)) - mean(p.lates.slice(-6, -3)) : 0;
    return { user_id: p.user_id, name: p.name, photo: p.photo, hangouts: n, on_time: p.lates.filter(m => m <= LATE_AFTER_MIN).length,
             avg_late_min: avg, trend_min: trend };
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
    const badge = i === 0 && pct >= 50 ? "👑 Most on time" : last && pct < 50 ? "🐢 Always “omw”"
      : b.trend_min < -1 ? "📈 Getting better" : b.trend_min > 1 ? "📉 Slipping lately" : "";
    const usually = b.avg_late_min < -1 ? `usually ${Math.round(-b.avg_late_min)} min early`
      : b.avg_late_min <= 1 ? "usually right on time" : `usually ${Math.round(b.avg_late_min)} min late`;
    return `<div class="rank-row ${i === 0 ? "first" : ""}"><div class="rank">${["🥇", "🥈", "🥉"][i] || i + 1}</div>${face(b, i)}
      <div class="who"><b>${esc(b.name)}</b><small>On time ${b.on_time} of ${b.hangouts} · ${usually}</small>
        ${badge ? `<span class="badge">${badge}</span>` : ""}</div>
      <div class="pct"><b>${pct}%</b><small>on time</small></div></div>`;
  }).join("");
}

async function render() {
  const pick = $("boardPick").value;
  if (pick === "mine") {
    const board = friendsBoard();
    $("boardList").innerHTML = board.length > 1 || board.some(b => b.hangouts) ? rows(board)
      : `<div class="nobody">Add friends and lock in a hangout. Everyone's arrivals will rank here.</div>`;
    $("boardNote").textContent = `Ranked by how often each person arrives within ${LATE_AFTER_MIN} minutes of the start. `
      + "omw checks you in automatically when you get there, or tap “I'm here”.";
  } else {
    $("boardList").innerHTML = `<div class="nobody">Loading…</div>`;
    const board = await (await fetch(`/leaderboard/demo?group_id=${pick}`)).json();
    if ($("boardPick").value !== pick) return;
    $("boardList").innerHTML = rows(board);
    $("boardNote").textContent = `From ${board.reduce((a, b) => a + b.hangouts, 0)} simulated arrivals: the same history the lateness model learned from.`;
  }
}

async function open() {
  if (!demoGroups) {
    const people = await (await fetch("/users")).json();
    demoGroups = [...new Set(people.map(p => p.group_id))].sort();
    $("boardPick").innerHTML = `<option value="mine">⭐ My friends</option>` +
      demoGroups.map(g => `<option value="${g}">👯 Demo group ${g + 1}</option>`).join("");
    // no real check-ins yet? start on a demo group so there's something to see
    if (!friendsBoard().some(b => b.hangouts)) $("boardPick").value = String(demoGroups[1] ?? demoGroups[0]);
  }
  $("board").hidden = false;
  render();
}

$("boardBtn").onclick = open;
$("boardClose").onclick = () => ($("board").hidden = true);
$("board").onclick = e => { if (e.target.id === "board") $("board").hidden = true; };
$("boardPick").onchange = render;

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => { uid = u?.uid || null; hangouts = []; autoCheckIn(); });
}