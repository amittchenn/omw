const API = "";  // same server that serves this page
const COLORS = ["#1e88ff", "#ff4f9a", "#ffb000", "#16c47f", "#ff6a3d", "#00c2c7", "#a3d900", "#e0a800"];  // you, then each friend
const TYPES = [["food", "utensils", "Food"], ["coffee", "coffee", "Coffee"], ["study", "book-open", "Study"], ["party", "party-popper", "Party"], ["sports", "volleyball", "Sports"]];
const MODE = { driving: "drive", walking: "walk", cycling: "bike", transit: "transit" };
const MODE_ICON = { driving: "car", walking: "footprints", cycling: "bike", transit: "bus" };
const modeHtml = m => `${icon(MODE_ICON[m] || "car")} ${MODE[m] || ""}`;
let modeFor = {};  // someone's way of getting there for this plan, picked on their card
const $ = id => document.getElementById(id);
const phone = () => matchMedia("(max-width: 860px)").matches;
let shown = null;  // the hangout from My plans on the map: { h, where, stop }
let lastPlan = [], homeMarkers = {}, people = [], colorOf = {}, venue = null, venueName = "", venueAddress = "", venueMarker = null, routes = {};
const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// cartoon avatar for each friend (falls back to initials if the avatar service is unreachable)
const face = p => p.photo || `https://api.dicebear.com/9.x/avataaars/svg?seed=${encodeURIComponent(p.user_id)}` +
                  `&backgroundColor=${colorOf[p.user_id].slice(1)}`;
const initials = name => name.slice(0, 2).toUpperCase();
const avatar = p => `<div class="avatar" style="--c:${colorOf[p.user_id]}"><span>${initials(p.name)}</span>` +
                    `<img src="${esc(face(p))}" alt="" data-fail="remove"></div>`;
const pal = (p, tag, extra = "") => L.divIcon({ className: "", iconSize: [62, 90], iconAnchor: [31, 34],
  html: `<div class="pal ${extra}" style="--c:${colorOf[p.user_id]}">${avatar(p)}` +
        `<div class="mode">${icon(MODE_ICON[p.travel_mode] || "car")}</div><div class="tag">${esc(tag)}</div></div>` });

// static icons in the page: <i data-ic="name"> and <button data-ic="name">
document.querySelectorAll("[data-page-link]").forEach(a => Object.assign(a, { href: (window.OMW_SERVER || "") + a.dataset.pageLink, target: "_blank", rel: "noopener" }));
document.querySelectorAll("[data-ic]").forEach(el => {
  if (el.tagName === "I") el.outerHTML = icon(el.dataset.ic); else el.insertAdjacentHTML("afterbegin", icon(el.dataset.ic));
});

// ---------- map ----------
const map = L.map("map").setView([37.7849, -122.4094], 13);
const layer = L.layerGroup().addTo(map);

// the map is Mapbox GL like Snap Map (glmap.js): Mapbox's Standard style, with its night lighting in dark mode
// (it follows the phone's setting); free OpenStreetMap tiles if there's no Mapbox token
let GKEY = "";  // Google Maps key for the map inside directions (from /config)
const darkMode = matchMedia("(prefers-color-scheme: dark)");
fetch(`${API}/config`).then(r => r.json()).catch(() => ({})).then(({ mapbox_token, google_maps_key }) => {
  GKEY = google_maps_key || "";
  map.start(mapbox_token || "", darkMode).catch(e => console.warn("map:", e.message));
});
// you: a live blue dot that follows you, like Google Maps. ◎ (bottom right) jumps back to it.
let myDot = null, myRing = null, myLocation = null, centeredOnMe = false;
navigator.geolocation?.watchPosition(p => {
  myLocation = [p.coords.latitude, p.coords.longitude];
  window.myFix = { here: myLocation, at: Date.now() };  // "Use my current location" in your profile reuses this
  window.dispatchEvent(new Event("my-fix"));  // plans that leave from "where you are" update their leave times
  if (!myDot) {
    myRing = L.circle(myLocation, { radius: p.coords.accuracy, color: "#1e88ff", weight: 1, fillOpacity: .12, interactive: false }).addTo(map);
    myDot = L.marker(myLocation, { zIndexOffset: 2000, interactive: false,
      icon: L.divIcon({ className: "", iconSize: [22, 22], iconAnchor: [11, 11], html: `<div class="me-dot"></div>` }) }).addTo(map);
  }
  myDot.setLatLng(myLocation);
  myRing.setLatLng(myLocation).setRadius(Math.min(p.coords.accuracy, 500));
  if (!centeredOnMe) { centeredOnMe = true; if (!venue && !shown) map.setView(myLocation, 14); }
  if (shown) drawHangout();  // keep "You" on a hangout's map in step with the dot
}, () => {}, { enableHighAccuracy: true, maximumAge: 10000 });
const Locate = L.Control.extend({ options: { position: "bottomright" }, onAdd() {  // bottom right, like Snap Map
  const b = L.DomUtil.create("button", "locate");
  b.title = "Show where I am"; b.setAttribute("aria-label", "Show where I am"); b.innerHTML = icon("navigation");
  L.DomEvent.disableClickPropagation(b);
  b.onclick = () => myLocation ? map.flyTo(myLocation, Math.max(map.getZoom(), 16))
                               : alert("Allow location for this site to see where you are.");
  return b;
} });
new Locate().addTo(map);

// keep the map's focus in the visible area (not under the planner)
const viewPadding = () => phone() ? { paddingTopLeft: [40, 90], paddingBottomRight: [40, innerHeight * 0.45] }
                                  : { paddingTopLeft: [460, 100], paddingBottomRight: [60, 60] };

// on phones, tap the handle or title to fold the planner away
// the + tab's planner is an iOS sheet: always full size, it slides down to fold (just its top shows) and back up
const planSheet = () => document.documentElement.dataset.tab === "plan";
const foldY = () => Math.max(0, $("sheet").offsetHeight - 150);
const halfY = () => Math.round($("sheet").offsetHeight * 0.48);  // the middle stop: half the map, half the planner
function toggleSheet(force) {
  if (!phone()) return;
  $("sheet").style.setProperty("--fold", `${foldY()}px`);
  $("sheet").classList.remove("half");
  const folded = $("sheet").classList.toggle("collapsed", force);
  if (folded) $("sheet").scrollTop = 0;  // show the title when folded
}
$("handle").onclick = () => { if (!sheetDragged) toggleSheet(); };
window.openSheet = () => toggleSheet(false);  // the feed's + tab
document.querySelector(".hello").onclick = () => { if (!sheetDragged) toggleSheet(); };

// on phones, swipe the planner down to fold it away (from the top of it) and up to open it again, like a maps app
let sheetDrag = null, sheetDragged = false;
$("sheet").addEventListener("touchstart", e => {
  if (!phone() || e.touches.length > 1) return;
  const s = $("sheet");
  sheetDragged = false;
  // folded: any swipe opens it. Open: only when it's scrolled to the top, so normal scrolling still works
  sheetDrag = s.classList.contains("collapsed") || s.scrollTop <= 0 ? { y: e.touches[0].clientY, x: e.touches[0].clientX, dy: 0, v: 0, t: Date.now() } : null;
}, { passive: true });
$("sheet").addEventListener("touchmove", e => {
  if (!sheetDrag) return;
  const s = $("sheet"), t = e.touches[0], dy = t.clientY - sheetDrag.y;
  // pulling down at the top of the + tab's sheet moves the sheet, from the very first pixel: if iOS starts its own
  // bounce first, the sheet's insides stretch while it moves (a gap opens above the handle)
  const half = planSheet() && s.classList.contains("half");
  if (planSheet() && (dy > 0 && s.scrollTop <= 0 || half)) e.preventDefault();
  if (!sheetDrag.dir) {  // decide once whether this is an up/down swipe or a sideways scroll (friend list, categories)
    if (Math.abs(dy) < 8 && Math.abs(t.clientX - sheetDrag.x) < 8) return;
    sheetDrag.dir = Math.abs(dy) > Math.abs(t.clientX - sheetDrag.x) ? "y" : "x";
  }
  if (sheetDrag.dir !== "y") return;
  const folded = s.classList.contains("collapsed");
  if (!folded && !half && (dy <= 0 || s.scrollTop > 0)) { sheetDrag.dy = 0; s.style.transform = ""; return; }  // scrolling the list up
  e.preventDefault();
  sheetDrag.v = (dy - sheetDrag.dy) / Math.max(1, Date.now() - sheetDrag.t); sheetDrag.t = Date.now();
  sheetDrag.dy = dy;
  sheetDragged = Math.abs(dy) > 8;
  s.classList.add("dragging");
  if (planSheet()) {  // follows your finger the whole way, and gives a little past the top
    const y = (folded ? foldY() : s.classList.contains("half") ? halfY() : 0) + dy;
    s.style.transform = `translateY(${y < 0 ? y * 0.25 : y}px)`;
    return;
  }
  s.style.transform = folded ? `translateY(${Math.max(dy, -40) * 0.5}px)` : `translateY(${dy}px)`;
}, { passive: false });
const endSheetDrag = () => {
  if (!sheetDrag) return;
  const s = $("sheet"), { dy, v } = sheetDrag, folded = s.classList.contains("collapsed");
  sheetDrag = null;
  s.classList.remove("dragging");
  if (planSheet()) {  // lands open, halfway or folded: a flick goes one stop that way, otherwise the closest stop
    const stops = [0, halfY(), foldY()], from = folded ? foldY() : s.classList.contains("half") ? halfY() : 0, y = from + dy;
    let i = stops.reduce((best, p, k) => Math.abs(p - y) < Math.abs(stops[best] - y) ? k : best, 0);
    if (Math.abs(v) > .4) i = Math.max(0, Math.min(2, stops.indexOf(from) + (v > 0 ? 1 : -1)));
    s.style.transition = "transform .28s cubic-bezier(.2, .9, .25, 1)";
    s.style.setProperty("--fold", `${foldY()}px`); s.style.setProperty("--half", `${halfY()}px`);
    s.classList.toggle("collapsed", i === 2); s.classList.toggle("half", i === 1); if (i === 2) s.scrollTop = 0;
    s.style.transform = "";
    setTimeout(() => { s.style.transition = ""; sheetDragged = false; }, 300);
    return;
  }
  s.style.transition = "transform .2s ease, max-height .25s ease"; s.style.transform = "";
  setTimeout(() => (s.style.transition = ""), 260);
  if (!folded && dy > 70) toggleSheet(true);
  else if (folded && dy < -25) toggleSheet(false);
  setTimeout(() => (sheetDragged = false), 50);
};
$("sheet").addEventListener("touchend", endSheetDrag);
$("sheet").addEventListener("touchcancel", endSheetDrag);

let forcedEmoji = "";  // a hangout from My plans shows its own emoji, even if it's someone else's category
const typeEmoji = () => glyph(forcedEmoji || allTypes().find(t => t[0] === selectedType())?.[1] || "map-pin");
const venueIcon = () => L.divIcon({ className: "", iconSize: [70, 70], iconAnchor: [35, 35],
  html: `<div class="venue-pin"><div class="glow"></div><div class="bubble">${typeEmoji()}</div></div>` });

function setVenue(latlng, name, address = "") {
  closeHangout();  // a different spot: stop showing the hangout from My plans
  venue = latlng; venueName = name; venueAddress = address;
  venueMarker?.remove();
  venueMarker = L.marker(latlng, { icon: venueIcon(), zIndexOffset: 1000 }).addTo(map)
    .bindTooltip(esc(name), { permanent: true, direction: "bottom", offset: [0, 38], className: "place-label" });
  $("mapHint").style.display = "none";
  $("placeInput").value = name;
  $("venueSub").innerHTML = `${icon("map-pin")} Meeting at <b>${esc(name)}</b> <button class="unpick" id="unpick">Remove</button>`;
  $("unpick").onclick = e => { e.stopPropagation(); clearVenue(); };
  $("clearPlace").hidden = false;
  showWeather();
  window.dispatchEvent(new CustomEvent("venue-set", { detail: { latlng, name, address } }));  // the Map tab's place card
}

