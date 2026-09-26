// Group chat for each hangout, only for the people going. omw posts in it by itself too:
//   📍 "Peggy arrived · 2 min early"   when someone checks in (automatically once they're within 150 m, or "I'm here")
//   ⏰ "Peggy is running late · 1.2 km away"   if someone isn't there 5 minutes after the start
// New messages pop up in omw, and as phone/computer notifications if you allow them.
// Stored at hangouts/{id}/messages/{auto id} = { from, name, text, kind, at }.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, collection, addDoc, onSnapshot } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const LATE_AFTER_MIN = 5;
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const time = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const store = { get: k => { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
                set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } } };

let db, me = null, myName = "", hangouts = [], listening = {}, messages = {}, openId = null, loadedAt = Date.now();

const endOf = h => new Date(h.start).getTime() + (h.durationMin || 120) * 6e4;
const chatOpenFor = h => Date.now() < endOf(h) + 24 * 36e5;  // chats stay live until a day after the hangout
const seen = id => store.get(`chatSeen:${me?.uid}:${id}`) || 0;
export const unreadCount = id => (messages[id] || []).filter(m => m.from !== me?.uid && new Date(m.at) > seen(id)).length;

function send(h, text, kind = "text") {
  return addDoc(collection(db, "hangouts", h.id, "messages"), { from: me.uid, name: myName, text: String(text).slice(0, 500), kind,
                                                               at: new Date().toISOString() });
}

// ---------- listening to every chat you're in ----------
export function chatHangouts(list, name) {
  hangouts = list; myName = name || myName;
  const live = new Set(list.filter(chatOpenFor).map(h => h.id));
  for (const id of Object.keys(listening)) if (!live.has(id)) { listening[id](); delete listening[id]; }
  for (const id of live) {
    if (listening[id]) continue;
    listening[id] = onSnapshot(collection(db, "hangouts", id, "messages"), s => {
      const before = new Set((messages[id] || []).map(m => m.id));
      messages[id] = s.docs.map(d => ({ ...d.data(), id: d.id })).sort((a, b) => a.at.localeCompare(b.at));
      // tell you about new ones from other people
      messages[id].filter(m => !before.has(m.id) && m.from !== me.uid && new Date(m.at) > loadedAt).forEach(m => notify(id, m));
      if (openId === id) renderChat();
      window.dispatchEvent(new Event("chat-changed"));
    }, () => {});
  }
}

function notify(id, m) {
  const h = hangouts.find(x => x.id === id);
  if (!h || (openId === id && !document.hidden)) return;
  const text = m.kind === "text" ? `${m.name}: ${m.text}` : `${m.name} ${m.text}`;
  window.toast?.({ user_id: m.from, name: m.name, photo: window.myFriends?.find(p => p.user_id === m.from)?.photo || "" },
                 `<b>${esc(h.title)}</b><br>${esc(text)}`, m.kind === "late");
  if ("Notification" in window && Notification.permission === "granted" && (document.hidden || !document.hasFocus())) {
    const n = new Notification(h.title, { body: text, tag: `${id}:${m.id}`, icon: "/static/logo.svg" });
    n.onclick = () => { window.focus(); openChat(id); n.close(); };
  }
}

// ---------- automatic messages ----------
// you checked in (leaderboard.js): tell the group
window.addEventListener("checked-in", e => {
  const { h, late } = e.detail;
  const how = late < -1 ? `${Math.round(-late)} min early` : late <= LATE_AFTER_MIN ? "right on time" : `${Math.round(late)} min late`;
  send(h, `arrived at ${h.venueName || "the spot"} · ${how} 🎉`, "arrived").catch(() => {});
});

