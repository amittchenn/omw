// The Map tab in the app, like Google Maps: your friends where they are right now (if they share it), the places you saved,
// and the spots your friends rated. Search or tap anywhere for a place card: save it, plan a hangout there, or get directions.
// Saved places are only yours: private/{uid}.saved = [{ name, address, lat, lng, at }].
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, doc, onSnapshot, setDoc } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const first = n => String(n || "Friend").split(" ")[0];
const map = () => window.omwMap;
let db, me = null, saved = [], stop = null, on = false, place = null, list = "", layers = null;

const isSaved = p => p && saved.some(s => Math.abs(s.lat - p.lat) < 1e-5 && Math.abs(s.lng - p.lng) < 1e-5);
const ago = t => { const m = Math.round((Date.now() - t) / 6e4); return m < 1 ? "just now" : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`; };
const status = p => {
  if (p.now && new Date(p.now.until) > Date.now()) return p.now.kind === "out" ? "Out now" : "On the way";
  if (p.freeUntil && new Date(p.freeUntil) > Date.now()) return "Free";
  return "";
};
const liveFriends = () => (window.myFriends || []).filter(p => !p.isMe && p.live);
const pinFace = p => p.photo ? `<span class="mf-face" style="background-image:url('${esc(p.photo)}')"></span>`
                             : `<span class="mf-face">${esc(first(p.name).slice(0, 1))}</span>`;

// ---------- drawing on the map ----------
function draw() {
  if (!map() || !window.L) return;
  layers ||= { friends: L.layerGroup(), saved: L.layerGroup() };
  layers.friends.clearLayers(); layers.saved.clearLayers();
  if (!on) { layers.friends.remove(); layers.saved.remove(); return; }
  layers.friends.addTo(map()); layers.saved.addTo(map());
  for (const p of liveFriends()) {
    L.marker(p.live, { zIndexOffset: 500, icon: L.divIcon({ className: "", iconSize: [64, 78], iconAnchor: [32, 32],
      html: `<div class="map-friend">${pinFace(p)}<b>${esc(first(p.name))}</b></div>` }) })
      .on("click", () => showFriend(p)).addTo(layers.friends);
  }
  for (const s of saved) {
    L.marker([s.lat, s.lng], { icon: L.divIcon({ className: "", iconSize: [34, 34], iconAnchor: [17, 17],
      html: `<div class="map-saved">${icon("bookmark")}</div>` }) })
      .on("click", () => window.planAt ? pick(s) : null).addTo(layers.saved);
  }
}
const pick = s => { map().setView([s.lat, s.lng], Math.max(map().getZoom(), 15)); window.pickPlace?.([s.lat, s.lng], s.name, s.address || ""); };

// ---------- the card at the bottom ----------
function card(html) {
  const el = $("mapPanel");
  el.hidden = !html;
  el.innerHTML = html || "";
}
function showPlace() {
  if (!on || !place) return card(list ? listHtml() : "");
  const s = isSaved(place);
  card(`<div class="mp-place">
    <div class="mp-title"><b>${esc(place.name)}</b><small>${esc(place.address || "")}</small></div>
    <button class="mp-close" data-mp-close aria-label="Close">${icon("x")}</button>
    <div class="mp-actions">
      <button class="mp-main" data-mp-plan>${icon("plus")} Plan a hangout here</button>
      <button data-mp-save class="${s ? "on" : ""}">${icon("bookmark")} ${s ? "Saved" : "Save"}</button>
      <button data-mp-go>${icon("navigation")} Directions</button>
    </div></div>`);
}
function showFriend(p) {
  place = null; list = "";
  card(`<div class="mp-place">
    <div class="mp-friend">${pinFace(p)}<div class="mp-title"><b>${esc(p.name)}</b>
      <small>${esc([status(p), p.liveAt ? `here ${ago(p.liveAt)}` : ""].filter(Boolean).join(" · "))}</small></div></div>
    <button class="mp-close" data-mp-close aria-label="Close">${icon("x")}</button>
    <div class="mp-actions"><button class="mp-main" data-mp-with="${esc(p.user_id)}">${icon("plus")} Plan something with ${esc(first(p.name))}</button></div>
  </div>`);
}
function listHtml() {
  const rows = list === "saved" ? saved.map((s, i) => ({ i, name: s.name, sub: s.address || "", kind: "saved" }))
    : list === "spots" ? (window.friendSpots?.() || []).map((s, i) => ({ i, name: s.name, kind: "spots", score: s.score,
        sub: `${s.visits} visit${s.visits === 1 ? "" : "s"} · ${s.people.slice(0, 3).join(", ")}` }))
    : liveFriends().map((p, i) => ({ i, name: p.name, kind: "friends", sub: [status(p), p.liveAt ? ago(p.liveAt) : ""].filter(Boolean).join(" · ") }));
  const empty = { saved: "Tap any place on the map and press Save. It shows up here, just for you.",
                  spots: "When friends rate a place after a hangout, it shows up here, best first.",
                  friends: "Friends who share their location show up on the map." }[list];
  const title = { saved: "Saved", spots: "Friends' spots", friends: "Friends nearby" }[list];
  return `<div class="mp-list"><div class="mp-list-head"><b>${title}</b><button class="mp-close" data-mp-close aria-label="Close">${icon("x")}</button></div>
    ${rows.length ? rows.map(r => `<button class="mp-row" data-mp-row="${r.kind}:${r.i}">
      ${r.score != null && r.kind === "spots" ? `<span class="fp-score">${r.score.toFixed(1)}</span>` : r.kind === "spots" ? `<span class="fp-score none">new</span>` : ""}
      <span><b>${esc(r.name)}</b><small>${esc(r.sub)}</small></span>${icon("chevron-right")}</button>`).join("")
      : `<p class="mp-empty">${empty}</p>`}</div>`;
}

// ---------- taps ----------
document.addEventListener("click", async e => {
  const t = e.target.closest("[data-map-list], [data-mp-close], [data-mp-plan], [data-mp-save], [data-mp-go], [data-mp-with], [data-mp-row]");
  if (!t || !t.closest("#mapChips, #mapPanel")) return;
  const ds = t.dataset;
  window.Capacitor?.Plugins?.Haptics?.impact({ style: "LIGHT" }).catch(() => {});
  if (ds.mapList) { list = list === ds.mapList ? "" : ds.mapList; place = null; chips(); return card(list ? listHtml() : ""); }
  if (t.hasAttribute("data-mp-close")) { place = null; list = ""; chips(); return card(""); }
  if (t.hasAttribute("data-mp-plan")) return window.showTab("plan");  // the spot is already picked: the planner opens on it
  if (ds.mpWith) { window.showTab("plan"); return window.planWith?.([ds.mpWith]); }
  if (t.hasAttribute("data-mp-go")) return window.openDirections?.({ venue: [place.lat, place.lng], name: place.name });
  if (t.hasAttribute("data-mp-save")) {
    const next = isSaved(place) ? saved.filter(s => !(Math.abs(s.lat - place.lat) < 1e-5 && Math.abs(s.lng - place.lng) < 1e-5))
                                : [...saved, { name: place.name, address: place.address || "", lat: place.lat, lng: place.lng, at: new Date().toISOString() }];
    saved = next; showPlace(); draw();
    return setDoc(doc(db, "private", me.uid), { saved: next.slice(-300) }, { merge: true }).catch(err => alert(friendly(err, "save it")));
  }
  if (ds.mpRow) {
    const [kind, i] = ds.mpRow.split(":");
    if (kind === "friends") { const p = liveFriends()[+i]; if (p) { map().setView(p.live, 15); showFriend(p); } return; }
    const s = kind === "saved" ? saved[+i] : (window.friendSpots?.() || [])[+i];
    if (s) { list = ""; chips(); pick(s.lat != null ? s : { name: s.name, address: s.address, lat: s.venue[0], lng: s.venue[1] }); }
  }
});
const chips = () => $("mapChips").querySelectorAll("[data-map-list]").forEach(b => b.classList.toggle("on", b.dataset.mapList === list));

// a place was picked (searched, or tapped on the map)
window.addEventListener("venue-set", e => {
  const { latlng, name, address } = e.detail;
  place = { name, address, lat: latlng[0], lng: latlng[1] }; list = ""; chips();
  showPlace();
});
window.addEventListener("venue-cleared", () => { place = null; showPlace(); });
window.addEventListener("tab-changed", e => {
  on = e.detail === "map";
  $("mapChips").hidden = !on;
  if (!on) card(""); else showPlace();
  draw();
  if (on) setTimeout(() => map()?.invalidateSize(), 60);
});
window.addEventListener("friends-changed", () => { if (on) draw(); });

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    stop?.(); stop = null; me = u; saved = [];
    if (!u) return;
    stop = onSnapshot(doc(db, "private", u.uid), s => { saved = (s.data()?.saved || []).filter(x => typeof x?.lat === "number"); draw(); if (on && place) showPlace(); }, () => {});
  });
}
