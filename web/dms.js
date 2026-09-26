// Chats: DMs with a friend and group chats, all in one inbox (plus every hangout's group chat), like Instagram or Snapchat.
// Open it with the chat button at the top right, or swipe left on the main screen; swipe right to go back.
//
// Firestore layout
//   chats/{id}              { members: [uid], group, title, createdBy, names: {uid: name}, photos: {uid: url},
//                             last: { text, from, name, at }, read: {uid: iso time you last looked} }
//                           a DM's id is dm_<uid>_<uid> (sorted), so the two of you always land in the same one
//   chats/{id}/messages/{auto id}   { from, name, text, at, kind? }  (kind "system" = "Priya created the group")
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, collection, doc, getDoc, setDoc, addDoc, updateDoc, onSnapshot, query, where, arrayRemove, arrayUnion }
  from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const ic = (n, c = "") => window.icon ? window.icon(n, c) : "";
const phone = () => matchMedia("(max-width: 860px)").matches;
const safe = u => /^(https:|data:image\/)/.test(u || "") ? u : "";

let db, me = null, myName = "", chats = {}, stopInbox = null, openCid = null, stopMsgs = null, msgs = [], loadedAt = Date.now();
let view = "list";  // list | new | info

// ---------- who's who ----------
const friendsList = () => (window.myFriends || []).filter(p => !p.isMe);
const friend = uid => friendsList().find(p => p.user_id === uid);
const nameIn = (c, uid) => uid === me?.uid ? "You" : friend(uid)?.name || c.names?.[uid] || "Friend";
const photoIn = (c, uid) => friend(uid)?.photo || c.photos?.[uid] || "";
const others = c => c.members.filter(u => u !== me.uid);
const titleOf = c => c.group ? (c.title || others(c).map(u => nameIn(c, u)).join(", ") || "Just you")
                             : nameIn(c, others(c)[0]);
const unread = c => !!c.last && c.last.from !== me.uid && (!c.read?.[me.uid] || c.last.at > c.read[me.uid]);

function face(name, photo, cls = "") {
  return safe(photo) ? `<div class="avatar ${cls}" style="background-image:url('${esc(safe(photo))}')"></div>`
                     : `<div class="avatar ${cls}" style="--c:#ffb000"><span>${esc((name || "?").slice(0, 2).toUpperCase())}</span></div>`;
}
function chatFace(c) {
  if (!c.group) { const u = others(c)[0]; return face(nameIn(c, u), photoIn(c, u), "ib-face"); }
  const [a, b] = others(c);  // two friends' faces, overlapping, like a group chat in Instagram
  return `<div class="ib-stack">${face(nameIn(c, a), photoIn(c, a), "ib-mini")}${b ? face(nameIn(c, b), photoIn(c, b), "ib-mini") : face(myName, "", "ib-mini")}</div>`;
}
function ago(iso) {
  const m = (Date.now() - new Date(iso)) / 6e4;
  if (m < 1) return "now";
  if (m < 60) return `${Math.floor(m)}m`;
  if (m < 1440) return `${Math.floor(m / 60)}h`;
  if (m < 10080) return `${Math.floor(m / 1440)}d`;
  return new Date(iso).toLocaleDateString([], { month: "short", day: "numeric" });
}

// ---------- the inbox ----------
function rows() {
  const mine = Object.values(chats).map(c => ({
    key: c.id, title: titleOf(c), face: chatFace(c), at: c.last?.at || c.createdAt || "", unread: unread(c),
    line: c.last ? `${c.last.from === me.uid ? "You: " : c.group && c.last.kind !== "system" ? `${esc(c.last.name || "")}: ` : ""}${esc(c.last.text)}`
                 : c.group ? "New group" : "Say hi!",
    open: `data-open="${esc(c.id)}"` }));
  // every hangout you're going to has its own group chat too (chat.js)
  const plans = (window.hangoutChatList?.() || []).map(h => ({
    key: "h:" + h.id, title: h.title, at: h.last?.at || "", unread: h.unread > 0,
    face: `<div class="ib-face ib-plan">${ic("calendar-days")}</div>`,
    line: h.last ? `${h.last.from === me.uid ? "You" : esc(h.last.name)}${h.last.kind === "text" ? ": " : " "}${esc(h.last.text)}` : "Hangout chat",
    open: `data-hangout="${esc(h.id)}"` }));
  return [...mine, ...plans].sort((a, b) => String(b.at).localeCompare(String(a.at)));
}