// take the spot back off: pin, routes and results all go, since they were for that spot
function clearVenue() {
  closeHangout();
  venue = null; venueName = venueAddress = "";
  venueMarker?.remove(); venueMarker = null;
  layer.clearLayers(); routes = {}; homeMarkers = {}; lastPlan = [];
  $("results").innerHTML = ""; $("empty").style.display = "";
  $("placeInput").value = ""; $("clearPlace").hidden = true; hideSuggest(); resultPins.clearLayers(); $("searchArea").hidden = true;
  fairPins.clearLayers();
  $("mapHint").style.display = "";
  $("venueSub").textContent = "Search or tap the map to pick a spot";
  showWeather();
  window.dispatchEvent(new Event("venue-cleared"));
}
$("clearPlace").onclick = clearVenue;

// tap the map: drop a pin, then look up what's there
map.on("click", async e => {
  const latlng = [e.latlng.lat, e.latlng.lng];
  setVenue(latlng, "Finding this spot…");
  const place = await fetch(`${API}/place-name?lat=${latlng[0]}&lng=${latlng[1]}`).then(r => r.json()).catch(() => ({}));
  if (venue !== latlng) return;  // they tapped somewhere else meanwhile
  // tapped right next to a place (a cafe, a park…): meet at the place itself, like tapping it in Google Maps
  const spot = place.kind === "place" && place.lat != null ? [place.lat, place.lng] : latlng;
  setVenue(spot, place.name || `${latlng[0].toFixed(5)}, ${latlng[1].toFixed(5)}`, place.address || "");
});

// ---------- search box, like Google Maps ----------
// typing: places and searches, closest first · Enter or a category: a full list with ratings, open now and distance,
// pinned on the map · empty box: quick categories and your recent spots
const CATEGORIES = [["coffee", "Coffee"], ["utensils", "Food"], ["cup-soda", "Boba"], ["pizza", "Pizza"], ["ice-cream-cone", "Dessert"], ["book-open", "Study spots"],
                    ["trees", "Parks"], ["ticket", "Things to do"], ["martini", "Bars"], ["shopping-bag", "Shopping"]];
const TYPE_ICONS = [[/cafe|coffee/, "coffee"], [/bakery/, "croissant"], [/bar|night_club/, "martini"], [/restaurant|food|meal/, "utensils"], [/park|garden/, "trees"],
  [/gym|fitness/, "dumbbell"], [/library/, "book-open"], [/university|school/, "graduation-cap"], [/movie/, "clapperboard"], [/bowling|amusement|arcade/, "ticket"],
  [/museum|art/, "landmark"], [/store|mall|shop|market/, "shopping-bag"], [/stadium|sports/, "volleyball"], [/lodging|hotel/, "hotel"], [/transit|station|airport/, "train-front"]];
const iconFor = types => icon((TYPE_ICONS.find(([re]) => re.test([].concat(types || []).join(" ").toLowerCase())) || [0, "map-pin"])[1]);
const MILES = /^en-US|^en-LR|^my/.test(navigator.language || "");
const howFar = m => m == null ? "" : MILES ? (m < 160 ? `${Math.round(m * 3.281)} ft` : `${(m / 1609).toFixed(m < 16090 ? 1 : 0)} mi`)
  : m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(m < 10000 ? 1 : 0)} km`;
const recentKey = "omwRecentPlaces";
const recents = () => { try { return JSON.parse(localStorage.getItem(recentKey)) || []; } catch { return []; } };
const remember = p => { try { localStorage.setItem(recentKey, JSON.stringify([{ name: p.name, address: p.address, lat: p.lat, lng: p.lng },
  ...recents().filter(r => r.name !== p.name)].slice(0, 5))); } catch { /* private mode */ } };
// bold the part of the name you typed
const highlight = (text, q) => { const i = text.toLowerCase().indexOf(q.toLowerCase());
  return i < 0 || !q ? esc(text) : `${esc(text.slice(0, i))}<b class="hit">${esc(text.slice(i, i + q.length))}</b>${esc(text.slice(i + q.length))}`; };

let searchTimer, found = [], active = -1, session = null, lastQuery = "", resultsQuery = "";
const resultPins = L.layerGroup().addTo(map);
const hideSuggest = () => { $("suggest").style.display = "none"; active = -1; };
const whereQs = () => { const c = map.getCenter(), me = window.myFix?.here;
  return `lat=${c.lat}&lng=${c.lng}${me ? `&here_lat=${me[0]}&here_lng=${me[1]}` : ""}`; };
function showList(html, items) {
  found = items; active = -1;
  $("suggest").innerHTML = html;
  $("suggest").style.display = "block";
}

async function pickPlace(p) {
  hideSuggest();
  $("placeInput").blur();
  if (p.kind === "query") return runSearch(p.text);
  if (p.lat == null && p.id) {  // a Google suggestion: look up where it is
    try { p = { ...p, ...(await (await fetch(`${API}/places/details?id=${encodeURIComponent(p.id)}${session ? `&session=${session}` : ""}`)).json()) }; }
    catch { return; }
    session = null;  // a typing session ends when you pick something
  }
  resultPins.clearLayers(); $("searchArea").hidden = true;
  remember(p);
  setVenue([p.lat, p.lng], p.name, p.address);
  map.flyTo([p.lat, p.lng], 16);
}

// empty box: quick categories + recent spots
function showStart() {
  const r = recents();
  showList(`<div class="chips">${CATEGORIES.map(([e, n]) => `<button class="chip" data-cat="${esc(n)}">${icon(e)} ${esc(n)}</button>`).join("")}</div>`
    + (r.length ? `<div class="list-head">Recent</div>` + r.map((p, i) => `<div class="opt" data-i="${i}"><i>${icon("history")}</i><div><b>${esc(p.name)}</b><span>${esc(p.address)}</span></div></div>`).join("") : ""),
    r.map(p => ({ ...p, kind: "place" })));
}

// typing: suggestions
async function showSuggestions(q) {
  session ||= crypto.randomUUID?.() || String(Math.random()).slice(2);
  let items = [];
  try { items = await (await fetch(`${API}/places/suggest?q=${encodeURIComponent(q)}&${whereQs()}&session=${session}`)).json(); } catch { /* offline */ }
  if ($("placeInput").value.trim() !== q) return;  // you kept typing
  // always offer "search for what I typed" first, like Google Maps
  if (!items.some(s => s.kind === "query" && s.text.toLowerCase() === q.toLowerCase())) items.unshift({ kind: "query", text: q });
  showList(items.map((s, i) => s.kind === "query"
      ? `<div class="opt" data-i="${i}"><i>${icon("search")}</i><div><b>${highlight(s.text, q)}</b><span>Search nearby</span></div></div>`
      : `<div class="opt" data-i="${i}"><i>${iconFor(s.types)}</i><div><b>${highlight(s.name, q)}</b><span>${esc(s.address)}</span></div>${s.distance_m != null ? `<em>${howFar(s.distance_m)}</em>` : ""}</div>`).join(""), items);
}

// Enter / a category / "Search this area": a full list, pinned on the map
async function runSearch(q) {
  resultsQuery = q;
  $("mapHint").style.display = "none";
  $("placeInput").value = q; $("clearPlace").hidden = false;
  showList(`<div class="none">Searching for ${esc(q)}…</div>`, []);
  let items = [];
  try { items = await (await fetch(`${API}/places/search?q=${encodeURIComponent(q)}&${whereQs()}`)).json(); } catch { /* offline */ }
  resultPins.clearLayers();
  if (!items.length) return showList(`<div class="none">Nothing found for “${esc(q)}” around here. Try another word, or tap the map.</div>`, []);
  items.forEach((p, i) => L.marker([p.lat, p.lng], { icon: L.divIcon({ className: "", iconSize: [30, 30], iconAnchor: [15, 30],
      html: `<div class="result-pin"><span>${i + 1}</span></div>` }) })
    .bindTooltip(esc(p.name), { direction: "top", offset: [0, -28] }).on("click", () => pickPlace(p)).addTo(resultPins));
  map.fitBounds(L.latLngBounds(items.map(p => [p.lat, p.lng])).pad(0.2), { maxZoom: 16, paddingTopLeft: [innerWidth > 800 ? 440 : 0, 80] });
  const stars = p => p.rating ? `<span class="stars">${icon("star", "star")} ${p.rating.toFixed(1)}</span>${p.reviews ? ` (${p.reviews.toLocaleString()})` : ""}` : "";
  showList(`<div class="list-head">Results for “${esc(q)}”</div>` + items.map((p, i) => `<div class="opt" data-i="${i}"><i class="num">${i + 1}</i><div>
      <b>${esc(p.name)}</b>
      <span>${[stars(p), p.price, esc(p.type)].filter(Boolean).join(" · ")}</span>
      <span>${p.open === true ? `<span class="open">Open now</span> · ` : p.open === false ? `<span class="closed">Closed</span> · ` : ""}${esc(p.address)}</span>
    </div>${p.distance_m != null ? `<em>${howFar(p.distance_m)}</em>` : ""}</div>`).join(""), items);
  setTimeout(() => ($("searchArea").hidden = true), 800);  // fitBounds moves the map; only offer it after *you* move it
}

$("suggest").onmousedown = e => {
  e.preventDefault();  // keep the box focused
  const cat = e.target.closest("[data-cat]"), opt = e.target.closest(".opt");
  if (cat) runSearch(cat.dataset.cat);
  else if (opt) pickPlace(found[+opt.dataset.i]);
};
$("placeInput").onfocus = () => { if (!$("placeInput").value.trim()) showStart(); else if (found.length) $("suggest").style.display = "block"; };
$("placeInput").oninput = () => {
  clearTimeout(searchTimer);
  const q = $("placeInput").value.trim();
  $("clearPlace").hidden = !q && !venue;
  if (!q) return showStart();
  if (q.length < 2) return;
  searchTimer = setTimeout(() => { lastQuery = q; showSuggestions(q); }, 180);
};
$("placeInput").onkeydown = e => {
  const opts = $("suggest").querySelectorAll(".opt");
  if (e.key === "Enter") {
    e.preventDefault();
    const q = $("placeInput").value.trim();
    if (active >= 0 && found[active]) pickPlace(found[active]);
    else if (q) { clearTimeout(searchTimer); runSearch(q); }
  } else if ((e.key === "ArrowDown" || e.key === "ArrowUp") && opts.length) {
    e.preventDefault();
    active = (active + (e.key === "ArrowDown" ? 1 : -1) + opts.length) % opts.length;
    opts.forEach((o, i) => o.classList.toggle("active", i === active));
    opts[active].scrollIntoView({ block: "nearest" });
  } else if (e.key === "Escape") { hideSuggest(); $("placeInput").blur(); }
};
$("placeInput").onblur = () => setTimeout(hideSuggest, 150);
// moved the map after a search: offer to search again there
map.on("moveend", () => { if (resultPins.getLayers().length) $("searchArea").hidden = false; });
$("searchArea").onclick = () => { $("searchArea").hidden = true; runSearch(resultsQuery); };

// ---------- form ----------
// categories: the defaults plus any you make (saved to your profile by friends.js)
const allTypes = () => [...TYPES, ...(window.myCategories || []).map(c => [c.id, c.emoji, c.name, true])];
const EMOJIS = ("pizza soup sandwich fish cup-soda ice-cream-cone croissant beer wine ticket clapperboard popcorn gamepad-2 mic music guitar palette dices "
  + "volleyball dumbbell mountain waves bike footprints tent-tree shopping-bag cake graduation-cap laptop heart-handshake dog trees camera drama").split(" ");  // icon names
function renderTypes() {
  const was = document.querySelector("input[name=type]:checked")?.value || "food", editing = !$("typeForm").hidden;
  const types = allTypes(), keep = types.some(t => t[0] === was) ? was : "food";
  $("types").innerHTML = types.map(([v, e, n, mine]) =>
    `<label class="type"><input type="radio" name="type" value="${esc(v)}" ${v === keep ? "checked" : ""}><span>${glyph(e)} ${esc(n)}${
      mine && editing ? `<i data-del-type="${esc(v)}" title="Delete">${icon("x")}</i>` : ""}</span></label>`).join("") +
    `<button class="type-add" id="typeAdd">${editing ? "Done" : `${icon("plus")} New`}</button>`;
  $("typeAdd").onclick = () => { $("typeForm").hidden = !$("typeForm").hidden; renderTypes(); if (!$("typeForm").hidden) $("newName").focus(); };
}
const pickIcon = v => { $("newEmoji").dataset.v = v; $("newEmoji").innerHTML = icon(v);
  $("emojiPick").querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.v === v)); };
$("emojiPick").innerHTML = EMOJIS.map(e => `<button type="button" data-v="${e}" title="${e.replace(/-/g, " ")}">${icon(e)}</button>`).join("");
$("emojiPick").onclick = e => { const b = e.target.closest("button"); if (b) pickIcon(b.dataset.v); };
pickIcon("star");
async function addType() {
  const name = $("newName").value.trim(), emoji = $("newEmoji").dataset.v || "star";
  if (!name) return $("newName").focus();
  if (!window.saveCategories) return alert("Sign in to save your own categories.");
  const id = "c_" + name.toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 20) + "-" + Math.random().toString(36).slice(2, 6);
  await window.saveCategories([...(window.myCategories || []), { id, emoji, name }]);
  window.myCategories = [...(window.myCategories || []), { id, emoji, name }];  // pick it right away
  $("newName").value = ""; pickIcon("star");
  renderTypes();
  document.querySelector(`input[name=type][value="${id}"]`).checked = true;
  venue && setVenue(venue, venueName, venueAddress);
}
$("typeSave").onclick = addType;
$("newName").onkeydown = e => { if (e.key === "Enter") addType(); };
$("types").onclick = async e => {
  const del = e.target.closest("[data-del-type]");
  if (!del) return;
  e.preventDefault();
  const id = del.dataset.delType;
  window.myCategories = (window.myCategories || []).filter(c => c.id !== id);
  renderTypes();
  await window.saveCategories?.(window.myCategories);
};
window.addEventListener("friends-changed", renderTypes);
renderTypes();
const selectedType = () => document.querySelector("input[name=type]:checked")?.value || "food";
$("types").onchange = () => venue && setVenue(venue, venueName, venueAddress);

// starts on the next full hour (4:13pm → 5pm); late in the evening, when there's barely any day left, tomorrow at 7pm
const lateTonight = () => { const n = new Date(); n.setMinutes(0, 0, 0); n.setHours(n.getHours() + 1); return n.getHours() >= 23 || n.getHours() < 7; };
{ const first = new Date(); first.setMinutes(0, 0, 0); first.setHours(first.getHours() + 1);
  if (lateTonight()) { if (first.getHours() >= 7) first.setDate(first.getDate() + 1); first.setHours(19); }
  $("start").value = new Date(first - first.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); }

// ---------- when: quick day and time chips (the datetime box underneath is still what everything reads) ----------
const nextHour = () => { const d = new Date(); d.setMinutes(0, 0, 0); d.setHours(d.getHours() + 1); return d; };  // the first time still worth suggesting
function showWhen() {
  const cur = $("start").value ? new Date($("start").value) : null, now = new Date(), sameDay = (a, b) => a && b && a.toDateString() === b.toDateString();
  $("whenSum").textContent = cur ? `${cur.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" })} · ${cur.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}` : "Pick a day and time";
  const days = Array.from({ length: 7 }, (_, i) => { const d = new Date(now); d.setDate(now.getDate() + i); return d; });
  const todayOver = lateTonight();  // 11pm or later: nothing left today worth suggesting
  $("dayChips").innerHTML = days.map((d, i) => `<button class="${sameDay(d, cur) ? "on" : ""}" data-day="${i}" ${i === 0 && todayOver ? "disabled" : ""} title="${d.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" })}">
      <small>${i === 0 ? "Today" : d.toLocaleDateString([], { weekday: "short" })}</small><b>${d.getDate()}</b></button>`).join("");
  // the hours people actually meet (7am to 11pm); today starts at the next full hour (4:20pm → 5pm). Custom does any time.
  const first = Math.max(7, sameDay(cur, now) ? nextHour().getHours() : 7), hm = cur ? [cur.getHours(), cur.getMinutes()] : null;
  const hours = sameDay(cur, now) && todayOver ? [] : Array.from({ length: Math.max(0, 24 - first) }, (_, i) => first + i);
  const row = $("timeChips");
  row.innerHTML = hours.map(h => `<button class="${hm && h === hm[0] && !hm[1] ? "on" : ""}" data-time="${h}:0">${(h + 11) % 12 + 1}${h < 12 ? "am" : "pm"}</button>`).join("");
  // bring the chosen hour (or, on another day, the evening) into view without moving the page
  // (worked out from the chip size, so it's right even before the row is on screen)
  const at = hm ? hours.indexOf(hm[0]) : -1;
  row.scrollLeft = at > 0 ? (at - 1) * 68 : 0;
  $("whenCustom").classList.toggle("on", !$("start").hidden);
}
function setWhen(d) {
  $("start").value = localIso(d);
  $("start").dispatchEvent(new Event("change"));
}
$("whenCustom").onclick = () => {
  $("start").hidden = !$("start").hidden;
  showWhen();
  if (!$("start").hidden) { $("start").focus(); try { $("start").showPicker(); } catch { } }
};
$("dayChips").onclick = e => {
  const b = e.target.closest("button");
  if (!b) return;
  const cur = $("start").value ? new Date($("start").value) : null, d = new Date();
  d.setDate(d.getDate() + +b.dataset.day);
  d.setHours(cur ? cur.getHours() : 19, cur ? cur.getMinutes() : 0, 0, 0);
  if (d < new Date()) d.setTime(nextHour());  // today, but that time has passed: the next full hour
  setWhen(d);
};
$("timeChips").onclick = e => {
  const b = e.target.closest("button");
  if (!b) return;
  const [h, m] = b.dataset.time.split(":").map(Number), d = $("start").value ? new Date($("start").value) : new Date();
  d.setHours(h, m, 0, 0);
  setWhen(d);
};
$("start").addEventListener("change", showWhen);
// Muse, "find a time" and opening a plan set the time directly: keep the chips in step
{ const box = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value"), el = $("start");
  Object.defineProperty(el, "value", { get() { return box.get.call(this); }, set(v) { box.set.call(this, v); queueMicrotask(showWhen); } }); }
