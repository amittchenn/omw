// Memories, like BeReal's: once everyone has arrived, one person takes a photo of the whole group. It's posted for everyone
// who went and lands on a calendar of your hangouts (Memories tab). Posted within 10 minutes of the last person arriving = "on time".
// Stored at memories/{hangout id} = { members, names, by, byName, photo (JPEG data URL), at, allHereAt, title, venueName, address, start }.
// Only the people who went can see it; only whoever posted it can retake or delete it; anyone can take it off their own calendar.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, collection, doc, query, where, onSnapshot, setDoc, updateDoc, deleteDoc, arrayRemove }
  from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const ON_TIME_MIN = 10;           // BeReal-style: post within this long of everyone arriving and it's on time
const PROMPT_FOR_H = 6;           // keep asking for the photo this long after everyone got there
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const store = { get: k => { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
                set: (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } } };

let db, me = null, memories = {}, stop = null, snapFor = null, draft = null, viewing = null, openWhenSaved = null;

const allHere = h => h?.attendees?.length > 0 && h.attendees.every(u => h.arrivals?.[u]);
const allHereAt = h => Math.max(...h.attendees.map(u => new Date(h.arrivals[u]).getTime()));
const lateText = m => {
  const mins = Math.round((new Date(m.at) - new Date(m.allHereAt)) / 6e4);
  if (mins <= ON_TIME_MIN) return "";
  return mins < 60 ? `${mins} min late` : mins < 48 * 60 ? `${Math.round(mins / 60)} hr${mins >= 90 ? "s" : ""} late` : `${Math.round(mins / 1440)} days late`;
};
const onTimeBadge = m => lateText(m) ? `<span class="mem-late">${esc(lateText(m))}</span>` : `<span class="mem-ontime">${icon("zap")} On time</span>`;
const nameOf = (m, u) => u === me?.uid ? "You" : m.names?.[u] || "Friend";
const hangoutsList = () => window.myHangouts || [];

// ---------- the photo prompt: on the map once everyone's there, and on the hangout's card ----------
function waiting() {  // hangouts where everyone has arrived, no photo yet, and it's still the moment
  return hangoutsList().filter(h => allHere(h) && !memories[h.id] && Date.now() - allHereAt(h) < PROMPT_FOR_H * 36e5
                                 && !store.get(`memSkip:${me?.uid}:${h.id}`));
}
function renderPrompt() {
  const h = waiting()[0], el = $("snapPrompt");
  if (!el) return;
  el.hidden = !h;
  if (!h) return;
  const left = ON_TIME_MIN - (Date.now() - allHereAt(h)) / 6e4;
  el.innerHTML = `<div class="snap-head">${icon("camera")}<span><b>Everyone's at ${esc(h.venueName || "the spot")}!</b>
      <small>${left > 0 ? `Take the group photo · ${Math.ceil(left)} min left to post on time` : "Add a group photo to your memories"}</small></span></div>
    <div class="snap-btns"><button class="snap-cam" data-snap="${esc(h.id)}">${icon("camera")} Take photo</button>
      <button class="snap-up" data-snap-upload="${esc(h.id)}">${icon("image")} Upload</button></div>
    <button class="snap-x" data-snap-skip="${esc(h.id)}" title="Not now">${icon("x")}</button>`;
}
setInterval(renderPrompt, 30000);

// the bit inside a hangout's card in My plans
window.memoryCard = h => {
  const m = memories[h.id];
  if (m) return `<button class="mem-strip" data-memory="${esc(h.id)}"><img src="${esc(m.photo)}" alt="">
      <span><b>${icon("image")} Memory</b><small>by ${esc(m.by === me?.uid ? "you" : m.byName || "a friend")} · ${lateText(m) || "on time"}</small></span>${icon("chevron-right")}</button>`;
  if (!allHere(h)) return "";
  return `<div class="mem-take-row"><button class="mem-take" data-snap="${esc(h.id)}">${icon("camera")} Take the group photo</button>
    <button class="mem-take up" data-snap-upload="${esc(h.id)}" title="Upload a photo">${icon("image")} Upload</button></div>`;
};