function renderInbox() {
  if (!me) return;
  const list = rows();
  const n = list.filter(r => r.unread).length;
  $("inboxBadge").hidden = !n; $("inboxBadge").textContent = n;
  if (view === "new") return renderNew();
  if (view === "info") return renderInfo();
  const q = ($("ibSearch")?.value || "").trim().toLowerCase();
  const shown = q ? list.filter(r => r.title.toLowerCase().includes(q)) : list;
  // friends you haven't messaged yet, in a row at the top (tap one to start a DM)
  const talked = new Set(Object.values(chats).filter(c => !c.group).map(c => others(c)[0]));
  const fresh = friendsList().filter(f => !talked.has(f.user_id));
  $("ibBody").innerHTML = `
    ${fresh.length && !q ? `<div class="ib-fresh">${fresh.map(f => `<button data-dm="${esc(f.user_id)}">${face(f.name, f.photo, "ib-face")}<small>${esc(f.name.split(" ")[0])}</small></button>`).join("")}</div>` : ""}
    ${shown.length ? shown.map(r => `<button class="ib-row ${r.unread ? "ib-unread" : ""}" ${r.open}>${r.face}
        <div class="ib-text"><b>${esc(r.title)}</b><small>${r.line}</small></div>
        <div class="ib-meta"><time>${r.at ? ago(r.at) : ""}</time>${r.unread ? `<i class="ib-dot"></i>` : ""}</div></button>`).join("")
      : `<div class="nobody">${q ? "No chats match that." : friendsList().length ? "No chats yet. Tap a friend above, or the pencil to start a group." : "Add friends first (tap your picture, top left), then chat with them here."}</div>`}`;
}

// ---------- starting a chat ----------
let picked = new Set();
function renderNew() {
  const fs = friendsList();
  $("ibBody").innerHTML = `
    <div class="ib-sub">${picked.size > 1 ? "New group" : "New message"}</div>
    ${picked.size > 1 ? `<input class="ib-name" id="ibGroupName" maxlength="40" placeholder="Group name (optional)" value="${esc($("ibGroupName")?.value || "")}">` : ""}
    ${fs.length ? fs.map(f => `<button class="ib-row pick ${picked.has(f.user_id) ? "on" : ""}" data-pick="${esc(f.user_id)}">${face(f.name, f.photo, "ib-face")}
        <div class="ib-text"><b>${esc(f.name)}</b></div><i class="ib-check">${picked.has(f.user_id) ? ic("check") : ""}</i></button>`).join("")
      : `<div class="nobody">Add friends first (tap your picture, top left).</div>`}
    <div class="ib-go"><button class="wide dark" id="ibStart" ${picked.size ? "" : "disabled"}>${picked.size > 1 ? `Create group (${picked.size + 1})` : "Chat"}</button></div>`;
}

async function openDm(uid) {
  const f = friend(uid), id = "dm_" + [me.uid, uid].sort().join("_"), ref = doc(db, "chats", id);
  const snap = await getDoc(ref);
  if (!snap.exists()) {
    await setDoc(ref, { members: [me.uid, uid].sort(), group: false, createdBy: me.uid, createdAt: new Date().toISOString(),
                        names: { [me.uid]: myName, [uid]: f?.name || "Friend" }, photos: {}, read: {} });
  }
  chats[id] ||= { id, members: [me.uid, uid], group: false, names: { [uid]: f?.name }, read: {} };
  openConvo(id);
}