showWhen();

// ---------- weather: the forecast at the spot for the chosen hour (the model uses it too) ----------
const here = () => venue || [map.getCenter().lat, map.getCenter().lng];
// °F in the US, °C everywhere else
const FAHRENHEIT = /-US$|^en$/.test(navigator.language || "en-US");
const deg = c => c == null ? "–" : `${Math.round(FAHRENHEIT ? c * 9 / 5 + 32 : c)}°`;
// the same forecast straight from Open-Meteo (free, no key), for when our server can't reach it (shared cloud servers get
// turned away sometimes; a phone never does)
const WX = [[[0], "sun", "Clear"], [[1, 2], "cloud-sun", "Mostly sunny"], [[3], "cloud", "Cloudy"], [[45, 48], "cloud-fog", "Foggy"],
  [[51, 67], "cloud-rain", "Rain"], [[71, 77], "snowflake", "Snow"], [[80, 82], "cloud-drizzle", "Showers"], [[85, 86], "snowflake", "Snow showers"],
  [[95, 99], "cloud-lightning", "Storms"]];
const wxLook = c => { const m = WX.find(([r]) => r.length > 1 ? c >= r[0] && c <= r[1] : c === r[0]); return m ? [m[1], m[2]] : ["thermometer", "Weather"]; };
async function weatherDirect(lat, lng, time) {
  const q = new URLSearchParams({ latitude: lat.toFixed(2), longitude: lng.toFixed(2), timezone: "auto", forecast_days: 16,
    hourly: "precipitation_probability,precipitation,weather_code,temperature_2m", current: "temperature_2m,apparent_temperature,weather_code,precipitation" });
  const d = await (await fetch(`https://api.open-meteo.com/v1/forecast?${q}`)).json();
  const H = d.hourly, at = t => H.time.indexOf(t), slot = time.slice(0, 13) + ":00";
  const hourOf = (i, t, hangout) => { const [ic] = wxLook(H.weather_code[i]); return { time: t, icon: ic, temp_c: H.temperature_2m[i], rain_chance: H.precipitation_probability[i], hangout }; };
  const i = at(slot), [nIcon, nLabel] = wxLook(d.current.weather_code), [hIcon, hLabel] = i >= 0 ? wxLook(H.weather_code[i]) : [];
  const hours = [];
  for (let k = -2; k <= 3; k++) {
    const t = new Date(new Date(slot).getTime() + k * 36e5), key = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}T${String(t.getHours()).padStart(2, "0")}:00`;
    if (at(key) >= 0) hours.push(hourOf(at(key), key, k === 0));
  }
  return { now: { icon: nIcon, label: nLabel, temp_c: d.current.temperature_2m, feels_c: d.current.apparent_temperature },
           known: i >= 0, icon: hIcon, label: hLabel, temp_c: i >= 0 ? H.temperature_2m[i] : null, rain_chance: i >= 0 ? H.precipitation_probability[i] : null,
           raining: i >= 0 && ((H.precipitation_probability[i] || 0) >= 50 || (H.precipitation[i] || 0) >= .3), hours };
}
// the town you're in (or looking at), for "Weather in Atlanta": from the address the place lookup gives back
// ("633 Techwood Dr NW, Atlanta, GA 30313, USA" → Atlanta), remembered per area so moving the map doesn't ask again
async function placeOf(lat, lng) {
  const key = `${lat.toFixed(2)},${lng.toFixed(2)}`;
  placeOf.seen ||= {};
  if (!(key in placeOf.seen)) {
    placeOf.seen[key] = fetch(`${API}/place-name?lat=${lat}&lng=${lng}`).then(r => r.json()).then(p => {
      const parts = String(p.address || "").split(",").map(x => x.trim()).filter(Boolean);
      return parts.length >= 3 ? parts[parts.length - 3] : parts.length === 2 ? parts[0] : "";
    }).catch(() => "");
  }
  const town = await placeOf.seen[key];
  if (town) placeOf.last = town;
  return town;
}
async function showWeather() {
  const [lat, lng] = here(), time = $("start").value;
  if (!time) return;
  try {
    let w = await fetch(`${API}/weather?lat=${lat}&lng=${lng}&time=${time}`).then(r => r.json()).catch(() => ({}));
    if (!w.now && !w.known) w = await weatherDirect(lat, lng, time);
    if ($("start").value !== time) return;  // the time changed while we waited
    $("wxWhere").textContent = venue ? `at ${venueName}` : placeOf.last ? `in ${placeOf.last}` : "near you";
    if (!venue) placeOf(lat, lng).then(town => { if (town && !venue && $("start").value === time) $("wxWhere").textContent = `in ${town}`; });
    const when = new Date(time), hour = t => new Date(t).toLocaleTimeString([], { hour: "numeric" }).replace(/\s/g, "").toLowerCase();
    const day = when.toLocaleDateString([], { weekday: "long" }), rain = w.rain_chance ?? 0;
    const top = w.known ? `<div class="wx-top"><span class="wx-glyph">${glyph(w.icon)}</span><span class="wx-temp">${deg(w.temp_c)}</span>
        <span class="wx-what"><b>${esc(w.label)}</b><span>${esc(day)} ${hour(when)}${rain ? ` · ${rain}% rain` : ""}</span></span></div>`
      : `<div class="wx-what" style="text-align:left"><b>No forecast yet</b><span>It shows up about two weeks out</span></div>`;
    const now = w.now ? `<div class="wx-now">Now ${deg(w.now.temp_c)}, ${esc(w.now.label.toLowerCase())}, feels like ${deg(w.now.feels_c)}</div>` : "";
    const hours = w.hours?.length ? `<div class="wx-hours">${w.hours.map(x => `<div class="${x.hangout ? "on" : ""}"><span>${hour(x.time)}</span>
         <i>${glyph(x.icon)}</i><b>${deg(x.temp_c)}</b><small>${x.rain_chance >= 20 ? `${x.rain_chance}%` : ""}</small></div>`).join("")}</div>` : "";
    $("wx").innerHTML = top + now + hours + (w.raining ? `<div class="wx-note">Rain's likely. Maybe somewhere indoors.</div>` : "");
  } catch { $("wx").innerHTML = `<div class="wx-now">Couldn't get the forecast right now</div>`; }
}
$("start").onchange = showWeather;
let wxTimer;  // no spot picked yet: follow the map, but only once it stops moving
map.on("moveend", () => { if (!venue) { clearTimeout(wxTimer); wxTimer = setTimeout(showWeather, 600); } });
showWeather();