// ---------- taking it ----------
function pickPhoto(id, camera) {
  snapFor = id;
  // phones open their own camera from the file input; laptops ignore that, so they get omw's camera instead
  if (camera && !phoneCamera() && navigator.mediaDevices?.getUserMedia) return openCamera();
  const input = $(camera ? "snapCamera" : "snapLibrary");
  input.value = "";
  input.click();
}
const phoneCamera = () => matchMedia("(pointer: coarse)").matches && /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);

// ---------- the camera on laptops: live preview, shutter, 3-second timer so the person taking it can get in too ----------
let cam = null;  // { stream, facing, timer, counting }
async function openCamera(facing = cam?.facing || "user") {
  closeCamera(false);
  cam = { facing, timer: cam?.timer ?? true, counting: false };
  const el = $("memCam");
  el.hidden = false;
  el.innerHTML = `<div class="mem-card cam-card">
    <button class="x" data-cam-close title="Close">${icon("x")}</button>
    <h2 class="board-title">Group photo</h2>
    <div class="cam-view"><video id="camVideo" autoplay playsinline muted></video><div class="cam-count" id="camCount"></div>
      <div class="cam-msg" id="camMsg">Starting the camera…</div></div>
    <div class="cam-bar">
      <button class="cam-side ${cam.timer ? "on" : ""}" data-cam-timer title="3-second timer">${icon("clock")}<small>${cam.timer ? "3s" : "Off"}</small></button>
      <button class="cam-shutter" data-cam-shoot title="Take the photo" disabled></button>
      <button class="cam-side" data-cam-flip title="Switch camera" hidden>${icon("refresh-cw")}<small>Flip</small></button>
    </div>
    <button class="wide cam-upload" data-cam-upload>${icon("image")} Upload a photo instead</button>
  </div>`;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: facing, width: { ideal: 1920 }, height: { ideal: 1440 } }, audio: false });
    if (!cam || $("memCam").hidden) return stream.getTracks().forEach(t => t.stop());  // closed while it was starting
    cam.stream = stream;
    const v = $("camVideo");
    v.srcObject = stream;
    v.classList.toggle("mirror", facing === "user");
    await v.play().catch(() => {});
    $("camMsg").hidden = true;
    el.querySelector("[data-cam-shoot]").disabled = false;
    const cams = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === "videoinput");
    el.querySelector("[data-cam-flip]").hidden = cams.length < 2;
  } catch (e) {
    $("camMsg").innerHTML = e.name === "NotAllowedError"
      ? `${icon("triangle-alert")}<b>Camera blocked</b>Allow the camera in your browser (the camera icon in the address bar), then try again. Or upload a photo.`
      : e.name === "NotFoundError" ? `${icon("triangle-alert")}<b>No camera found</b>Upload a photo instead.`
      : `${icon("triangle-alert")}<b>Couldn't start the camera</b>Upload a photo instead.`;
  }
}
function closeCamera(hide = true) {
  cam?.stream?.getTracks().forEach(t => t.stop());
  if (cam) cam.stream = null;
  if (hide) { $("memCam").hidden = true; $("memCam").innerHTML = ""; cam = null; }
}
async function shoot() {
  const v = $("camVideo");
  if (!cam?.stream || cam.counting || !v.videoWidth) return;
  cam.counting = true;
  if (cam.timer) for (let n = 3; n > 0; n--) { $("camCount").textContent = n; await new Promise(r => setTimeout(r, 1000)); if (!cam) return; }
  $("camCount").textContent = "";
  const c = document.createElement("canvas");
  c.width = v.videoWidth; c.height = v.videoHeight;
  const g = c.getContext("2d");
  if (cam.facing === "user") { g.translate(c.width, 0); g.scale(-1, 1); }  // save it the way you saw it, like a selfie
  g.drawImage(v, 0, 0);
  $("memCam").querySelector(".cam-view").classList.add("flash");
  const blob = await new Promise(r => c.toBlob(r, "image/jpeg", .92));
  closeCamera();
  gotFile(blob);
}
async function shrink(file) {  // at most 1280px and ~700 KB, as a JPEG (it's stored in the database)
  const img = await new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("That file isn't a photo."));
                                              i.src = URL.createObjectURL(file); });
  for (const [size, q] of [[1280, .82], [1080, .78], [900, .72], [720, .7]]) {
    const k = Math.min(1, size / Math.max(img.naturalWidth, img.naturalHeight));
    const c = document.createElement("canvas");
    c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const url = c.toDataURL("image/jpeg", q);
    if (url.length < 700000) return url;
  }
  throw new Error("That photo is too big. Try another one.");
}
async function gotFile(file) {
  const m = memories[snapFor];
  const h = hangoutsList().find(x => x.id === snapFor) || (m && { id: snapFor, title: m.title, venueName: m.venueName, attendees: m.members, names: m.names });
  if (!file || !h) return;
  try { draft = { h, photo: await shrink(file) }; showComposer(); }
  catch (e) { alert(friendly(e, "use that photo")); }
}
function showComposer(msg = "") {
  const { h, photo } = draft;
  const mine = memories[h.id]?.by === me.uid;
  $("memCompose").hidden = false;
  $("memCompose").innerHTML = `<div class="mem-card">
    <button class="x" data-compose-close title="Cancel">${icon("x")}</button>
    <h2 class="board-title">${mine ? "New group photo" : "Your group photo"}</h2>
    <div class="mem-sub">${esc(plainTitle(h.title))} · ${esc(h.venueName || "")}</div>
    <div class="mem-photo"><img src="${photo}" alt="Group photo"></div>
    <div class="mem-who">${h.attendees.map(u => `<span>${esc(u === me.uid ? "You" : h.names?.[u] || "Friend")}</span>`).join("")}</div>
    <div class="mem-actions">
      <button class="mini" data-snap-again="camera">${icon("camera")} Retake</button>
      <button class="mini" data-snap-again="library">${icon("image")} Pick another</button>
    </div>
    <button class="wide dark" data-post>${icon("send")} ${mine ? "Replace the photo" : `Post for everyone (${h.attendees.length})`}</button>
    <small class="note mem-msg">${esc(msg)}</small>
  </div>`;
}
async function post() {
  const { h, photo } = draft, old = memories[h.id], at = new Date().toISOString();
  const btn = $("memCompose").querySelector("[data-post]");
  btn.disabled = true; btn.textContent = "Posting…";
  try {
    if (old) await updateDoc(doc(db, "memories", h.id), { photo, at });  // yours: retaken
    else await setDoc(doc(db, "memories", h.id), {
      members: h.attendees, names: Object.fromEntries(h.attendees.map(u => [u, h.names?.[u] || (u === me.uid ? myName() : "Friend")])),
      by: me.uid, byName: h.names?.[me.uid] || myName(), photo, at, allHereAt: new Date(allHereAt(h)).toISOString(),
      title: plainTitle(h.title), venueName: h.venueName || "", address: h.address || "", start: h.start });
    window.sendChat?.(h.id, "posted the group photo in Memories").catch?.(() => {});
    draft = null; $("memCompose").hidden = true;
    openWhenSaved = h.id;  // show it as soon as it's saved
    if (memories[h.id]?.photo === photo) { openWhenSaved = null; open(h.id); }
  } catch (e) {
    btn.disabled = false; btn.textContent = "Post for everyone";
    showComposer(/permission/i.test(e.message) ? "Someone else just posted the photo for this one." : friendly(e, "post it"));
  }
}
const myName = () => me?.displayName || "Friend";