async function createGroup(uids, title) {
  const at = new Date().toISOString(), names = { [me.uid]: myName };
  uids.forEach(u => (names[u] = friend(u)?.name || "Friend"));
  const ref = await addDoc(collection(db, "chats"), {
    members: [me.uid, ...uids], group: true, title: title.slice(0, 40), createdBy: me.uid, createdAt: at, names, photos: {},
    last: { text: `${myName} created the group`, from: me.uid, name: myName, at, kind: "system" }, read: { [me.uid]: at } });
  await addDoc(collection(db, "chats", ref.id, "messages"), { from: me.uid, name: myName, text: `${myName} created the group`, at, kind: "system" });
  chats[ref.id] ||= { id: ref.id, members: [me.uid, ...uids], group: true, title, names, read: {} };
  openConvo(ref.id);
}

// ---------- one conversation ----------
function openConvo(id) {
  openCid = id;
  msgs = [];
  stopMsgs?.();
  stopMsgs = onSnapshot(collection(db, "chats", id, "messages"), s => {
    msgs = s.docs.map(d => ({ ...d.data(), id: d.id })).sort((a, b) => String(a.at).localeCompare(String(b.at)));
    renderConvo(); markRead();
  }, () => {});
  $("inbox").classList.add("in-convo");
  renderConvo();
  if (!phone()) setTimeout(() => $("cvInput").focus(), 300);
}
function closeConvo() {
  stopMsgs?.(); stopMsgs = null; openCid = null;
  $("inbox").classList.remove("in-convo");
  renderInbox();
}
function markRead() {
  const c = chats[openCid];
  if (!c?.last || !unread(c)) return;
  const at = new Date().toISOString();
  c.read = { ...c.read, [me.uid]: at };
  updateDoc(doc(db, "chats", c.id), { [`read.${me.uid}`]: at }).catch(() => {});
  renderInbox();
}

function renderConvo() {
  const c = chats[openCid];
  if (!c) return;
  $("cvHead").innerHTML = `${chatFace(c)}<div class="ib-text"><b>${esc(titleOf(c))}</b>
    <small>${c.group ? `${c.members.length} people · tap for info` : "Friend"}</small></div>`;
  const keep = $("cvList").scrollHeight - $("cvList").scrollTop - $("cvList").clientHeight < 60;
  $("cvList").innerHTML = msgs.length ? msgs.map((m, i) => {
    if (m.kind === "system") return `<div class="msg-auto sys">${esc(m.text)}</div>`;
    const mine = m.from === me.uid, prev = msgs[i - 1];
    const showName = c.group && !mine && (prev?.from !== m.from || prev?.kind === "system");
    return `<div class="msg ${mine ? "mine" : ""}">${showName ? `<small>${esc(nameIn(c, m.from) === "Friend" ? m.name : nameIn(c, m.from))}</small>` : ""}<p>${esc(m.text)}</p>
      <time>${new Date(m.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</time></div>`;
  }).join("") : `<div class="nobody">${c.group ? "Say hi to the group!" : `This is the start of your chat with ${esc(titleOf(c))}.`}</div>`;
  if (keep || !msgs.length) $("cvList").scrollTop = $("cvList").scrollHeight;
}

async function send(text) {
  const c = chats[openCid];
  if (!c) return;
  const at = new Date().toISOString(), m = { from: me.uid, name: myName, text: text.slice(0, 1000), at };
  await addDoc(collection(db, "chats", c.id, "messages"), m);
  c.last = m; c.read = { ...c.read, [me.uid]: at };
  await updateDoc(doc(db, "chats", c.id), { last: m, [`read.${me.uid}`]: at });
}