// "Who": you're always in; search your friends list and tap to add or remove people for this plan
const myFriends = () => window.myFriends || [];
const myId = () => myFriends().find(p => p.isMe)?.user_id;
const picked = new Set();  // friends chosen for this plan
const MODE_LABEL = { driving: "Drives", walking: "Walks", cycling: "Bikes", transit: "Takes transit" };
const pickedIds = () => myFriends().filter(p => p.isMe || picked.has(p.user_id)).map(p => p.user_id);
window.omwMap = map;  // the Map tab (maptab.js) draws friends and saved places on it
window.openPlanner = () => { toggleSheet(false); window.invalidateMap?.(); };  // the + tab
window.pickPlace = (ll, name, address) => setVenue(ll, name, address);  // a saved place or a friend's spot on the Map tab
// the feed: tap a friend who's free, or "Plan this" on a post
window.planWith = ids => { picked.clear(); ids.forEach(id => picked.add(id)); showFriends(); toggleSheet(false); };
window.planAt = (ll, name, address) => { setVenue(ll, name, address); map.setView(ll, 15); toggleSheet(false); };
window.invalidateMap = () => setTimeout(() => map.invalidateSize(), 50);
function showFriends() {
  const everyone = myFriends(), others = everyone.filter(p => !p.isMe);
  people = everyone;
  everyone.forEach((p, i) => colorOf[p.user_id] = COLORS[i % COLORS.length]);
  for (const id of picked) if (!others.some(p => p.user_id === id)) picked.delete(id);  // unfriended

  // who's in: tap a face to take them out again
  const chosen = everyone.filter(p => p.isMe || picked.has(p.user_id));
  $("friends").innerHTML = chosen.map(p =>
    `<label class="friend ${p.isMe ? "" : "removable"}" style="--c:${colorOf[p.user_id]}" ${p.isMe ? "" : `data-unpick="${esc(p.user_id)}"`}
       title="${p.isMe ? "You're always in" : "Tap to remove"}"><input type="checkbox" checked disabled>${avatar(p)}<small>${esc(p.name)}</small></label>`).join("")
    // the rest of your friends stay tucked away until you tap Add
    + `<button class="friend add-tile ${$("whoPick").hidden ? "" : "on"}" id="whoAdd" type="button"><i>${icon($("whoPick").hidden ? "plus" : "check")}</i><small>${$("whoPick").hidden ? "Add" : "Done"}</small></button>`;
  $("whoCount").textContent = picked.size ? `· ${picked.size + 1} people` : "";

  // your friends list, filtered by the search box (name or friend ID)
  const q = $("friendSearch").value.trim().toLowerCase();
  const match = others.filter(p => !q || p.name.toLowerCase().includes(q) || (p.code || "").toLowerCase().includes(q));
  $("friendSearch").parentElement.hidden = !others.length;
  $("pickAll").textContent = others.length > 1 ? (others.every(p => picked.has(p.user_id)) ? "Clear all" : "Select all") : "";
  $("friendPick").innerHTML = !others.length
    ? `<div class="pick-empty">No friends yet. Add some from your profile (top left) to plan with them.</div>`
    : match.length ? match.map(p => `<div class="pick-row ${picked.has(p.user_id) ? "on" : ""}" data-pick="${esc(p.user_id)}">${avatar(p)}
        <div class="who"><b>${esc(p.name)}</b><small>${p.travel_mode ? icon(MODE_ICON[p.travel_mode]) + " " : ""}${MODE_LABEL[p.travel_mode] || ""}${p.home ? "" : " · no home set yet"}</small></div>
        <div class="tick">${picked.has(p.user_id) ? icon("check") : ""}</div></div>`).join("")
    : `<div class="pick-empty">No friend named “${esc(q)}”</div>`;
}
$("friendPick").onclick = e => {
  const row = e.target.closest("[data-pick]");
  if (!row) return;
  picked.has(row.dataset.pick) ? picked.delete(row.dataset.pick) : picked.add(row.dataset.pick);
  showFriends();
};
$("friends").onclick = e => {
  if (e.target.closest("#whoAdd")) {
    $("whoPick").hidden = !$("whoPick").hidden;
    showFriends();
    if (!$("whoPick").hidden) setTimeout(() => $("friendSearch").focus({ preventScroll: true }), 0);
    return;
  }
  const face = e.target.closest("[data-unpick]");
  if (!face) return;
  e.preventDefault();
  picked.delete(face.dataset.unpick);
  showFriends();
};
$("friendSearch").oninput = showFriends;
$("friendSearch").onkeydown = e => {  // Enter picks the first match
  if (e.key !== "Enter") return;
  const first = $("friendPick").querySelector("[data-pick]");
  if (first) { picked.add(first.dataset.pick); $("friendSearch").value = ""; showFriends(); }
};
$("pickAll").onclick = () => {
  const others = myFriends().filter(p => !p.isMe);
  const all = others.every(p => picked.has(p.user_id));
  others.forEach(p => all ? picked.delete(p.user_id) : picked.add(p.user_id));
  showFriends();
};
window.addEventListener("friends-changed", showFriends);

// ---------- find a time ----------
const localDate = d => new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10);
$("findBtn").onclick = async () => {
  const user_ids = pickedIds();
  if (user_ids.length < 2) return $("slots").innerHTML = `<div class="slot-note">Pick who's coming first: search your friends above.</div>`;
  $("findBtn").disabled = true; $("findBtn").textContent = "Checking everyone's week…";
  try {
    const res = await fetch(`${API}/find-times`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_ids, hangout_type: selectedType(), from_date: localDate(new Date()),
                             now: new Date(Date.now() - new Date().getTimezoneOffset() * 6e4).toISOString().slice(0, 16), venue: here(),
                             guests: myFriends().filter(p => user_ids.includes(p.user_id))
                               .map(({ user_id, name, travel_mode, home, busy, habits }) => ({ user_id, name, travel_mode, home, busy, habits })) }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || res.statusText);
    const when = iso => new Date(iso).toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
    $("slots").innerHTML = data.slots.length
      ? data.slots.map((s, i) => `<div class="slot ${i ? "" : "best"}" data-start="${s.start}">
            <span>${i ? "" : icon("star", "star") + " "}${when(s.start)}</span><small>${s.weather.known ? glyph(s.weather.icon) + " " : ""}~${Math.round(s.avg_delay_min)} min late on avg</small></div>`).join("") +
        ""
      : `<div class="slot-note">${esc(data.message)}</div>`;
    document.querySelectorAll(".slot").forEach(el => el.onclick = () => {
      $("start").value = el.dataset.start;
      showWeather();
      document.querySelectorAll(".slot").forEach(x => x.classList.toggle("on", x === el));
    });
  } catch (e) {
    $("slots").innerHTML = `<div class="slot-note">${esc(friendly(e, "find times"))}</div>`;
  } finally {
    $("findBtn").disabled = false; $("findBtn").innerHTML = `${icon("calendar-days")} Find a time everyone's free`;
  }
};

// ---------- plan ----------
const fmt = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const minutesBetween = (a, b) => Math.round((new Date(b) - new Date(a)) / 6e4);

// ---------- directions, like Google Maps ----------
// from where you are now (or your home), every way to get there with times, then turn by turn or which bus to take
const DIR_MODES = { driving: "Drive", transit: "Transit", walking: "Walk", cycling: "Bike" };
const GMAPS_MODE = { driving: "driving", transit: "transit", walking: "walking", cycling: "bicycling" };
const localIso = d => new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16);
const dirLayer = L.layerGroup().addTo(map);
const TURN = [[/uturn/i, "undo-2"], [/sharp.?left|SHARP_LEFT/i, "corner-up-left"], [/sharp.?right|SHARP_RIGHT/i, "corner-up-right"], [/slight.?left|SLIGHT_LEFT|keep.?left|FORK_LEFT/i, "arrow-up-left"],
  [/slight.?right|SLIGHT_RIGHT|keep.?right|FORK_RIGHT/i, "arrow-up-right"], [/left/i, "corner-up-left"], [/right/i, "corner-up-right"], [/roundabout/i, "refresh-cw"], [/merge|ramp/i, "merge"],
  [/depart|straight|continue|name|DEPART/i, "arrow-up"], [/arrive/i, "flag"]];
// driving: what the traffic model expects when they leave, e.g. " · traffic +14% at 2:33 PM, rain"
const trafficNote = t => { const pct = Math.round((t.ratio - 1) * 100), at = new Date(t.leave).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return ` · ${t.basis === "live" ? "live traffic" : pct > 2 ? `traffic +${pct}% at ${at}` : pct < -2 ? `light roads at ${at}` : `usual traffic at ${at}`}${
    t.weather && t.weather !== "clear" ? `, ${t.weather === "heavy" ? "heavy rain" : t.weather}` : ""}`; };
const turnIcon = m => icon((TURN.find(([re]) => re.test(m || "")) || [0, "arrow-up"])[1]);
let dirState = null;  // { venue, name, start, mode, origin, originLabel, results: { mode: directions } }

async function openDirections({ venue: dest, name, start, mode, from, fromLabel }) {
  const live = window.myFix && Date.now() - window.myFix.at < 5 * 6e4 ? window.myFix.here : null;
  const home = myFriends().find(p => p.isMe)?.home;
  const origin = live || from || home;  // where you are right now, else where you said you're leaving from, else home
  $("dir").hidden = false;
  $("dirTitle").textContent = `To ${name || "the spot"}`;
  if (!origin) {
    $("dirFrom").textContent = ""; $("dirModes").innerHTML = $("dirOpen").innerHTML = $("dirSteps").innerHTML = "";
    return $("dirSum").textContent = "Allow location, or set your home in your profile, to get directions.";
  }
  dirState = { venue: dest, name, start, mode: DIR_MODES[mode] ? mode : "driving", origin,
               originLabel: live ? "From your location" : from ? fromLabel || "From where you're leaving" : "From home", results: {} };
  $("dirFrom").textContent = dirState.originLabel;
  renderDirections();
  // every way at once, so the tabs show their times like Google Maps
  await Promise.all(Object.keys(DIR_MODES).map(async m => {
    try {
      const res = await fetch(`${API}/directions`, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ origin, venue: dest, mode: m, start_time: start || null, utc_offset_min: -new Date().getTimezoneOffset() }) });
      if (!res.ok) throw new Error();
      if (dirState?.venue === dest) { dirState.results[m] = await res.json(); renderDirections(); }
    } catch { if (dirState?.venue === dest) { dirState.results[m] = { error: true }; renderDirections(); } }
  }));
}
window.openDirections = openDirections;