// not there 5 minutes after the start? your own omw lets the group know how far away you are (once per hangout)
function lateCheck() {
  if (!me) return;
  for (const h of hangouts) {
    const mins = (Date.now() - new Date(h.start)) / 6e4, key = `lateSent:${me.uid}:${h.id}`;
    if (mins < LATE_AFTER_MIN || mins > 60 || h.arrivals?.[me.uid] || store.get(key)) continue;
    store.set(key, true);
    const fix = window.myFix, away = fix && h.venue ? distance(fix.here, h.venue) : null;
    send(h, `is running late${away != null ? ` · ${away < 1000 ? Math.round(away) + " m" : (away / 1000).toFixed(1) + " km"} away` : ""}`, "late").catch(() => {});
  }
}
setInterval(lateCheck, 30000);
function distance([a, b], [c, d]) {
  const r = Math.PI / 180, x = Math.sin((c - a) * r / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin((d - b) * r / 2) ** 2;
  return 12742000 * Math.asin(Math.sqrt(x));
}

// ---------- the chat panel ----------
function openChat(id) {
  openId = id;
  $("chat").hidden = false;
  renderChat();
  setTimeout(() => $("chatInput").focus(), 50);
}
window.openChat = openChat;

function renderChat() {
  const h = hangouts.find(x => x.id === openId);
  if (!h) { $("chat").hidden = true; openId = null; return; }
  const list = messages[openId] || [];
  store.set(`chatSeen:${me.uid}:${openId}`, Date.now());
  window.dispatchEvent(new Event("chat-changed"));
  $("chatTitle").textContent = `💬 ${h.title}`;
  $("chatSub").textContent = `${new Date(h.start).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" })} · ` +
    h.attendees.map(u => u === me.uid ? "You" : h.names?.[u] || "Friend").join(", ");
  const canAsk = "Notification" in window && Notification.permission === "default";
  $("chatNotify").innerHTML = canAsk ? `<button class="wide" id="notifyBtn">🔔 Notify me when people arrive or message</button>` : "";
  if (canAsk) $("notifyBtn").onclick = async () => { await Notification.requestPermission(); renderChat(); };
  $("chatList").innerHTML = list.length ? list.map(m => m.kind === "text"
      ? `<div class="msg ${m.from === me.uid ? "mine" : ""}">${m.from === me.uid ? "" : `<small>${esc(m.name)}</small>`}<p>${esc(m.text)}</p><time>${time(m.at)}</time></div>`
      : `<div class="msg-auto ${m.kind}">${m.kind === "arrived" ? "📍" : m.kind === "late" ? "⏰" : "🏃"} <b>${m.from === me.uid ? "You" : esc(m.name)}</b> ${esc(m.from === me.uid ? m.text.replace(/^is /, "are ") : m.text)} <time>${time(m.at)}</time></div>`).join("")
    : `<div class="nobody">No messages yet. omw posts here when people are on their way, running late or arrive.</div>`;
  $("chatList").scrollTop = $("chatList").scrollHeight;
}

$("chatForm").onsubmit = e => {
  e.preventDefault();
  const h = hangouts.find(x => x.id === openId), text = $("chatInput").value.trim();
  if (!h || !text) return;
  $("chatInput").value = "";
  send(h, text).catch(err => alert(`Couldn't send: ${err.message}`));
};
$("chatQuick").onclick = e => {
  const b = e.target.closest("[data-quick]"), h = hangouts.find(x => x.id === openId);
  if (!b || !h) return;
  if (b.dataset.quick === "omw") send(h, `is on the way${h.travel?.[me.uid] ? ` · there in ~${Math.round(h.travel[me.uid])} min` : ""}`, "omw");
  if (b.dataset.quick === "late") send(h, "is running late", "late");
};
$("chatClose").onclick = () => { $("chat").hidden = true; openId = null; };
$("chat").onclick = e => { if (e.target.id === "chat") { $("chat").hidden = true; openId = null; } };

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    me = u; loadedAt = Date.now(); messages = {}; openId = null;
    Object.values(listening).forEach(stop => stop()); listening = {};
  });
}