// ---------- group info: who's in it, rename, add people, leave ----------
function renderInfo() {
  const c = chats[openCid];
  if (!c) { view = "list"; return renderInbox(); }
  const addable = friendsList().filter(f => !c.members.includes(f.user_id));
  $("ibBody").innerHTML = `
    <div class="ib-sub">Group name</div>
    <form class="ib-rename" id="ibRename"><input class="ib-name" id="ibTitle" maxlength="40" value="${esc(c.title || "")}" placeholder="${esc(titleOf({ ...c, title: "" }))}">
      <button class="mini dark">Save</button></form>
    <div class="ib-sub">${c.members.length} people</div>
    ${c.members.map(u => `<div class="ib-row static">${face(nameIn(c, u), photoIn(c, u), "ib-face")}<div class="ib-text"><b>${esc(nameIn(c, u))}</b></div></div>`).join("")}
    ${addable.length ? `<div class="ib-sub">Add people</div>${addable.map(f => `<button class="ib-row" data-add="${esc(f.user_id)}">${face(f.name, f.photo, "ib-face")}
        <div class="ib-text"><b>${esc(f.name)}</b></div><i class="ib-check">${ic("plus")}</i></button>`).join("")}` : ""}
    <div class="ib-go"><button class="wide danger-btn" id="ibLeave">${ic("log-out")} Leave group</button></div>`;
  $("ibRename").onsubmit = e => {
    e.preventDefault();
    const title = $("ibTitle").value.trim();
    c.title = title;
    updateDoc(doc(db, "chats", c.id), { title }).catch(err => alert(`Couldn't rename: ${err.message}`));
    systemNote(c, title ? `${myName} named the group "${title}"` : `${myName} removed the group name`);
    view = "list"; $("inbox").classList.add("in-convo"); renderConvo();
  };
}
function systemNote(c, text) {
  const at = new Date().toISOString(), m = { from: me.uid, name: myName, text, at, kind: "system" };
  addDoc(collection(db, "chats", c.id, "messages"), m).then(() => updateDoc(doc(db, "chats", c.id), { last: m })).catch(() => {});
}

// ---------- opening and closing the whole thing ----------
function setView(v) {
  view = v;
  $("ibTitleBar").textContent = v === "new" ? "New chat" : v === "info" ? "Group info" : "Chats";
  $("ibNew").hidden = v !== "list";
  $("ibSearchWrap").hidden = v !== "list";
  renderInbox();
}
function openInbox() {
  if (!me) return;
  $("inbox").hidden = false;
  requestAnimationFrame(() => { $("inbox").style.transform = ""; $("inbox").classList.add("ib-open"); });
  setView("list");
}
function closeInbox() {
  $("inbox").style.transform = "";
  $("inbox").classList.remove("ib-open");
  closeConvo();
}
window.openInbox = openInbox;
// "Back": out of a conversation, out of new chat / group info, or out of Chats altogether
function back() {
  if (view === "info") { view = "list"; setView("list"); $("inbox").classList.add("in-convo"); return renderConvo(); }
  if ($("inbox").classList.contains("in-convo")) return closeConvo();
  if (view !== "list") return setView("list");
  closeInbox();
}

$("inboxBtn").onclick = () => ($("inbox").classList.contains("ib-open") ? closeInbox() : openInbox());
$("ibBack").onclick = back;
$("cvBack").onclick = back;
$("ibNew").onclick = () => { picked = new Set(); setView("new"); };
$("ibSearch").oninput = () => renderInbox();
$("cvHead").onclick = () => { if (chats[openCid]?.group) { $("inbox").classList.remove("in-convo"); setView("info"); } };
$("ibBody").onclick = async e => {
  const b = e.target.closest("button");
  if (!b || b.disabled) return;
  try {
    if (b.dataset.open) return openConvo(b.dataset.open);
    if (b.dataset.hangout) return window.openChat?.(b.dataset.hangout);
    if (b.dataset.dm) return await openDm(b.dataset.dm);
    if (b.dataset.pick) { picked.has(b.dataset.pick) ? picked.delete(b.dataset.pick) : picked.add(b.dataset.pick); return renderNew(); }
    if (b.id === "ibStart") {
      b.disabled = true;
      const uids = [...picked], title = $("ibGroupName")?.value.trim() || "";
      setView("list");
      return uids.length === 1 ? await openDm(uids[0]) : await createGroup(uids, title);
    }
    const c = chats[openCid];
    if (b.dataset.add && c) {
      const f = friend(b.dataset.add);
      await updateDoc(doc(db, "chats", c.id), { members: arrayUnion(b.dataset.add), [`names.${b.dataset.add}`]: f?.name || "Friend" });
      c.members = [...new Set([...c.members, b.dataset.add])];
      systemNote(c, `${myName} added ${f?.name || "a friend"}`);
      return renderInfo();
    }
    if (b.id === "ibLeave" && c && confirm(`Leave ${titleOf(c)}? You won't get its messages anymore.`)) {
      systemNote(c, `${myName} left the group`);
      await updateDoc(doc(db, "chats", c.id), { members: arrayRemove(me.uid) });
      delete chats[c.id];
      closeConvo(); setView("list");
    }
  } catch (err) { alert(`Couldn't do that: ${err.message}`); renderInbox(); }
};
$("cvForm").onsubmit = e => {
  e.preventDefault();
  const text = $("cvInput").value.trim();
  if (!text) return;
  $("cvInput").value = "";
  send(text).catch(err => alert(`Couldn't send: ${err.message}`));
};
addEventListener("keydown", e => { if (e.key === "Escape" && $("inbox").classList.contains("ib-open")) back(); });
window.addEventListener("friends-changed", () => { myName = window.myFriends?.find(p => p.isMe)?.realName || myName; renderInbox(); if (openCid) renderConvo(); });
window.addEventListener("chat-changed", () => renderInbox());