function renderDirections() {
  const s = dirState, d = s.results[s.mode], dist = m => m == null ? "" : howFar(m);
  $("dirModes").innerHTML = Object.entries(DIR_MODES).map(([m, label]) => {
    const r = s.results[m];
    return `<button class="${m === s.mode ? "on" : ""}" data-dmode="${m}">${icon(MODE_ICON[m])}<span>${label}</span><small>${!r ? "…" : r.error ? "n/a" : `${Math.round(r.minutes)} min`}</small></button>`;
  }).join("");
  const g = `https://www.google.com/maps/dir/?api=1&origin=${s.origin.join(",")}&destination=${s.venue.join(",")}&travelmode=${GMAPS_MODE[s.mode]}`;
  // navigation happens inside omw; the Google Maps link (g) is only a backup if Google's map can't load
  $("dirOpen").innerHTML = `<button id="navStart">${icon("navigation")} Start</button>`;
  $("navStart").onclick = () => startNav(g);
  showGoogleRoute();
  dirLayer.clearLayers();
  if (!d) { $("dirSum").innerHTML = "Getting directions…"; $("dirSteps").innerHTML = ""; return; }
  if (d.error) { $("dirSum").innerHTML = `No ${DIR_MODES[s.mode].toLowerCase()} route found. Try another way.`; $("dirSteps").innerHTML = ""; return; }
  const now = new Date(), arrive = new Date(now.getTime() + d.minutes * 6e4), start = s.start ? new Date(s.start) : null;
  const leaveBy = start && new Date(start.getTime() - d.minutes * 6e4);
  $("dirSum").innerHTML = `<div class="big">${Math.round(d.minutes)} min <small>(${dist(d.distance_m)})</small></div>
    <div>Leave now, arrive <span class="eta">${fmt(arrive.toISOString())}</span>${d.source === "google" ? " · Google Maps" : d.source === "estimate" ? " · rough estimate" : ""}</div>
    ${leaveBy && leaveBy > now ? `<div>To be there by ${fmt(start.toISOString())}, leave by <b>${fmt(leaveBy.toISOString())}</b></div>`
      : start && start > now ? `<div class="late">Leave now: you'll be ${Math.round((arrive - start) / 6e4)} min late</div>` : ""}`;
  $("dirSteps").innerHTML = d.steps.length ? d.steps.map(st => st.transit ? `<li><i>${icon(/bus/i.test(st.transit.vehicle) ? "bus" : /rail|train|subway|metro|tram/i.test(st.transit.vehicle) ? "train-front" : "signpost")}</i><div>
        <span class="line-badge" style="background:${esc(st.transit.color || "#1e88ff")};color:${esc(st.transit.text_color || "#fff")}">${esc(st.transit.line || st.transit.vehicle)}</span>
        toward ${esc(st.transit.headsign)}
        <small>Get on at ${esc(st.transit.from)}${st.transit.departs ? ` · ${esc(st.transit.departs)}` : ""}</small>
        <small>${st.transit.stops ? `${st.transit.stops} stops · ` : ""}get off at ${esc(st.transit.to)}${st.transit.arrives ? ` · ${esc(st.transit.arrives)}` : ""}</small></div></li>`
      : `<li><i>${turnIcon(st.maneuver || st.text)}</i><div>${esc(st.text || "Continue")}<small>${[dist(st.distance_m), st.minutes >= 1 ? `${Math.round(st.minutes)} min` : ""].filter(Boolean).join(" · ")}</small></div></li>`).join("")
      + `<li><i>${icon("flag")}</i><div>${esc(s.name || "You're there")}</div></li>`
    : `<li><i>${icon("info")}</i><div>No turn-by-turn for this one. Tap Start to navigate.</div></li>`;
  const line = L.polyline(d.path, { color: "#1e88ff", weight: 7, opacity: .9 }).addTo(dirLayer);
  L.circleMarker(s.origin, { radius: 7, color: "#fff", weight: 3, fillColor: "#1e88ff", fillOpacity: 1 }).addTo(dirLayer);
  map.fitBounds(line.getBounds().pad(0.15), { paddingTopLeft: [innerWidth > 860 ? 440 : 20, 80], paddingBottomRight: [innerWidth > 860 ? 400 : 20, innerWidth > 860 ? 20 : innerHeight * 0.6] });
}
$("dirModes").onclick = e => { const b = e.target.closest("[data-dmode]"); if (b && dirState) { dirState.mode = b.dataset.dmode; renderDirections(); } };
$("dirClose").onclick = () => { $("dir").hidden = true; dirState = null; dirLayer.clearLayers(); };

// ---------- Google Maps inside omw ----------
// The directions panel shows Google's own map of the route (live traffic when driving), and ▶ Start opens
// full-screen turn-by-turn that follows you, talks, and reroutes if you go off course. Needs "Maps JavaScript API"
// (and "Directions API") turned on for the key. If Google won't load, everything falls back to the omw map
// and "Google Maps app".
const G_MODE = { driving: "DRIVING", walking: "WALKING", cycling: "BICYCLING", transit: "TRANSIT" };
let gmLoading = null, googleBroken = false, gPanel = null, gRenderer = null, gTraffic = null, gLine = null;
function loadGoogle() {
  if (!GKEY || googleBroken) return Promise.reject(new Error("no Google Maps key"));
  gmLoading ||= new Promise((ok, fail) => {
    window.__gmReady = () => ok(google.maps);
    window.gm_authFailure = () => {  // Google calls this when the key isn't allowed here
      googleBroken = true; $("gmap").hidden = true;
      console.warn("[omw] Google Maps refused the key: turn on Maps JavaScript API and allow this website for the key");
      if (!$("nav").hidden) { endNav(); if (dirState) window.open(`https://www.google.com/maps/dir/?api=1&origin=${dirState.origin.join(",")}&destination=${dirState.venue.join(",")}&travelmode=${GMAPS_MODE[dirState.mode]}`, "_blank"); }
    };
    const tag = document.createElement("script");
    tag.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(GKEY)}&v=weekly&libraries=geometry&callback=__gmReady&loading=async`;
    tag.async = true;
    tag.onerror = () => { googleBroken = true; fail(new Error("Google Maps didn't load")); };
    document.head.appendChild(tag);
  });
  return gmLoading;
}
const LL = ([lat, lng]) => ({ lat, lng });
function googleRoute(origin, dest, mode, start) {
  const req = { origin: LL(origin), destination: LL(dest), travelMode: G_MODE[mode] };
  if (mode === "driving") req.drivingOptions = { departureTime: new Date(), trafficModel: "bestguess" };
  if (mode === "transit" && start && new Date(start) > new Date()) req.transitOptions = { arrivalTime: new Date(start) };
  return new google.maps.DirectionsService().route(req);
}
const stripHtml = h => new DOMParser().parseFromString((h || "").replace(/<div[^>]*>/g, ". "), "text/html").body.textContent.replace(/\s+/g, " ").trim();

async function showGoogleRoute() {
  const s = dirState;
  if (!s || googleBroken || !GKEY) return;
  let gm;
  try { gm = await loadGoogle(); } catch { $("gmap").hidden = true; return; }
  if (dirState !== s || googleBroken) return;
  const mode = s.mode;
  s.google ||= {};
  s.google[mode] ||= googleRoute(s.origin, s.venue, mode, s.start).catch(e => { console.warn("[omw] Google route:", e.message); return null; });
  $("gmap").hidden = false;
  if (!gPanel) {
    gPanel = new gm.Map($("gmap"), { disableDefaultUI: true, zoomControl: true, clickableIcons: false, gestureHandling: "cooperative" });
    gRenderer = new gm.DirectionsRenderer({ polylineOptions: { strokeColor: "#1e88ff", strokeWeight: 6, strokeOpacity: .9 } });
    gTraffic = new gm.TrafficLayer();
  }
  const res = await s.google[mode];
  if (dirState !== s || s.mode !== mode) return;
  gTraffic.setMap(mode === "driving" ? gPanel : null);
  const drawn = res ? "g" : s.results[mode]?.path ? "p" : null;
  if (s.drawn === mode + drawn) return;  // already showing this
  s.drawn = mode + drawn;
  gLine?.setMap(null);
  if (res) { gRenderer.setMap(gPanel); gRenderer.setDirections(res); return; }
  gRenderer.setMap(null);
  if (!drawn) return;  // omw's own route line comes in a moment; this runs again then
  gLine = new gm.Polyline({ map: gPanel, path: s.results[mode].path.map(LL), strokeColor: "#1e88ff", strokeWeight: 6 });
  const box = new gm.LatLngBounds();
  s.results[mode].path.forEach(p => box.extend(LL(p)));
  gPanel.fitBounds(box, 30);
}

// ---------- ▶ Start: navigation ----------
let nav = null, navMap = null, navRenderer = null, navMe = null, navTraffic = null, navWatch = null, navLock = null;
const navVoiceOn = () => { try { return localStorage.getItem("navVoice") !== "off"; } catch { return true; } };
function say(text) {
  if (!navVoiceOn() || !("speechSynthesis" in window) || !text) return;
  speechSynthesis.cancel();
  speechSynthesis.speak(new SpeechSynthesisUtterance(text));
}

async function startNav(appLink) {
  const s = dirState;
  if (!s) return;
  let gm, res;
  try {
    gm = await loadGoogle();
    s.google ||= {};
    s.google[s.mode] ||= googleRoute(s.origin, s.venue, s.mode, s.start).catch(() => null);
    res = await s.google[s.mode];
  } catch { /* no Google */ }
  if (!res) return window.open(appLink, "_blank");  // no Google map: hand off to the Google Maps app instead
  $("nav").hidden = false;
  if (!navMap) {
    navMap = new gm.Map($("navMap"), { disableDefaultUI: true, zoomControl: true, clickableIcons: false, gestureHandling: "greedy" });
    navRenderer = new gm.DirectionsRenderer({ map: navMap, preserveViewport: true, polylineOptions: { strokeColor: "#1e88ff", strokeWeight: 8, strokeOpacity: .9 } });
    navMe = new gm.Marker({ map: navMap, zIndex: 999, icon: { path: gm.SymbolPath.CIRCLE, scale: 9, fillColor: "#1e88ff", fillOpacity: 1, strokeColor: "#fff", strokeWeight: 3 } });
    navTraffic = new gm.TrafficLayer();
    navMap.addListener("dragstart", () => { if (nav) { nav.follow = false; $("navRecenter").hidden = false; } });
  }
  nav = { s, mode: s.mode, follow: true, off: 0, lastReroute: 0, arrived: false, here: s.origin };
  useRoute(res);
  navTraffic.setMap(s.mode === "driving" ? navMap : null);
  navMap.setCenter(LL(s.origin)); navMap.setZoom(s.mode === "driving" ? 16 : 17);
  navMe.setPosition(LL(s.origin));
  $("navVoice").innerHTML = icon(navVoiceOn() ? "volume-2" : "volume-x");
  $("navRecenter").hidden = true;
  try { navLock = await navigator.wakeLock?.request("screen"); } catch { /* screen may still dim */ }
  navWatch = navigator.geolocation?.watchPosition(p => navFix([p.coords.latitude, p.coords.longitude]), () => {},
                                                  { enableHighAccuracy: true, maximumAge: 2000 });
  renderNav();
  say(`Starting route to ${s.name || "the spot"}. ${nav.steps[0]?.text || ""}`);
}

function useRoute(res) {
  const leg = res.routes[0].legs[0];
  navRenderer.setDirections(res);
  nav.leg = leg;
  nav.slow = leg.duration_in_traffic ? leg.duration_in_traffic.value / Math.max(leg.duration.value, 1) : 1;  // traffic right now
  nav.path = new google.maps.Polyline({ path: res.routes[0].overview_path });
  nav.steps = leg.steps.map(st => ({ text: stripHtml(st.instructions), maneuver: st.maneuver || "", end: st.end_location,
                                     meters: st.distance?.value || 0, secs: st.duration?.value || 0, transit: st.transit }));
  nav.i = 0;
}

function navFix(here) {
  if (!nav) return;
  const gm = google.maps, pos = LL(here), dist = (a, b) => gm.geometry.spherical.computeDistanceBetween(a, b);
  nav.here = here;
  navMe.setPosition(pos);
  if (nav.follow) navMap.panTo(pos);
  // reached the end of this step? on to the next one, and say it
  const near = nav.mode === "driving" ? 30 : 15;
  let moved = false;
  while (nav.i < nav.steps.length - 1 && dist(pos, nav.steps[nav.i].end) < near) { nav.i++; moved = true; }
  if (moved) say(nav.steps[nav.i].text);
  if (!nav.arrived && dist(pos, LL(nav.s.venue)) < 40) {
    nav.arrived = true;
    say(`You've arrived at ${nav.s.name || "the spot"}`);
  }
  // off the blue line for a few updates in a row? ask Google for a new route from here (not for buses and trains)
  const onRoute = gm.geometry.poly.isLocationOnEdge(pos, nav.path, nav.mode === "driving" ? 6e-4 : 4e-4);
  nav.off = onRoute ? 0 : nav.off + 1;
  if (!nav.arrived && nav.off >= 3 && nav.mode !== "transit" && Date.now() - nav.lastReroute > 20000) {
    nav.lastReroute = Date.now(); nav.off = 0;
    say("Rerouting");
    googleRoute(here, nav.s.venue, nav.mode, nav.s.start).then(res => { if (nav) { useRoute(res); renderNav(); say(nav.steps[0]?.text); } }).catch(() => {});
  }
  renderNav();
}