// ---------- the Memories page: a calendar of your hangouts, a photo on each day you met up ----------
function render() {
  const list = Object.values(memories).sort((a, b) => b.start.localeCompare(a.start));
  const onTime = list.filter(m => !lateText(m)).length;
  $("memSummary").innerHTML = list.length
    ? `<b>${list.length}</b> hangout${list.length === 1 ? "" : "s"} together · <b>${onTime}</b> posted on time`
    : "";
  if (!list.length) {
    $("memList").innerHTML = `<div class="nobody mem-empty">${icon("camera")}<b>No memories yet</b>Group photos from your hangouts show up here.</div>`;
    return;
  }
  const months = [];
  for (const m of list) {
    const d = new Date(m.start), key = `${d.getFullYear()}-${d.getMonth()}`;
    let month = months.find(x => x.key === key);
    if (!month) months.push(month = { key, y: d.getFullYear(), mo: d.getMonth(), days: {} });
    (month.days[d.getDate()] ||= []).push(m);
  }
  const week = Array.from({ length: 7 }, (_, i) => new Date(2026, 1, 1 + i).toLocaleDateString([], { weekday: "narrow" }));  // Feb 1 2026 is a Sunday
  $("memList").innerHTML = months.map(({ y, mo, days }) => {
    const first = new Date(y, mo, 1).getDay(), count = new Date(y, mo + 1, 0).getDate(), n = Object.values(days).flat().length;
    const cells = [...Array(first).fill(`<i></i>`), ...Array.from({ length: count }, (_, i) => {
      const ms = days[i + 1];
      if (!ms) return `<span class="mem-day">${i + 1}</span>`;
      return `<button class="mem-day has" data-memory="${esc(ms[0].id)}" title="${esc(ms.map(m => m.title).join(", "))}">
        <img src="${esc(ms[0].photo)}" alt="" loading="lazy"><b>${i + 1}</b>${ms.length > 1 ? `<em>${ms.length}</em>` : ""}</button>`;
    })];
    return `<section class="mem-month"><div class="mem-month-head"><b>${new Date(y, mo, 1).toLocaleDateString([], { month: "long", year: "numeric" })}</b>
        <small>${n} memor${n === 1 ? "y" : "ies"}</small></div>
      <div class="mem-grid">${week.map(w => `<small>${w}</small>`).join("")}${cells.join("")}</div></section>`;
  }).join("");
}