// ---------- swiping between screens, like Instagram / Snapchat ----------
// Main screen: swipe left for Chats (from the right), swipe right for My plans + leaderboard (from the left).
// On those screens, swipe the other way to go back. Swipes start on the planner, the top bar, or a thin strip at either
// edge of the screen (the strips keep the map from panning instead).
const sideScroller = el => el.closest(".types, .week, .friends, .cc-tabs, .ib-fresh, .page-tabs, input, textarea, select, .modes, .cal-menu, .plan-actions");
const pageOpen = () => [$("plans"), $("board")].find(d => !d.hidden);
const pageCard = () => pageOpen()?.querySelector(".drawer-card");
let sw = null;
function swipeStart(e, mode) {
  if (!phone() || e.touches.length > 1 || !me) return;
  const t = e.touches[0];
  sw = { mode, x: t.clientX, y: t.clientY, dx: 0, dir: null };
}
function swipeMove(e) {
  if (!sw) return;
  const t = e.touches[0], dx = t.clientX - sw.x, dy = t.clientY - sw.y, W = innerWidth;
  if (!sw.dir) {
    if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
    sw.dir = Math.abs(dx) > Math.abs(dy) * 1.3 ? "x" : "y";
    if (sw.dir === "y") { sw = null; return; }
    if (sw.mode === "main") {  // which way decides where you're going
      if (dx < 0) sw.mode = "chats";
      else { sw.mode = "plans"; $("plans").classList.add("instant"); $("plansBtn").click(); }
    }
  }
  sw.dx = dx;
  const drag = (el, x) => { el.classList.add("dragging"); el.style.transform = `translateX(${x}px)`; };
  if (sw.mode === "chats" && dx < 0) { e.preventDefault(); $("inbox").hidden = false; drag($("inbox"), Math.max(0, W + dx)); }
  if (sw.mode === "plans") { e.preventDefault(); const c = pageCard(); if (c) drag(c, Math.min(0, -W + Math.max(0, dx))); }
  if (sw.mode === "convo" && dx > 0) { e.preventDefault(); drag($("convo"), dx); }
  if (sw.mode === "inbox" && dx > 0) { e.preventDefault(); drag($("inbox"), dx); }
  if (sw.mode === "page" && dx < 0) { e.preventDefault(); const c = pageCard(); if (c) drag(c, dx); }
}
// let a dragged screen glide the rest of the way (in or out), then tidy up
function settle(el, to, done) {
  el.classList.remove("dragging"); el.classList.add("settle");
  requestAnimationFrame(() => (el.style.transform = to));
  setTimeout(() => { el.classList.remove("settle"); el.style.transform = ""; done?.(); }, 260);
}
function swipeEnd() {
  if (!sw) return;
  const { mode, dx } = sw, W = innerWidth, far = Math.abs(dx) > W * 0.22;
  sw = null;
  for (const el of [$("inbox"), $("convo")]) { el.classList.remove("dragging"); el.style.transform = ""; }
  if (mode === "chats") { if (dx < 0 && far) openInbox(); }
  else if ((mode === "convo" || mode === "inbox") && dx > 0 && far) back();
  else if (mode === "plans") {
    const c = pageCard();
    if (c) far && dx > 0 ? settle(c, "translateX(0)") : settle(c, "translateX(-100%)", () => ($("plans").hidden = true));
  } else if (mode === "page") {
    const c = pageCard();
    if (c) dx < 0 && far ? settle(c, "translateX(-100%)", () => (pageOpen().hidden = true)) : settle(c, "translateX(0)");
  }
}
const onTouch = (el, start) => {
  el.addEventListener("touchstart", start, { passive: true });
  el.addEventListener("touchmove", swipeMove, { passive: false });
  el.addEventListener("touchend", swipeEnd);
  el.addEventListener("touchcancel", swipeEnd);
};
for (const el of [$("sheet"), document.querySelector(".topbar")])
  onTouch(el, e => { if (!$("inbox").classList.contains("ib-open") && !sideScroller(e.target)) swipeStart(e, "main"); });