function renderNav() {
  if (!nav) return;
  const gm = google.maps, step = nav.steps[nav.i], next = nav.steps[nav.i + 1];
  if (nav.arrived) {
    $("navIcon").innerHTML = icon("flag"); $("navText").textContent = `You're at ${nav.s.name || "the spot"}`; $("navDist").textContent = "Have fun!";
    $("navThen").textContent = ""; $("navEta").textContent = "Arrived"; $("navLeft").textContent = ""; return;
  }
  // how far to the end of this step, then everything after it
  const toTurn = step ? gm.geometry.spherical.computeDistanceBetween(LL(nav.here), step.end) : 0;
  const part = step && step.meters ? Math.min(1, toTurn / step.meters) : 1;
  const later = nav.steps.slice(nav.i + 1);
  const meters = toTurn + later.reduce((a, x) => a + x.meters, 0);
  const secs = ((step?.secs || 0) * part + later.reduce((a, x) => a + x.secs, 0)) * nav.slow;
  const t = step?.transit;
  $("navIcon").innerHTML = t ? icon(/bus/i.test(t.line?.vehicle?.type || "") ? "bus" : "train-front") : turnIcon(step?.maneuver || step?.text);
  $("navText").textContent = t ? `${t.line?.short_name || t.line?.name || "Transit"} toward ${t.headsign || ""} · ${t.num_stops || "?"} stops` : step?.text || "Head to the spot";
  $("navDist").textContent = t ? `Get on at ${t.departure_stop?.name || ""}${t.departure_time?.text ? ` · ${t.departure_time.text}` : ""}` : `In ${howFar(toTurn)}`;
  $("navThen").innerHTML = next ? `Then ${turnIcon(next.maneuver || next.text)} ${esc(next.text)}` : "";
  $("navEta").textContent = `${Math.max(1, Math.round(secs / 60))} min`;
  $("navLeft").textContent = `${howFar(meters)} · arrive ${fmt(new Date(Date.now() + secs * 1000).toISOString())}`;
}

function endNav() {
  if (navWatch != null) navigator.geolocation.clearWatch(navWatch);
  navWatch = null; nav = null;
  navLock?.release?.().catch(() => {}); navLock = null;
  if ("speechSynthesis" in window) speechSynthesis.cancel();
  $("nav").hidden = true;
}
$("navEnd").onclick = endNav;
$("navRecenter").onclick = () => { if (!nav) return; nav.follow = true; $("navRecenter").hidden = true; navMap.panTo(LL(nav.here)); };
$("navVoice").onclick = () => {
  const on = !navVoiceOn();
  try { localStorage.setItem("navVoice", on ? "on" : "off"); } catch { /* private mode */ }
  $("navVoice").innerHTML = icon(on ? "volume-2" : "volume-x");
  if (!on && "speechSynthesis" in window) speechSynthesis.cancel();
};

// ---------- Muse: plan from one sentence ----------
$("museForm").onsubmit = async e => {
  e.preventDefault();
  const text = $("museText").value.trim();
  if (!text) return;
  const msg = (t, err = false) => { $("museMsg").textContent = t; $("museMsg").className = "muse-msg" + (err ? " err" : ""); };
  $("museGo").disabled = true; msg("Working on it…"); $("museConfirm").hidden = true;
  try {
    const c = map.getCenter();
    const res = await fetch(`${API}/ai/plan`, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, now: localIso(new Date()), lat: c.lat, lng: c.lng,
        friends: myFriends().filter(p => !p.isMe).map(p => ({ id: p.user_id, name: p.name })),
        categories: allTypes().map(([id, , name]) => ({ id, name })) }) });
    const d = await res.json();
    if (!res.ok) throw new Error(d.detail || res.statusText);
    const done = [];
    if (d.who.length) { picked.clear(); d.who.forEach(id => picked.add(id)); showFriends();
      done.push(`added ${d.who.map(id => myFriends().find(p => p.user_id === id)?.name).filter(Boolean).join(", ")}`); }
    const type = d.type && document.querySelector(`input[name=type][value="${CSS.escape(d.type)}"]`);
    if (type) { type.checked = true; done.push(allTypes().find(t => t[0] === d.type)?.[2].toLowerCase()); }
    if (d.when) { $("start").value = d.when; done.push(new Date(d.when).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" })); }
    if (d.place) { setVenue([d.place.lat, d.place.lng], d.place.name, d.place.address); map.flyTo([d.place.lat, d.place.lng], 15); done.push(d.place.name); }
    else if (d.place_query) done.push(`couldn't find “${d.place_query}”`);
    showWeather();
    msg(`${d.summary || "Done"}${done.length ? ` (${done.join(" · ")})` : ""}`);
    if (d.find_time) $("findBtn").click();
    else museConfirm(d.note, "museConfirm", d.place_options || []);
  } catch (err) {
    msg(friendly(err, "plan that"), true);
  } finally { $("museGo").disabled = false; }
};

// after Muse fills the plan in (or you pick a fair spot): a card where you can change anything Muse got wrong
// (what, where, when, who, the message), then Send. Nothing goes out, and nobody's plans change, until you tap Send.
// Friends only get an invite; it's on their schedule once they tap Going. Every change here updates the planner too.
function museConfirm(note, boxId = "museConfirm", options) {
  const box = $(boxId), q = sel => box.querySelector(sel);
  if (options) box._opts = options.filter(o => o.lat != null);  // other places Muse found, to swap to in one tap
  const opts = box._opts || [];
  const friendsAll = myFriends().filter(p => !p.isMe);
  const who = friendsAll.filter(p => picked.has(p.user_id)), notYet = friendsAll.filter(p => !picked.has(p.user_id));
  const type = allTypes().find(t => t[0] === selectedType());
  const typed = q(".mc-note textarea")?.value;  // keep what you already wrote when the card redraws
  const ready = who.length && venue && $("start").value;
  box.hidden = false;
  box.innerHTML = `<b>Check the plan, then send</b>
    <div class="mc-field"><span>${icon("tag")} What</span>
      <select class="mc-type">${allTypes().map(([v, , n]) => `<option value="${esc(v)}" ${v === selectedType() ? "selected" : ""}>${esc(n)}</option>`).join("")}</select></div>
    <div class="mc-field"><span>${icon("map-pin")} Where</span>
      <div class="mc-place">${venue ? `<b>${esc(venueName)}</b>${venueAddress ? `<small>${esc(venueAddress)}</small>` : ""}` : `<small>Pick a place</small>`}
        ${opts.filter(o => o.name !== venueName).length ? `<div class="mc-opts">${opts.map((o, k) => o.name === venueName ? "" :
          `<button class="mc-opt" data-opt="${k}" title="${esc(o.name)}">${icon("map-pin")}<span>${esc(o.name)}</span></button>`).join("")}</div>` : ""}
        <form class="mc-search"><input placeholder="Search another place" maxlength="100"><button class="mini">Find</button></form></div></div>
    <div class="mc-field"><span>${icon("calendar")} When</span><input type="datetime-local" class="mc-when" value="${esc($("start").value)}"></div>
    <div class="mc-field"><span>${icon("users")} Who</span>
      <div class="mc-chips"><span class="mc-person">You</span>${who.map(p =>
        `<span class="mc-person">${esc(p.name)}<button data-drop="${esc(p.user_id)}" title="Remove">${icon("x")}</button></span>`).join("")}
        ${notYet.length ? `<select class="mc-add"><option value="">+ Add</option>${notYet.map(p => `<option value="${esc(p.user_id)}">${esc(p.name)}</option>`).join("")}</select>` : ""}</div></div>
    <label class="mc-note">Message to the group<textarea maxlength="200" rows="2">${esc(typed ?? note ?? `${type ? type[2] : "Hang out"} at ${venueName}?`)}</textarea></label>
    <div class="mc-actions"><button class="mini mc-cancel">Cancel</button>
      <button class="mini dark mc-send" ${ready ? "" : "disabled"}>${icon("send")} Send invites</button></div>
    ${ready ? "" : `<small class="mc-err">Add ${[!who.length && "who's coming", !venue && "a place", !$("start").value && "a time"].filter(Boolean).join(", ")} to send.</small>`}`;
  const redraw = () => museConfirm(note, boxId);

  q(".mc-type").onchange = e => {
    document.querySelector(`input[name=type][value="${CSS.escape(e.target.value)}"]`).checked = true;
    if (venue) setVenue(venue, venueName, venueAddress);  // the map pin shows the new category
    redraw();
  };
  const goTo = p => { setVenue([p.lat, p.lng], p.name, p.address || ""); map.flyTo([p.lat, p.lng], 15); showWeather(); redraw(); };
  box.querySelectorAll("[data-opt]").forEach(b => b.onclick = () => goTo(opts[+b.dataset.opt]));
  q(".mc-search").onsubmit = async e => {
    e.preventDefault();
    const text = q(".mc-search input").value.trim(), btn = q(".mc-search button");
    if (!text) return;
    btn.disabled = true; btn.textContent = "…";
    try {
      const found = (await (await fetch(`${API}/places/search?q=${encodeURIComponent(text)}&${whereQs()}`)).json()).filter(o => o.lat != null).slice(0, 4);
      if (!found.length) { btn.disabled = false; btn.textContent = "None found"; return; }
      box._opts = found;
      goTo(found[0]);
    } catch { btn.disabled = false; btn.textContent = "Try again"; }
  };
  q(".mc-when").onchange = e => { $("start").value = e.target.value; $("start").dispatchEvent(new Event("change")); showWeather(); redraw(); };
  box.querySelectorAll("[data-drop]").forEach(b => b.onclick = () => { picked.delete(b.dataset.drop); showFriends(); redraw(); });
  const add = q(".mc-add");
  if (add) add.onchange = () => { if (add.value) { picked.add(add.value); showFriends(); redraw(); } };
  q(".mc-cancel").onclick = () => { box.hidden = true; };

  const sendBtn = q(".mc-send");
  sendBtn.onclick = async () => {
    const text = q(".mc-note textarea").value.trim();
    sendBtn.disabled = true; sendBtn.textContent = "Working out everyone's alerts…";
    try {
      if (!(await runPlan())) throw new Error($("error").textContent || "Couldn't plan it.");
      sendBtn.textContent = "Sending…";
      const id = await lockIn(lastPlan);
      if (text) await window.sendChat?.(id, text).catch(() => {});
      box.innerHTML = `<b>${icon("circle-check")} Invites sent</b><small>${esc(who.map(p => p.name).join(", "))} will see it in My plans${text ? ", with your message in the group chat" : ""}.
        It goes on their schedule once they tap Going. Their leave-now alerts are below.</small>`;
      if (boxId === "museConfirm") { $("museText").value = ""; $("museMsg").textContent = ""; }
      box._onSent?.();
    } catch (err) {
      sendBtn.disabled = false; sendBtn.textContent = "Try again";
      q(".mc-err")?.remove();
      const m = document.createElement("small"); m.className = "mc-err"; m.textContent = friendly(err, "send it"); box.appendChild(m);
    }
  };
}