// one memory, big
function open(id) {
  const m = memories[id];
  if (!m) return;
  viewing = id;
  const d = new Date(m.start), sameDay = Object.values(memories).filter(x => new Date(x.start).toDateString() === d.toDateString())
    .sort((a, b) => a.start.localeCompare(b.start));
  $("memView").hidden = false;
  $("memView").innerHTML = `<div class="mem-card">
    <button class="x" data-view-close title="Close">${icon("x")}</button>
    <div class="mem-date">${d.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", year: "numeric" })}</div>
    <h2 class="board-title">${esc(plainTitle(m.title))}</h2>
    <div class="mem-sub">${icon("map-pin")} ${esc(m.venueName || m.address || "")} · ${new Date(m.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })} ${onTimeBadge(m)}</div>
    <div class="mem-photo"><img src="${esc(m.photo)}" alt="Group photo"></div>
    ${sameDay.length > 1 ? `<div class="mem-others">${sameDay.map(x => `<button class="${x.id === id ? "on" : ""}" data-memory="${esc(x.id)}"><img src="${esc(x.photo)}" alt=""></button>`).join("")}</div>` : ""}
    <div class="mem-who">${m.members.map(u => `<span>${esc(nameOf(m, u))}</span>`).join("")}</div>
    <div class="mem-actions">
      <button class="mini" data-save>${icon("share")} Save</button>
      ${m.by === me.uid ? `<button class="mini" data-retake="${esc(id)}">${icon("camera")} Retake</button>
                           <button class="mini danger" data-delete="${esc(id)}">${icon("trash-2")} Delete for everyone</button>`
                        : `<button class="mini" data-hide="${esc(id)}">${icon("eye")} Remove from my memories</button>`}
    </div>
  </div>`;
}
window.openMemory = open;

async function save(m) {  // share sheet on phones (Save Image), a download elsewhere
  const blob = await (await fetch(m.photo)).blob(), name = `omw-${m.start.slice(0, 10)}.jpg`;
  const file = new File([blob], name, { type: "image/jpeg" });
  if (navigator.canShare?.({ files: [file] })) return navigator.share({ files: [file], title: m.title }).catch(() => {});
  const a = Object.assign(document.createElement("a"), { href: m.photo, download: name });
  a.click();
}