onTouch($("chatEdge"), e => swipeStart(e, "chats"));
onTouch($("pageEdge"), e => { swipeStart(e, "main"); });
onTouch($("inbox"), e => { if (!e.target.closest("input, textarea, .ib-fresh")) swipeStart(e, $("inbox").classList.contains("in-convo") ? "convo" : "inbox"); });
for (const d of [$("plans"), $("board")]) {
  onTouch(d, e => { if (!sideScroller(e.target)) swipeStart(e, "page"); });
  // the "My plans | Leaderboard" switch at the top of that page
  d.querySelector(".page-tabs").onclick = e => {
    const b = e.target.closest("[data-page]");
    if (!b || b.classList.contains("on")) return;
    d.hidden = true;
    const to = $(b.dataset.page);
    to.classList.add("instant");
    $(b.dataset.page === "board" ? "boardBtn" : "plansBtn").click();
  };
  // tapping the top-bar buttons slides the page in; switching tabs or swiping doesn't replay that
  new MutationObserver(() => { if (d.hidden) d.classList.remove("instant"); }).observe(d, { attributes: true, attributeFilter: ["hidden"] });
}

// ---------- listening ----------
function notify(c) {
  const m = c.last;
  window.toast?.({ user_id: m.from, name: m.name, photo: photoIn(c, m.from) },
                 `<b>${esc(c.group ? titleOf(c) : m.name)}</b><br>${c.group ? `${esc(m.name)}: ` : ""}${esc(m.text)}`);
  if ("Notification" in window && Notification.permission === "granted" && (document.hidden || !document.hasFocus())) {
    const n = new Notification(c.group ? titleOf(c) : m.name, { body: c.group ? `${m.name}: ${m.text}` : m.text, tag: `${c.id}:${m.at}`,
                                                                icon: document.getElementById("favicon")?.href });
    n.onclick = () => { window.focus(); openInbox(); openConvo(c.id); n.close(); };
  }
}

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    stopInbox?.(); stopInbox = null; closeInbox(); chats = {}; me = u; loadedAt = Date.now();
    $("inboxBtn").parentElement.hidden = !u;
    if (!u) return;
    myName = u.displayName || (u.email || "friend").split("@")[0];
    stopInbox = onSnapshot(query(collection(db, "chats"), where("members", "array-contains", u.uid)), s => {
      const before = chats;
      chats = {};
      s.docs.forEach(d => (chats[d.id] = { ...d.data(), id: d.id }));
      for (const c of Object.values(chats)) {  // a new message from someone else, in a chat you're not looking at
        const was = before[c.id]?.last?.at;
        if (c.last && c.last.from !== me.uid && c.last.kind !== "system" && c.last.at !== was && new Date(c.last.at) > loadedAt && c.id !== openCid) notify(c);
      }
      renderInbox();
      if (openCid) { if (chats[openCid]) renderConvo(); else closeConvo(); }
    }, err => console.warn("chats:", err.message));
  });
}