// ---------- Muse: a spot that's fair for everyone ----------
const fairPins = L.layerGroup().addTo(map);
function closeFair() {  // Cancel, or after the invites go out: put the options away
  $("fair").hidden = true; $("fairList").innerHTML = ""; $("fairConfirm").hidden = true; fairPins.clearLayers();
}
$("fairBtn").onclick = () => {
  if (!$("fair").hidden) return closeFair();
  $("fair").hidden = false; $("fairDone").hidden = true;
  if (!$("fairText").value) $("fairText").value = allTypes().find(t => t[0] === selectedType())?.[2] || "";
  if (!$("fair").hidden) $("fairText").focus();
};
$("fairForm").onsubmit = async e => {
  e.preventDefault();
  const query = $("fairText").value.trim(), ids = pickedIds();
  if (!query) return;
  if (ids.length < 2) return $("fairList").innerHTML = `<div class="note">Pick at least one friend under Who first.</div>`;
  const people = myFriends().filter(p => ids.includes(p.user_id))
    .map(p => ({ id: p.user_id, name: p.isMe ? "You" : p.name, home: startPoint(p).at, mode: modeFor[p.user_id] || p.travel_mode }));
  $("fairConfirm").hidden = true; $("fairDone").hidden = true;
  $("fairList").innerHTML = `<div class="note">Checking everyone's trip to each place…</div>`;
  try {
    const c = map.getCenter();
    const res = await fetch(`${API}/ai/fair-spot`, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query, people, lat: c.lat, lng: c.lng }) });
    const d = await res.json();
    if (!res.ok) throw new Error(d.detail || res.statusText);
    if (!d.candidates.length) return $("fairList").innerHTML = `<div class="note">${esc(d.why)}</div>`;
    const name = id => people.find(p => p.id === id)?.name || "Friend";
    const order = [d.pick, ...d.candidates.map((_, i) => i).filter(i => i !== d.pick)];
    fairPins.clearLayers();
    d.candidates.forEach((p, i) => L.marker([p.lat, p.lng], { icon: L.divIcon({ className: "", iconSize: [30, 30], iconAnchor: [15, 30],
      html: `<div class="result-pin" ${i === d.pick ? 'style="background:#111114"' : ""}><span>${i === d.pick ? icon("star") : order.indexOf(i) + 1}</span></div>` }) })
      .bindTooltip(esc(p.name), { direction: "top", offset: [0, -28] }).addTo(fairPins));
    map.fitBounds(L.latLngBounds([...d.candidates.map(p => [p.lat, p.lng]), ...people.filter(p => p.home).map(p => p.home)]).pad(0.15), viewPadding());
    $("fairList").innerHTML = `<div class="fair-head"><span>${d.candidates.length} place${d.candidates.length === 1 ? "" : "s"} for “${esc(query)}”</span>
        <button class="mini fair-cancel" type="button">Cancel</button></div>` + order.map((i, n) => { const p = d.candidates[i];
      return `<div class="fair-card ${i === d.pick ? "pick" : ""}">
        <b>${i === d.pick ? icon("star") + " " : `${n + 1}. `}${esc(p.name)}</b>
        ${i === d.pick ? `<div class="why">${esc(d.why)}</div>` : ""}
        <small>${[p.rating ? `${icon("star", "star")} ${p.rating.toFixed(1)}` : "", p.price, esc(p.type || ""), p.open === true ? "Open now" : p.open === false ? "Closed now" : ""].filter(Boolean).join(" · ")}</small>
        <div class="trips">${Object.entries(p.times).map(([u, m]) => `<span class="trip ${m === p.worst && p.spread > 5 ? "worst" : ""}">${esc(name(u))} ${m} min</span>`).join("")}</div>
        <button class="mini ${i === d.pick ? "dark" : ""}" data-meet="${i}">Meet here</button></div>`; }).join("")
      + (d.missing_home?.length ? `<div class="note">No location for ${esc(d.missing_home.join(", "))}.</div>` : "");
    // Meet here: sets the spot, then asks before sending anyone anything
    $("fairList").onclick = ev => {
      if (ev.target.closest(".fair-cancel")) return closeFair();
      const b = ev.target.closest("[data-meet]"); if (!b) return;
      const i = +b.dataset.meet, p = d.candidates[i];
      setVenue([p.lat, p.lng], p.name, p.address); map.flyTo([p.lat, p.lng], 15);
      $("fairList").querySelectorAll(".fair-card").forEach(c => c.classList.toggle("chosen", c.contains(b)));
      // the invite uses what you searched for: Muse writes it for its pick, the others get a simple one
      const what = query[0].toUpperCase() + query.slice(1);
      const note = i === d.pick && d.note ? d.note : `${what} at ${p.name}? It's about ${p.worst} min for everyone.`;
      $("fairConfirm")._onSent = () => { closeFair(); $("fairDone").hidden = false;
        $("fairDone").innerHTML = `${icon("circle-check")} Invites sent for <b>${esc(p.name)}</b>. Everyone's leave-now alerts are below.`; };
      $("fairConfirm").innerHTML = "";  // a new place gets its own message
      museConfirm(note.slice(0, 200), "fairConfirm", d.candidates);
      $("fairConfirm").scrollIntoView({ behavior: "smooth", block: "nearest" }); };
  } catch (err) { $("fairList").innerHTML = `<div class="note">${esc(friendly(err, "find a spot"))}</div>`; }
};

$("planBtn").onclick = () => { closeHangout(); runPlan(); };
async function runPlan() {
  closeHangout();  // stop showing a saved plan; its live updates would redraw over these results
  $("error").textContent = "";
  const user_ids = pickedIds();
  if (!venue) return $("error").textContent = "Search for a place or tap the map to choose where to meet.";
  if (user_ids.length < 2) return $("error").textContent = "Pick at least one friend: search your friends under Who.";

  // live location first, then home. Anyone with neither is still invited; their app works out their time when they accept.
  const group = myFriends().filter(p => user_ids.includes(p.user_id));
  group.forEach(p => (startOf[p.user_id] = startPoint(p)));
  unplaced = group.filter(p => !startOf[p.user_id].at);
  const placed = group.filter(p => startOf[p.user_id].at);
  if (!placed.some(p => p.isMe)) return $("error").textContent = "Turn on location or set your home in your profile to plan.";

  $("planBtn").disabled = true; $("planBtn").textContent = "Planning…";
  try {
    const res = await fetch(`${API}/plan`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_ids: placed.map(p => p.user_id), venue, start_time: $("start").value, group_size: group.length,
                             hangout_type: selectedType(), modes: modeFor, utc_offset_min: -new Date().getTimezoneOffset(),
                             guests: placed.map(p => ({ user_id: p.user_id, name: p.name, travel_mode: p.travel_mode, habits: p.habits, home: startOf[p.user_id].at })) }),
    });
    if (!res.ok) throw new Error((await res.json()).detail || res.statusText);
    showResults(await res.json());
    return true;
  } catch (e) {
    $("error").textContent = friendly(e, "plan it");
    return false;
  } finally {
    $("planBtn").disabled = false; $("planBtn").textContent = "Plan it";
  }
}

let routeCasing = {};  // the white outline under each route line
// where each person leaves from when you plan: where they are right now if their app shared it recently, otherwise home
const LIVE_MIN = 30;
function startPoint(p) {
  if (p.isMe && window.myFix && Date.now() - window.myFix.at < LIVE_MIN * 6e4) return { at: window.myFix.here, kind: "live", when: window.myFix.at };
  if (p.live) return { at: p.live, kind: "live", when: p.liveAt };
  if (p.home) return { at: p.home, kind: "home" };
  return { at: null, kind: "none" };
}
const fromText = s => !s ? "" : s.kind === "live" ? `Live location · ${agoText(s.when)}` : s.kind === "home" ? "From home (no live location)" : "";
const agoText = t => { const m = Math.round((Date.now() - t) / 6e4); return m < 1 ? "just now" : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} hr ago`; };
let startOf = {};  // user id -> the start point the plan used
let unplaced = [];  // friends in the plan with no location yet (no live location, no home)
// while the plan is on screen, someone who moves (their live location changed a lot) gets their trip and leave time redone
const lastRedo = {};
const kmApart = ([a, b], [c, d]) => { const r = Math.PI / 180, x = Math.sin((c - a) * r / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin((d - b) * r / 2) ** 2;
                                     return 12742 * Math.asin(Math.sqrt(x)); };
window.addEventListener("friends-changed", () => {
  if (!lastPlan || !$("lockBtn") || $("lockBtn").disabled) return;  // only a plan you haven't sent yet
  for (const r of lastPlan) {
    const p = myFriends().find(x => x.user_id === r.user_id), used = startOf[r.user_id], now = p && startPoint(p);
    if (!now?.at || now.kind !== "live" || !used?.at || kmApart(used.at, now.at) < 0.3 || Date.now() - (lastRedo[r.user_id] || 0) < 60e3) continue;
    lastRedo[r.user_id] = Date.now();
    const card = document.querySelector(`#results .card[data-user="${r.user_id}"]`);
    if (card) switchMode(r.user_id, r.travel_mode, card, true);
  }
});

const enrich = r => {
  const person = people.find(p => p.user_id === r.user_id);
  r.photo = person?.photo || "";
  r.real = !!person?.real;  // a signed-in friend
  r.realName = person?.realName || r.name;  // "You" on your screen, your actual name for everyone else
  return r;
};

function summaryInner(plan) {
  const wouldBeLate = plan.filter(r => r.typical_delay_min >= 3).length, learning = plan.filter(r => r.learning).length;
  return learning === plan.length
    ? `Everyone at <strong>${esc(venueName)}</strong> by <strong>${fmt(new Date($("start").value))}</strong>.`
    : `With Maps alone, <strong>${wouldBeLate} of ${plan.length}</strong> would likely be late.`;
}

// the leave-time line: dots slide to their new spot when someone switches how they're getting there
function timelineHtml(plan) {
  return `<div class="bar"></div>${plan.map(r => `<div class="dot" data-user="${r.user_id}">${avatar(r)}</div>`).join("")}
    <div class="end">${icon("flag")}</div><div class="tick" id="tickFirst" style="left:0"></div><div class="tick" style="right:0">${fmt(new Date($("start").value))}</div>`;
}
function placeDots(plan) {
  const start = new Date($("start").value), first = new Date(Math.min(...plan.map(r => +new Date(r.alert_time))));
  const span = Math.max(start - first, 6e4);
  plan.forEach(r => {
    const dot = document.querySelector(`.timeline .dot[data-user="${r.user_id}"]`);
    if (dot) { dot.style.left = `${((new Date(r.alert_time) - first) / span) * 92 + 2}%`; dot.title = `${r.name} ${fmt(r.alert_time)}`; }
  });
  if ($("tickFirst")) $("tickFirst").textContent = fmt(first);
}

function cardHtml(r) {
  const earlier = minutesBetween(r.alert_time, r.maps_only_alert_time), mine = r.user_id === myId();
  const how = MODE[r.travel_mode] || "drive";
  return `<div class="card" style="--c:${colorOf[r.user_id]}" data-user="${r.user_id}">
    ${avatar(r)}
    <div class="card-main">
      <div class="card-top">
        <div class="who"><div class="name">${esc(r.name)}</div><span class="chip" title="${esc(r.label)}">${esc(r.learning ? "Learning" : r.label)}</span></div>
        <div class="time"><small>Alert</small>${fmt(r.alert_time)}</div>
      </div>
      <div class="two-times">
        <div class="tt rec"><small>${icon("bell")} Alert</small><b>${fmt(r.alert_time)}</b>
          <span>${r.learning ? "Same as Maps for now" : r.typical_delay_min >= 1 ? `Usually heads out ~${Math.round(r.typical_delay_min)} min after` : "Usually heads out right away"}</span></div>
        <div class="tt maps"><small>${icon("map")} Google Maps</small><b>${Math.round(r.travel_minutes)} min trip</b>
          <span>Latest ${fmt(r.maps_only_alert_time)}</span></div>
      </div>
      <div class="from-line ${startOf[r.user_id]?.kind || ""}">${icon(startOf[r.user_id]?.kind === "live" ? "locate-fixed" : startOf[r.user_id]?.kind === "home" ? "house" : "map-pin")} ${esc(fromText(startOf[r.user_id]) || r.label)}</div>
      ${r.traffic && r.traffic.basis !== "live" ? `<div class="detail">${icon("car")} ${trafficNote(r.traffic).slice(3)}</div>` : ""}
      <div class="modes">${Object.entries(MODE).map(([m, label]) =>
        `<button class="mode-chip ${m === r.travel_mode ? "on" : ""}" data-user="${r.user_id}" data-mode="${m}" title="${label}">${icon(MODE_ICON[m])}${label}</button>`).join("")}</div>
      ${mine ? `<button class="dir-btn" data-dir="1">${icon("route")} Directions</button>` : ""}
      <div class="status" id="st-${r.user_id}"></div>
    </div>
  </div>`;
}