// ---------- taps ----------
document.addEventListener("click", async e => {
  const cb = e.target.closest("[data-cam-close], [data-cam-shoot], [data-cam-timer], [data-cam-flip], [data-cam-upload]");
  if (cb) {
    e.stopPropagation(); e.preventDefault();
    if (cb.hasAttribute("data-cam-close")) return closeCamera();
    if (cb.hasAttribute("data-cam-shoot")) return shoot();
    if (cb.hasAttribute("data-cam-flip")) return openCamera(cam?.facing === "user" ? "environment" : "user");
    if (cb.hasAttribute("data-cam-upload")) { closeCamera(); return pickPhoto(snapFor, false); }
    if (cb.hasAttribute("data-cam-timer")) { cam.timer = !cam.timer; cb.classList.toggle("on", cam.timer); cb.querySelector("small").textContent = cam.timer ? "3s" : "Off"; }
    return;
  }
  if (e.target.id === "memCam") return closeCamera();
  const t = e.target.closest("[data-snap], [data-snap-upload], [data-snap-skip], [data-memory], [data-snap-again], [data-post], [data-compose-close], [data-view-close], [data-save], [data-retake], [data-delete], [data-hide]");
  if (!t) {
    if (e.target.id === "memView") { $("memView").hidden = true; viewing = null; }
    if (e.target.id === "memCompose") { $("memCompose").hidden = true; draft = null; }
    return;
  }
  e.stopPropagation(); e.preventDefault();  // don't also open the hangout on the map
  const ds = t.dataset;
  if (ds.snap) return pickPhoto(ds.snap, true);
  if (ds.snapUpload) return pickPhoto(ds.snapUpload, false);
  if (ds.snapSkip) { store.set(`memSkip:${me.uid}:${ds.snapSkip}`, true); return renderPrompt(); }
  if (ds.memory) return open(ds.memory);
  if (ds.snapAgain) { $("memCompose").hidden = true; return pickPhoto(draft.h.id, ds.snapAgain === "camera"); }
  if (t.hasAttribute("data-post")) return post();
  if (t.hasAttribute("data-compose-close")) { $("memCompose").hidden = true; draft = null; return; }
  if (t.hasAttribute("data-view-close")) { $("memView").hidden = true; viewing = null; return; }
  if (t.hasAttribute("data-save")) return save(memories[viewing]);
  if (ds.retake) { $("memView").hidden = true; return pickPhoto(ds.retake, true); }
  if (ds.delete) {
    if (!confirm("Delete this photo for everyone who went?")) return;
    await deleteDoc(doc(db, "memories", ds.delete)).catch(err => alert(friendly(err, "delete it")));
    $("memView").hidden = true; viewing = null; return;
  }
  if (ds.hide) {
    if (!confirm("Take this off your memories? The others keep it.")) return;
    await updateDoc(doc(db, "memories", ds.hide), { members: arrayRemove(me.uid) }).catch(err => alert(friendly(err, "remove it")));
    $("memView").hidden = true; viewing = null;
  }
}, true);
$("snapCamera").onchange = e => gotFile(e.target.files[0]);
$("snapLibrary").onchange = e => gotFile(e.target.files[0]);
$("memoriesBtn").onclick = () => { $("memories").hidden = false; render(); };
$("memoriesClose").onclick = () => { $("memories").hidden = true; };
window.addEventListener("hangouts-changed", renderPrompt);
document.addEventListener("keydown", e => { if (cam && !$("memCam").hidden) { if (e.key === "Escape") closeCamera(); if (e.key === " " || e.key === "Enter") { e.preventDefault(); shoot(); } } });

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    stop?.(); stop = null; memories = {}; me = u;
    renderPrompt();
    if (!u) return;
    stop = onSnapshot(query(collection(db, "memories"), where("members", "array-contains", u.uid)), s => {
      memories = Object.fromEntries(s.docs.map(d => [d.id, { ...d.data(), id: d.id }]));
      render(); renderPrompt();
      if (openWhenSaved && memories[openWhenSaved]) { open(openWhenSaved); openWhenSaved = null; }
      if (viewing && !memories[viewing]) { $("memView").hidden = true; viewing = null; }
      window.dispatchEvent(new Event("memories-changed"));
    }, err => console.warn("memories:", err.message));
  });
}