function bindCard(card) {
  const uid = card.dataset.user;
  // hover a card to highlight that friend's route
  card.onmouseenter = () => { routes[uid]?.setStyle({ weight: 10, dashArray: null }); routes[uid]?.bringToFront(); };
  card.onmouseleave = () => routes[uid]?.setStyle({ weight: 6, dashArray: "1 10" });
  card.querySelectorAll(".mode-chip").forEach(b => b.onclick = e => { e.stopPropagation(); switchMode(uid, b.dataset.mode, card); });
  const dirBtn = card.querySelector("[data-dir]");
  if (dirBtn) dirBtn.onclick = e => { e.stopPropagation(); const r = lastPlan.find(x => x.user_id === uid);
    openDirections({ venue, name: venueName, start: $("start").value, mode: r?.travel_mode, from: r?.home }); };
}

function drawRoute(r) {
  routeCasing[r.user_id] = L.polyline(r.route, { color: "#fff", weight: 10, opacity: .95 }).addTo(layer);
  routes[r.user_id] = L.polyline(r.route, { color: colorOf[r.user_id], weight: 6, opacity: .95, lineCap: "round", dashArray: "1 10" }).addTo(layer);
  homeMarkers[r.user_id] = L.marker(r.home, { icon: pal(r, `Leaves ${fmt(r.alert_time)}`) }).addTo(layer);
}

function showResults(plan) {
  plan.forEach(enrich);
  lastPlan = plan;
  layer.clearLayers(); routes = {}; homeMarkers = {}; routeCasing = {};
  $("empty").style.display = "none";
  plan.forEach(drawRoute);

  $("results").innerHTML = `
    <div class="summary" id="planSummary">${summaryInner(plan)}</div>
    ${unplaced.length ? `<div class="note">No location yet for ${esc(unplaced.map(p => p.name).join(", "))}.</div>` : ""}
    ${plan.some(r => r.real) ? `<button class="lock" id="lockBtn">${icon("send")} Send invites</button>` : ""}
    <div class="timeline" id="timeline">${timelineHtml(plan)}</div>
    ${plan.map(cardHtml).join("")}`;
  placeDots(plan);
  document.querySelectorAll("#results .card").forEach(bindCard);
  map.fitBounds([venue, ...plan.flatMap(r => r.route)], viewPadding());
  if ($("lockBtn")) $("lockBtn").onclick = () => lockIn(lastPlan).catch(() => {});
}

// switch how one person gets there: only their card, route and dot change (no reloading the whole plan)
async function switchMode(uid, mode, card, again = false) {
  const old = lastPlan.find(r => r.user_id === uid);
  if (!old || (old.travel_mode === mode && !again) || card.classList.contains("busy")) return;
  card.classList.add("busy");
  card.querySelectorAll(".mode-chip").forEach(x => x.classList.toggle("on", x.dataset.mode === mode));  // feels instant
  $(`st-${uid}`).textContent = "";
  try {
    const guest = myFriends().find(p => p.user_id === uid);
    if (guest) startOf[uid] = startPoint(guest);
    const res = await fetch(`${API}/plan`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_ids: [uid], group_size: lastPlan.length, venue, start_time: $("start").value,
                             hangout_type: selectedType(), modes: { [uid]: mode }, utc_offset_min: -new Date().getTimezoneOffset(),
                             guests: guest ? [{ user_id: uid, name: guest.name, travel_mode: guest.travel_mode, home: startOf[uid].at, habits: guest.habits }] : [] }),
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).detail || res.statusText);
    const r = enrich((await res.json())[0]);
    modeFor[uid] = mode;
    lastPlan = lastPlan.map(x => x.user_id === uid ? r : x);
    routes[uid].setLatLngs(r.route); routeCasing[uid].setLatLngs(r.route);
    homeMarkers[uid].setIcon(pal(r, `Leaves ${fmt(r.alert_time)}`));
    const fresh = document.createElement("div");
    fresh.innerHTML = cardHtml(r);
    const next = fresh.firstElementChild;
    next.classList.add("changed");
    card.replaceWith(next);
    bindCard(next);
    placeDots(lastPlan);
    $("planSummary").innerHTML = summaryInner(lastPlan);
  } catch (e) {
    card.classList.remove("busy");
    card.querySelectorAll(".mode-chip").forEach(x => x.classList.toggle("on", x.dataset.mode === old.travel_mode));
    $(`st-${uid}`).className = "status warn";
    $(`st-${uid}`).textContent = `No ${MODE[mode]} route found.`;
  }
}

// tap a plan in My plans: its spot on the map, plus where everyone going is right now (live, around hangout time)

const ago = iso => { const m = Math.round((Date.now() - new Date(iso)) / 6e4); return m < 1 ? "just now" : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`; };
const awayText = (a, b) => { const m = map.distance(a, b); return m < 1000 ? `${Math.round(m)} m away` : `${(m / 1000).toFixed(1)} km away`; };

window.showHangout = h => {
  closeHangout();
  clearVenue();
  const t = new Date(h.start);
  $("start").value = new Date(t - t.getTimezoneOffset() * 6e4).toISOString().slice(0, 16);
  const type = document.querySelector(`input[name=type][value="${h.type}"]`);
  if (type) type.checked = true;
  forcedEmoji = h.emoji || "map-pin";
  setVenue(h.venue, h.venueName || "Hangout", h.address || "");
  shown = { h, where: {}, fitted: false };
  shown.stop = window.watchHangoutPeople(h.id, where => { if (shown?.h.id === h.id) { shown.where = where; drawHangout(); } });
  drawHangout();
  toggleSheet(false);
};
window.hangoutsChanged = docs => {  // someone arrived, joined or left: redraw (or close if it was cancelled)
  if (!shown) return;
  if (!docs[shown.h.id]) return clearVenue();
  shown.h = docs[shown.h.id];
  drawHangout();
};
function closeHangout() {
  if (!shown) return;
  shown.stop?.(); shown = null; forcedEmoji = "";
  layer.clearLayers(); $("results").innerHTML = ""; $("empty").style.display = "";
}

function drawHangout() {
  const { h, where } = shown;
  layer.clearLayers();
  const friends = Object.fromEntries(myFriends().map(p => [p.user_id, p]));
  const over = Date.now() > new Date(h.start).getTime() + (h.durationMin || 120) * 6e4;
  const rows = h.attendees.map((u, i) => {
    const p = { user_id: u, name: friends[u]?.name || h.names?.[u] || "Friend", photo: friends[u]?.photo || "",
                travel_mode: h.modes?.[u] || friends[u]?.travel_mode || "driving" };
    colorOf[u] ??= COLORS[i % COLORS.length];
    const shareFrom = window.shareStart(h, u);  // everyone's spot shows from when they're supposed to leave
    const isMe = myFriends().find(f => f.isMe)?.user_id === u;
    const live = isMe && myLocation ? myLocation  // you always see yourself
      : where[u] && new Date(where[u].at) >= shareFrom - 6e4 ? [where[u].lat, where[u].lng] : null;
    const arrived = h.arrivals?.[u];
    let spot = null, tag, text;
    if (arrived) {
      const angle = (i / h.attendees.length) * 2 * Math.PI;
      spot = [h.venue[0] + 0.0004 * Math.cos(angle), h.venue[1] + 0.0005 * Math.sin(angle)];
      const late = Math.round((new Date(arrived) - t0(h)) / 6e4);
      tag = "Here";
      text = `Arrived ${fmt(arrived)} · ${late < -1 ? `${-late} min early` : late <= 5 ? "on time" : `${late} min late`}`;
    } else if (live && !over) {
      spot = live;
      const seen = isMe ? "live" : ago(where[u].at);
      tag = seen === "live" ? "Live" : seen;
      text = `${awayText(live, h.venue)} · ${seen}${h.alerts?.[u] ? ` · leaves ${fmt(h.alerts[u])}` : ""}`;
    } else {
      spot = friends[u]?.home || null;
      tag = "Home";
      text = over ? "Didn't check in" : Date.now() < shareFrom ? `Shows up here from ${fmt(shareFrom)}${h.alerts?.[u] ? ` · leaves ${fmt(h.alerts[u])}` : ""}`
                                                               : "Not sharing yet (omw! closed or location off)";
    }
    const onTheWay = live && !arrived && !over;  // live: show how they're getting there
    if (spot && !(isMe && live && !arrived)) L.marker(spot, { icon: pal(p, tag, onTheWay ? "moving" : ""), zIndexOffset: 500 }).addTo(layer)
      .getElement()?.classList.toggle("faded", !onTheWay && !arrived);
    return { p, spot, text };
  });
  $("empty").style.display = "none";
  $("results").innerHTML = `<div class="summary"><b>${esc(h.title)}</b> · ${esc(new Date(h.start).toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))}</div>
    ${rows.map(r => `<div class="card" style="--c:${colorOf[r.p.user_id]}">${avatar(r.p)}<div class="card-main">
      <div class="name">${esc(r.p.name)}</div><div class="detail">${esc(r.text)}</div></div></div>`).join("")}`;
  if (!shown.fitted) {  // zoom to everyone once; after that, leave the map where you put it
    shown.fitted = true;
    const pts = [h.venue, ...rows.map(r => r.spot).filter(Boolean)];
    pts.length > 1 ? map.fitBounds(pts, viewPadding()) : map.flyTo(h.venue, 16);
  }
}
const t0 = h => new Date(h.start);

// invite everyone in the plan; you're going, the others accept or decline in their own omw
async function lockIn(plan) {
  const invited = plan.filter(r => r.real), later = unplaced.filter(p => !plan.some(r => r.user_id === p.user_id));
  const type = allTypes().find(t => t[0] === selectedType()) || TYPES[0];
  const btn = $("lockBtn") || {};  // the planner's button (the Muse card sends without it)
  btn.disabled = true; btn.textContent = "Sending…";
  try {
    const id = await window.lockInHangout({
      title: `${type[2]} at ${venueName}`,
      start: new Date($("start").value).toISOString(),
      durationMin: 120,
      venueName, address: venueAddress, venue,
      type: type[0], emoji: type[1],
      invited: [...invited.map(r => r.user_id), ...later.map(p => p.user_id)],
      names: Object.fromEntries([...invited.map(r => [r.user_id, r.realName]), ...later.map(p => [p.user_id, p.name])]),
      modes: Object.fromEntries([...invited.map(r => [r.user_id, r.travel_mode]), ...later.map(p => [p.user_id, p.travel_mode])]),
      alerts: Object.fromEntries(invited.map(r => [r.user_id, new Date(r.alert_time).toISOString()])),
      travel: Object.fromEntries(invited.map(r => [r.user_id, Math.round(r.travel_minutes * 10) / 10])),  // to learn from check-ins
    });
    const others = invited.length + later.length - 1;
    if ($("lockBtn")) $("lockBtn").innerHTML = `${icon("circle-check")} ${others > 0 ? `Invites sent to ${others} friend${others === 1 ? "" : "s"}` : "Saved"}`;
    return id;
  } catch (e) {
    if ($("lockBtn")) { $("lockBtn").disabled = false; $("lockBtn").innerHTML = `${icon("send")} Send invites`; }
    $("error").textContent = friendly(e, "send the invites");
    throw e;
  }
}

// pop-up notes at the top (chat messages, arrivals)
function toast(f, html, warn = false) {
  const el = document.createElement("div");
  el.className = "toast" + (warn ? " warn" : "");
  el.innerHTML = `${avatar(f)}<div>${html}</div>`;
  $("toasts").prepend(el);
  setTimeout(() => el.remove(), 4500);
}

// one number at a time in the top bar: the most important count shows, any others are just a dot
{ const order = ["planBadge", "inboxBadge", "reqBadge"];
  let busy = false;
  const sync = () => {
    if (busy) return; busy = true;
    let shown = false;
    for (const id of order) { const b = $(id); if (!b) continue; b.classList.toggle("dot", !b.hidden && shown); if (!b.hidden) shown = true; }
    busy = false;
  };
  const watch = new MutationObserver(sync);
  order.forEach(id => $(id) && watch.observe($(id), { attributes: true, attributeFilter: ["hidden"], childList: true, characterData: true, subtree: true }));
  sync(); }

showFriends();
