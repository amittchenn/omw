// The feed: the home screen on phones and in the iPhone / iPad app, like Instagram. Your friends' posts (a photo, a caption,
// maybe a place) and the group photos from hangouts, with likes and comments; who's out, on their way or free right now; and
// your next plan. Tabs at the bottom: Feed, Map (maptab.js), + (plan a hangout), Plans (your plans and memories), Me.
// feed/{id} is one of two kinds:
//   a post:         { kind: "post", by, byName, members: [by], names, photo, caption, at, venueName?, address?, venue?, viewers, likes }
//   a group photo:  { by, byName, members, names, photo, at, start, title, venueName, address, venue, late: { uid: minutes late },
//                     viewers, likes, ratings: { uid: 9 | 5.5 | 2 } }   (id = the hangout's id; shared from Memories)
// viewers = the people in it plus their friends (each person in it adds their own friends when their app sees it): friends only.
// feed/{id}/comments/{auto id} = { from, name, text, at }
// Report and block (App Store rule for apps where people see each other's posts): reports/{post}_{you} for us to review,
// and users/{uid}.blocked hides everything posted by or with that person.
// Your status for friends lives on your profile: users/{uid}.freeUntil (you tapped "I'm free") and .now = { kind: "out" | "omw", until }.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, collection, doc, query, where, orderBy, limit, onSnapshot, setDoc, addDoc, updateDoc, deleteDoc, arrayUnion, arrayRemove }
  from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const POSTS = 30;            // newest posts loaded (each carries its photo)
const ON_TIME_MIN = 5;       // later than this and the post says who was late
const RATINGS = [[9, "Loved it"], [5.5, "It was fine"], [2, "Didn't like it"]];  // Beli's three buckets, as a score out of 10
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const phone = () => matchMedia("(max-width: 860px)").matches;
const tick = () => window.Capacitor?.Plugins?.Haptics?.impact({ style: "LIGHT" }).catch(() => {});  // a light tap in the iPhone app

let db, me = null, posts = {}, stopFeed = null, tab = "feed", freeMenu = false, widened = new Set(), nowSent = "", menuFor = null;
let comments = {}, commentStops = {}, openComments = new Set(), draft = null;

// ---------- helpers ----------
const friends = () => (window.myFriends || []).filter(p => !p.isMe);
const friendOf = uid => (window.myFriends || []).find(p => p.user_id === uid);
const myName = () => (window.myFriends || []).find(p => p.isMe)?.realName || me?.displayName || "Me";
const first = n => String(n || "Friend").split(" ")[0];
const ago = iso => {
  const m = Math.round((Date.now() - new Date(iso)) / 6e4);
  return m < 1 ? "just now" : m < 60 ? `${m} min ago` : m < 1440 ? `${Math.round(m / 60)} h ago` : m < 2880 ? "yesterday"
       : new Date(iso).toLocaleDateString([], { month: "short", day: "numeric" });
};
const clock = iso => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const face = (uid, name, cls = "") => {
  const photo = friendOf(uid)?.photo;
  return photo ? `<span class="ff ${cls}" style="background-image:url('${esc(photo)}')"></span>`
               : `<span class="ff ${cls}">${esc(first(name).slice(0, 1).toUpperCase())}</span>`;
};
const blocked = () => (window.myFriends || []).find(p => p.isMe)?.blocked || [];
const hiddenKey = () => `feedHidden:${me?.uid}`;
const hidden = () => { try { return JSON.parse(localStorage.getItem(hiddenKey())) || []; } catch { return []; } };
const visible = () => Object.values(posts).filter(p => !hidden().includes(p.id) && !p.members.some(u => blocked().includes(u)));
const score = p => { const r = Object.values(p.ratings || {}); return r.length ? r.reduce((a, b) => a + b, 0) / r.length : null; };
const kmFromMe = ll => {
  const f = window.myFix?.here;
  if (!f || !ll) return null;
  const r = Math.PI / 180, x = Math.sin((ll[0] - f[0]) * r / 2) ** 2 + Math.cos(f[0] * r) * Math.cos(ll[0] * r) * Math.sin((ll[1] - f[1]) * r / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(x));
};
const away = ll => { const km = kmFromMe(ll); return km == null ? "" : km < 1 ? `${Math.round(km * 1000)} m away` : `${km.toFixed(1)} km away`; };

// someone's status right now: out at a hangout, on their way, or free
function statusOf(p) {
  const now = Date.now();
  if (p.now && new Date(p.now.until) > now) return p.now.kind === "out" ? ["out", "Out now"] : ["omw", "On the way"];
  if (p.freeUntil && new Date(p.freeUntil) > now) return ["free", "Free"];
  return ["", ""];
}

// ---------- drawing ----------
function render() {
  if (!$("feed") || !me) return;
  // typing a comment: don't redraw under the person's fingers (it catches up when they send)
  if (document.activeElement?.matches?.("#feed .fc-input")) return;
  $("feedBody").innerHTML = friendsRow() + upNext() + snapBanner() + postsHtml();
}

function friendsRow() {
  const mine = (window.myFriends || []).find(p => p.isMe) || {};
  const free = mine.freeUntil && new Date(mine.freeUntil) > Date.now();
  const rank = s => ({ out: 0, omw: 1, free: 2 })[s] ?? 3;
  const list = friends().map(p => ({ p, s: statusOf(p) })).sort((a, b) => rank(a.s[0]) - rank(b.s[0]) || a.p.name.localeCompare(b.p.name));
  return `<div class="ff-row">
    <button class="ff-me ${free ? "free" : ""}" data-free-menu>
      ${free ? face(mine.user_id, mine.realName, "big") : `<span class="ff big add">${icon("plus")}</span>`}
      <b>${free ? "You're free" : "I'm free"}</b><small>${free ? `til ${esc(clock(mine.freeUntil))}` : "Tap me"}</small></button>
    ${list.map(({ p, s }) => `<button class="ff-friend ${s[0]}" data-plan-with="${esc(p.user_id)}" title="Plan something with ${esc(p.name)}">
      ${face(p.user_id, p.name, "big")}<b>${esc(first(p.name))}</b><small>${esc(s[1])}</small></button>`).join("")}
    ${list.length ? "" : `<button class="ff-friend" data-tab-go="me"><span class="ff big add">${icon("user-round-plus")}</span><b>Add friends</b><small>by friend ID</small></button>`}
  </div>
  ${freeMenu ? `<div class="free-menu">
    <span>Let your friends know you're up for something</span>
    <div><button data-free="2">Next 2 hours</button><button data-free="tonight">Tonight</button>
    ${free ? `<button data-free="off" class="off">Not free anymore</button>` : ""}</div></div>` : ""}`;
}

function upNext() {  // your next hangout in the next two days
  const now = Date.now();
  const h = (window.myHangouts || []).filter(h => new Date(h.start).getTime() + (h.durationMin || 120) * 6e4 > now
                                                && new Date(h.start) - now < 48 * 36e5).sort((a, b) => a.start.localeCompare(b.start))[0];
  if (!h) return "";
  const d = new Date(h.start), today = d.toDateString() === new Date().toDateString();
  const tomorrow = d.toDateString() === new Date(now + 864e5).toDateString();
  const day = today ? "Today" : tomorrow ? "Tomorrow" : d.toLocaleDateString([], { weekday: "long" });
  const leave = h.alerts?.[me.uid], arrived = h.arrivals?.[me.uid];
  const going = h.attendees.filter(u => u !== me.uid);
  return `<button class="up-next" data-open-plan="${esc(h.id)}">
    <span class="un-when">${esc(day)} · ${esc(clock(h.start))}</span>
    <b>${esc(plainTitle(h.title))}</b>
    <span class="un-where">${esc(plainTitle(h.title).includes(h.venueName) ? h.address || "" : h.venueName || "")}</span>
    <span class="un-who">${going.slice(0, 5).map(u => face(u, h.names?.[u])).join("")}
      <small>${going.length ? `${esc(going.slice(0, 2).map(u => first(h.names?.[u])).join(", "))}${going.length > 2 ? ` +${going.length - 2}` : ""}` : "Just you so far"}</small></span>
    ${arrived ? `<span class="un-leave">${icon("circle-check")} You're there</span>`
      : leave ? `<span class="un-leave">${icon("clock")} Leave by <b>${esc(clock(leave))}</b>${h.travel?.[me.uid] ? ` · ${Math.round(h.travel[me.uid])} min trip` : ""}</span>` : ""}
  </button>`;
}

function snapBanner() {  // everyone's there and nobody posted the group photo yet (memories.js)
  const h = window.snapWaiting?.()[0];
  if (!h) return "";
  const allAt = Math.max(...h.attendees.map(u => new Date(h.arrivals[u]).getTime()));
  const left = Math.ceil(10 - (Date.now() - allAt) / 6e4);
  return `<div class="feed-snap"><button class="fs-go" data-snap="${esc(h.id)}">${icon("camera")}
    <span><b>You all made it!</b><small>Snap the group at ${esc(h.venueName || "the spot")}${left > 0 ? ` · ${left} min left` : ""}</small></span>
    ${icon("chevron-right")}</button></div>`;
}

function lateBadge(p) {
  const late = Object.entries(p.late || {});
  if (!late.length) return "";
  const [uid, worst] = late.sort((a, b) => b[1] - a[1])[0];
  if (worst <= ON_TIME_MIN) return `<span class="fp-badge ok">${icon("zap")} All on time</span>`;
  const who = uid === me.uid ? "You" : first(p.names?.[uid]);
  return `<span class="fp-badge late">${esc(who)} ${worst < 60 ? `${Math.round(worst)} min` : `${Math.round(worst / 60)} h`} late</span>`;
}

function postsHtml() {
  const list = visible().sort((a, b) => b.at.localeCompare(a.at));
  if (!list.length) return `<div class="feed-empty">${icon("images")}<b>Nothing here yet</b>
    Share what you're up to, or hang out with friends: the group photo shows up here too.
    <button class="fe-go" data-new-post>${icon("camera")} Make your first post</button></div>`;
  return list.map(p => p.kind === "post" ? postHtml(p) : groupHtml(p)).join("");
}

// someone's post, like Instagram
function postHtml(p) {
  const liked = p.likes?.includes(me.uid), name = p.by === me.uid ? "You" : p.names?.[p.by] || p.byName;
  return `<article class="fpost" data-post="${esc(p.id)}">
    <header><span class="fp-faces">${face(p.by, name)}</span>
      <span class="fp-who"><b>${esc(name)}</b><small>${esc([p.venueName, ago(p.at)].filter(Boolean).join(" · "))}</small></span>
      <button class="fp-more" data-post-menu="${esc(p.id)}" aria-label="More options">${icon("ellipsis")}</button></header>
    ${menuFor === p.id ? postMenu(p) : ""}
    <div class="fp-photo" data-like-twice="${esc(p.id)}"><img src="${esc(p.photo)}" alt="${esc(p.caption || "Photo")}" loading="lazy">
      ${p.venueName ? `<div class="fp-place"><span class="fp-pin">${icon("map-pin")}</span>
        <span class="fp-pname"><b>${esc(p.venueName)}</b><small>${esc([p.address, away(p.venue)].filter(Boolean).join(" · "))}</small></span></div>` : ""}
    </div>
    ${actions(p, liked)}
    ${p.caption ? `<p class="fp-caption"><b>${esc(first(name))}</b> ${esc(p.caption)}</p>` : ""}
    ${commentsHtml(p)}
  </article>`;
}

// a hangout's group photo (shared from Memories), with who was late and the place's rating
function groupHtml(p) {
  const members = [...p.members].sort((a, b) => (b === me.uid) - (a === me.uid) || !!friendOf(b) - !!friendOf(a));
  const names = members.map(u => u === me.uid ? "You" : first(p.names?.[u]));
  const who = names.length <= 3 ? names.join(", ").replace(/, ([^,]*)$/, " & $1") : `${names.slice(0, 2).join(", ")} & ${names.length - 2} more`;
  const liked = p.likes?.includes(me.uid), mine = p.members.includes(me.uid), s = score(p);
  const myRating = p.ratings?.[me.uid];
  return `<article class="fpost" data-post="${esc(p.id)}">
    <header><span class="fp-faces">${members.slice(0, 3).map(u => face(u, p.names?.[u])).join("")}</span>
      <span class="fp-who"><b>${esc(who)}</b><small>${esc(p.venueName || plainTitle(p.title))} · ${esc(ago(p.at))}</small></span>${lateBadge(p)}
      <button class="fp-more" data-post-menu="${esc(p.id)}" aria-label="More options">${icon("ellipsis")}</button></header>
    ${menuFor === p.id ? postMenu(p) : ""}
    <div class="fp-photo" data-like-twice="${esc(p.id)}"><img src="${esc(p.photo)}" alt="Group photo at ${esc(p.venueName || "a hangout")}" loading="lazy">
      ${p.venueName ? `<div class="fp-place">
        <span class="fp-score ${s == null ? "none" : ""}">${s == null ? "new" : s.toFixed(1)}</span>
        <span class="fp-pname"><b>${esc(p.venueName)}</b><small>${esc([s == null ? "Not rated yet" : `Rated by ${Object.keys(p.ratings).length}`,
          away(p.venue)].filter(Boolean).join(" · "))}</small></span>
      </div>` : ""}
    </div>
    ${mine && !myRating && p.venueName ? `<div class="fp-rate"><span>How was ${esc(p.venueName)}?</span>
      <div>${RATINGS.map(([v, l]) => `<button data-rate="${esc(p.id)}" data-score="${v}">${esc(l)}</button>`).join("")}</div></div>` : ""}
    ${actions(p, liked, myRating ? `<small class="fp-mine">You: ${esc(RATINGS.find(r => r[0] === myRating)?.[1] || myRating)}</small>` : "")}
    ${commentsHtml(p)}
  </article>`;
}

function actions(p, liked, extra = "") {
  const n = (comments[p.id] || []).length;
  return `<footer>
    <button class="fp-like ${liked ? "on" : ""}" data-like="${esc(p.id)}" aria-label="${liked ? "Unlike" : "Like"}">${icon("heart")}<span>${p.likes?.length || ""}</span></button>
    <button class="fp-like" data-comments="${esc(p.id)}" aria-label="Comments">${icon("message-circle")}<span>${n || ""}</span></button>
    ${extra}<span class="fp-gap"></span>
    ${p.venue ? `<button class="fp-plan" data-plan-at="${esc(p.id)}">Plan this</button>` : ""}
  </footer>`;
}

// the last two comments, or all of them and a box to add yours
function commentsHtml(p) {
  const list = comments[p.id] || [], open = openComments.has(p.id), shown = open ? list : list.slice(-2);
  return `<div class="fp-comments">
    ${!open && list.length > 2 ? `<button class="fc-more" data-comments="${esc(p.id)}">View all ${list.length} comments</button>` : ""}
    ${shown.map(c => `<p class="fc"><b>${esc(c.from === me.uid ? "You" : first(c.name))}</b> ${esc(c.text)}
      ${c.from === me.uid || p.by === me.uid ? `<button class="fc-x" data-del-comment="${esc(p.id)}/${esc(c.id)}">Delete</button>`
        : `<button class="fc-x" data-report-comment="${esc(p.id)}/${esc(c.id)}">Report</button>`}</p>`).join("")}
    ${open ? `<form class="fc-form" data-comment-form="${esc(p.id)}"><input class="fc-input" maxlength="300" placeholder="Add a comment…" aria-label="Add a comment">
      <button class="fc-send">Post</button></form>` : ""}
  </div>`;
}

function postMenu(p) {
  const poster = p.by === me.uid ? "you" : first(p.names?.[p.by]);
  return `<div class="fp-menu">${p.by === me.uid
    ? `<button data-unshare-post="${esc(p.id)}">${icon("trash-2")} ${p.kind === "post" ? "Delete this post" : "Take it off the feed"}</button>`
    : `<button data-report="${esc(p.id)}">${icon("flag")} Report this post</button>
       <button data-block="${esc(p.by)}">${icon("user-x")} Block ${esc(poster)}</button>`}
    <button data-hide-post="${esc(p.id)}">${icon("x")} Hide this post</button></div>`;
}

// the spots your friends rated, best first (the map's "Friends' spots")
window.friendSpots = () => {
  const by = {};
  for (const p of visible()) {
    if (!p.venueName || !p.venue) continue;
    const k = `${p.venueName}|${p.address || ""}`;
    const v = by[k] ||= { name: p.venueName, address: p.address || "", venue: p.venue, ratings: [], visits: 0, people: new Set() };
    v.ratings.push(...Object.values(p.ratings || {}));
    v.visits++;
    p.members.forEach(u => v.people.add(u === me.uid ? "You" : first(p.names?.[u])));
  }
  return Object.values(by).map(v => ({ ...v, people: [...v.people], score: v.ratings.length ? v.ratings.reduce((a, b) => a + b, 0) / v.ratings.length : null }))
    .sort((a, b) => (b.score ?? -1) - (a.score ?? -1) || b.visits - a.visits);
};

// ---------- comments: live for the posts on screen ----------
function listenComments() {
  const ids = new Set(Object.keys(posts));
  for (const id of Object.keys(commentStops)) if (!ids.has(id)) { commentStops[id](); delete commentStops[id]; delete comments[id]; }
  for (const id of ids) {
    if (commentStops[id]) continue;
    commentStops[id] = onSnapshot(query(collection(db, "feed", id, "comments"), orderBy("at"), limit(100)), s => {
      comments[id] = s.docs.map(d => ({ ...d.data(), id: d.id }));
      render();
    }, () => {});
  }
}

// ---------- making a post ----------
function pickPhoto() {
  const input = Object.assign(document.createElement("input"), { type: "file", accept: "image/*" });
  input.onchange = async () => {
    const file = input.files[0];
    if (!file) return;
    try { draft = { photo: await toJpeg(URL.createObjectURL(file)), caption: "", place: null, found: [] }; compose(); }
    catch (e) { alert(friendly(e, "use that photo")); }
  };
  input.click();
}
function compose(msg = "") {
  const box = $("postCompose");
  box.hidden = false;
  box.innerHTML = `<div class="pc-card" role="dialog" aria-label="New post">
    <div class="pc-head"><button class="pc-cancel" data-pc-cancel>Cancel</button><b>New post</b>
      <button class="pc-share" data-pc-share>Share</button></div>
    <div class="pc-photo"><img src="${draft.photo}" alt="Your photo"></div>
    <textarea class="pc-caption" id="pcCaption" maxlength="500" placeholder="Write a caption…" aria-label="Caption">${esc(draft.caption)}</textarea>
    <div class="pc-place">${draft.place
      ? `<div class="pc-picked">${icon("map-pin")}<span><b>${esc(draft.place.name)}</b><small>${esc(draft.place.address || "")}</small></span>
         <button data-pc-unplace aria-label="Remove the place">${icon("x")}</button></div>`
      : `<label class="pc-search">${icon("map-pin")}<input id="pcPlace" placeholder="Add a place" autocomplete="off" aria-label="Add a place"></label>
         <div class="pc-found" id="pcFound"></div>`}</div>
    <small class="pc-note">Your friends see it in their feed.</small>
    <small class="pc-msg">${esc(msg)}</small>
  </div>`;
  const input = $("pcPlace");
  if (input) input.oninput = () => {
    clearTimeout(compose.timer);
    const q = input.value.trim();
    if (q.length < 2) { $("pcFound").innerHTML = ""; return; }
    compose.timer = setTimeout(async () => {
      compose.session ||= crypto.randomUUID?.() || String(Math.random()).slice(2);
      const c = window.myFix?.here || [37.7749, -122.4194];
      const list = await fetch(`/places/suggest?q=${encodeURIComponent(q)}&lat=${c[0]}&lng=${c[1]}&session=${compose.session}`).then(r => r.json()).catch(() => []);
      if (input.value.trim() !== q) return;
      draft.found = (list || []).filter(p => p.kind !== "query").slice(0, 6);
      $("pcFound").innerHTML = draft.found.map((p, i) => `<button data-pc-place="${i}"><b>${esc(p.name)}</b><small>${esc(p.address || "")}</small></button>`).join("");
    }, 250);
  };
}
async function toJpeg(src) {  // at most 1080 px and about 300 KB (it's stored in the database)
  const img = await new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("That file isn't a photo.")); i.src = src; });
  for (const [size, q] of [[1080, .8], [960, .74], [800, .7], [640, .66]]) {
    const k = Math.min(1, size / Math.max(img.naturalWidth, img.naturalHeight)), c = document.createElement("canvas");
    c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const url = c.toDataURL("image/jpeg", q);
    if (url.length < 380000) return url;
  }
  throw new Error("That photo is too big. Try another one.");
}
async function share() {
  const btn = $("postCompose").querySelector("[data-pc-share]");
  draft.caption = $("pcCaption").value.trim();
  btn.disabled = true; btn.textContent = "Sharing…";
  const p = draft.place;
  try {
    await addDoc(collection(db, "feed"), {
      kind: "post", by: me.uid, byName: myName(), members: [me.uid], names: { [me.uid]: myName() }, photo: draft.photo,
      caption: draft.caption, at: new Date().toISOString(), venueName: p?.name || "", address: p?.address || "",
      venue: p ? [p.lat, p.lng] : null, likes: [], ratings: {}, viewers: [me.uid, ...friends().map(f => f.user_id)] });
    draft = null; $("postCompose").hidden = true; $("feed").scrollTo({ top: 0, behavior: "smooth" });
  } catch (e) { btn.disabled = false; btn.textContent = "Share"; compose(friendly(e, "share it")); }
}

// ---------- tabs ----------
// Feed and Map are screens; Plans and Me open their pages over the feed; + opens the planner
const pages = { plans: "plans", memories: "memories", me: "drawer", board: "board" };
function closePages() { for (const id of Object.values(pages)) if ($(id)) $(id).hidden = true; }
function go(t) {
  closePages();
  if (t === "plan") { window.openPlanner?.(); setTab("plan"); setTimeout(() => $("museText")?.focus(), 250); return; }
  if (t === "plans") { $("plansBtn").click(); return setTab("plans"); }
  if (t === "me") { $("userPic").click(); return setTab("me"); }
  setTab(t);
  if (t === "feed") return render();
  window.showMapTab?.();
}
function setTab(t) {
  tab = t;
  document.documentElement.dataset.tab = t;
  document.documentElement.classList.toggle("on-feed", t === "feed");
  $("feed").hidden = t !== "feed";
  $("tabs").querySelectorAll("[data-tab]").forEach(b => b.classList.toggle("on", b.dataset.tab === t));
  window.dispatchEvent(new CustomEvent("tab-changed", { detail: t }));
}
window.showTab = go;
// closing Plans or Me (the ×, or a swipe) goes back to the feed
for (const id of Object.values(pages)) {
  const el = $(id);
  if (el) new MutationObserver(() => {
    if (document.documentElement.classList.contains("has-tabs") && ["plans", "me"].includes(tab)
        && Object.values(pages).every(p => $(p)?.hidden)) setTab("feed");
  }).observe(el, { attributes: true, attributeFilter: ["hidden"] });
}

const native = !!window.Capacitor?.isNativePlatform?.();
function setUpTabs() {
  const on = !!me && (phone() || native);  // the iPhone and iPad app always have the tabs; on the website only phones do
  $("tabs").hidden = !on;
  document.documentElement.classList.toggle("has-tabs", on);
  if (!on) { $("feed").hidden = true; document.documentElement.classList.remove("on-feed"); delete document.documentElement.dataset.tab; return; }
  if (!setUpTabs.done) { setUpTabs.done = true; go("feed"); }  // the app opens on the feed
}
matchMedia("(max-width: 860px)").addEventListener("change", setUpTabs);

// ---------- taps ----------
document.addEventListener("click", async e => {
  const t = e.target.closest(`[data-tab], [data-tab-go], [data-free-menu], [data-free], [data-plan-with], [data-plan-at], [data-open-plan],
    [data-like], [data-rate], [data-post-menu], [data-report], [data-block], [data-hide-post], [data-unshare-post], [data-comments],
    [data-del-comment], [data-report-comment], [data-new-post], [data-pc-cancel], [data-pc-share], [data-pc-place], [data-pc-unplace], #feedChats`);
  if (!t || !t.closest("#feed, #tabs, #postCompose")) return;
  const ds = t.dataset;
  tick();
  if (ds.tab || ds.tabGo) return go(ds.tab || ds.tabGo);
  if (t.id === "feedChats") return $("inboxBtn").click();
  if (t.hasAttribute("data-new-post")) return pickPhoto();
  if (t.hasAttribute("data-pc-cancel")) { draft = null; $("postCompose").hidden = true; return; }
  if (t.hasAttribute("data-pc-share")) return share();
  if (ds.pcPlace) {
    let p = draft.found[+ds.pcPlace];
    if (p && p.lat == null) p = { ...p, ...(await fetch(`/places/details?id=${encodeURIComponent(p.id)}&session=${compose.session}`).then(r => r.json()).catch(() => ({}))) };
    compose.session = null;
    if (p?.lat == null) return compose("Couldn't find that place. Try another.");
    draft.caption = $("pcCaption").value; draft.place = { name: p.name, address: p.address || "", lat: p.lat, lng: p.lng };
    return compose();
  }
  if (t.hasAttribute("data-pc-unplace")) { draft.caption = $("pcCaption").value; draft.place = null; return compose(); }
  if (t.hasAttribute("data-free-menu")) { freeMenu = !freeMenu; return render(); }
  if (ds.free) {
    const end = new Date();
    if (ds.free === "2") end.setHours(end.getHours() + 2);
    else if (end.getHours() >= 21) end.setHours(end.getHours() + 3);  // late already: the next few hours
    else end.setHours(23, 59, 0, 0);
    freeMenu = false;
    await setDoc(doc(db, "users", me.uid), { freeUntil: ds.free === "off" ? null : end.toISOString() }, { merge: true })
      .catch(err => alert(friendly(err, "update that")));
    return render();
  }
  if (ds.planWith) { go("plan"); window.planWith?.([ds.planWith]); return; }
  if (ds.planAt) {
    const p = posts[ds.planAt];
    if (!p?.venue) return;
    go("plan"); window.planAt?.(p.venue, p.venueName, p.address || "");
    return;
  }
  if (ds.openPlan) { setTab("plans"); return window.openPlanCard?.(ds.openPlan); }
  if (ds.comments) {
    openComments.has(ds.comments) ? openComments.delete(ds.comments) : openComments.add(ds.comments);
    render();
    return $("feed").querySelector(`[data-comment-form="${CSS.escape(ds.comments)}"] input`)?.focus();
  }
  if (ds.delComment || ds.reportComment) {
    const [pid, cid] = (ds.delComment || ds.reportComment).split("/");
    if (ds.delComment) return deleteDoc(doc(db, "feed", pid, "comments", cid)).catch(err => alert(friendly(err, "delete it")));
    if (!confirm("Report this comment? We'll review it within 24 hours.")) return;
    return setDoc(doc(db, "reports", `${pid}_${cid}_${me.uid}`), { post: pid, comment: cid, by: me.uid, at: new Date().toISOString() })
      .then(() => alert("Thanks. We'll take a look.")).catch(err => alert(friendly(err, "report it")));
  }
  if (ds.postMenu) { menuFor = menuFor === ds.postMenu ? null : ds.postMenu; return render(); }
  if (ds.hidePost || ds.report) {
    const id = ds.hidePost || ds.report;
    if (ds.report) {
      if (!confirm("Report this post? We'll review it within 24 hours and remove it if it breaks the rules. It's hidden for you now.")) return;
      const p = posts[id];
      await setDoc(doc(db, "reports", `${id}_${me.uid}`), { post: id, poster: p.by, members: p.members, by: me.uid, at: new Date().toISOString() })
        .catch(err => alert(friendly(err, "report it")));
    }
    try { localStorage.setItem(hiddenKey(), JSON.stringify([...hidden(), id])); } catch { /* private mode */ }
    menuFor = null; return render();
  }
  if (ds.block) {
    const name = first(Object.values(posts).find(p => p.by === ds.block)?.names?.[ds.block]);
    if (!confirm(`Block ${name}? You won't see their posts, or posts they're in.`)) return;
    menuFor = null;
    return setDoc(doc(db, "users", me.uid), { blocked: arrayUnion(ds.block) }, { merge: true }).catch(err => alert(friendly(err, "block them")));
  }
  if (ds.unsharePost) {
    if (posts[ds.unsharePost]?.kind === "post" && !confirm("Delete this post?")) return;
    menuFor = null; return window.unshareFromFeed(ds.unsharePost).catch(err => alert(friendly(err, "delete it")));
  }
  if (ds.like) return like(ds.like);
  if (ds.rate) return updateDoc(doc(db, "feed", ds.rate), { [`ratings.${me.uid}`]: Number(ds.score) }).catch(err => alert(friendly(err, "rate it")));
});
document.addEventListener("submit", e => {
  const f = e.target.closest("[data-comment-form]");
  if (!f) return;
  e.preventDefault();
  const input = f.querySelector("input"), text = input.value.trim();
  if (!text) return;
  input.value = ""; input.blur();
  addDoc(collection(db, "feed", f.dataset.commentForm, "comments"), { from: me.uid, name: myName(), text, at: new Date().toISOString() })
    .catch(err => alert(friendly(err, "post that")));
});
// double-tap the photo to like it, like Instagram
let lastTap = { id: null, at: 0 };
document.addEventListener("click", e => {
  const ph = e.target.closest("[data-like-twice]");
  if (!ph) return;
  const id = ph.dataset.likeTwice, now = Date.now();
  if (lastTap.id === id && now - lastTap.at < 350) {
    if (!posts[id]?.likes?.includes(me.uid)) { tick(); like(id); }
    ph.classList.remove("pop"); void ph.offsetWidth; ph.classList.add("pop");
    lastTap = { id: null, at: 0 };
  } else lastTap = { id, at: now };
});
function like(id) {
  const p = posts[id], on = !p.likes?.includes(me.uid);
  p.likes = on ? [...(p.likes || []), me.uid] : p.likes.filter(u => u !== me.uid);  // show it right away
  render();
  updateDoc(doc(db, "feed", id), { likes: on ? arrayUnion(me.uid) : arrayRemove(me.uid) }).catch(err => alert(friendly(err, "like it")));
}

// ---------- sharing a group photo (memories.js calls these) ----------
async function smaller(dataUrl) {  // feed photos are loaded 30 at a time: keep each around 150 KB
  const img = await new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = dataUrl; });
  const k = Math.min(1, 960 / Math.max(img.naturalWidth, img.naturalHeight)), c = document.createElement("canvas");
  c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
  c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
  return c.toDataURL("image/jpeg", .74);
}
const lateOf = h => Object.fromEntries((h.attendees || []).filter(u => h.arrivals?.[u])
  .map(u => [u, Math.max(0, Math.round((new Date(h.arrivals[u]) - new Date(h.start)) / 6e4))]));
window.shareToFeed = async (h, m) => {  // h: the hangout (or what the memory remembers of it), m: the memory
  const members = m.members || h.attendees;  // exactly the memory's people (the rules check)
  await setDoc(doc(db, "feed", h.id), {
    by: me.uid, byName: m.byName || "", members, names: m.names || h.names || {}, photo: await smaller(m.photo), at: m.at,
    start: h.start || m.start, title: plainTitle(h.title || m.title), venueName: h.venueName || m.venueName || "", address: h.address || m.address || "",
    venue: Array.isArray(h.venue) ? h.venue : null, late: lateOf(h), likes: [], ratings: {},
    viewers: [...new Set([...members, ...friends().map(p => p.user_id)])] });
};
window.updateFeedPhoto = async (id, photo, at) => { if (posts[id]) await updateDoc(doc(db, "feed", id), { photo: await smaller(photo), at }); };
window.unshareFromFeed = id => deleteDoc(doc(db, "feed", id));
window.feedHas = id => !!posts[id];

// the people in a post each show it to their own friends (new friends see your older posts too)
function widen() {
  const mine = friends().map(p => p.user_id);
  for (const p of Object.values(posts)) {
    if (!p.members.includes(me.uid)) continue;
    const missing = mine.filter(u => !p.viewers?.includes(u));
    const key = `${p.id}:${missing.join(",")}`;
    if (!missing.length || widened.has(key)) continue;
    widened.add(key);
    updateDoc(doc(db, "feed", p.id), { viewers: arrayUnion(...missing) }).catch(() => {});
  }
}

// ---------- your status for friends: out at a hangout, or on your way (unless you turned off sharing your location) ----------
function myNow() {
  const now = Date.now();
  for (const h of window.myHangouts || []) {
    const start = new Date(h.start).getTime(), end = start + (h.durationMin || 120) * 6e4;
    if (now > end) continue;
    if (h.arrivals?.[me.uid]) return { kind: "out", until: new Date(end).toISOString() };
    const leave = h.alerts?.[me.uid] ? new Date(h.alerts[me.uid]).getTime() : start - 30 * 6e4;
    if (now >= leave && now < start + 60 * 6e4) return { kind: "omw", until: new Date(start + 60 * 6e4).toISOString() };
  }
  return null;
}
function sendNow() {
  if (!me || !db) return;
  const mine = (window.myFriends || []).find(p => p.isMe);
  if (!mine) return;
  const now = mine.sharing === false ? null : myNow(), key = JSON.stringify(now);
  if (key === nowSent) return;
  nowSent = key;
  setDoc(doc(db, "users", me.uid), { now }, { merge: true }).catch(() => (nowSent = ""));
}
setInterval(() => { sendNow(); if (tab === "feed" && !$("feed")?.hidden) render(); }, 60000);
window.addEventListener("hangouts-changed", () => { sendNow(); render(); });
window.addEventListener("friends-changed", () => { sendNow(); widen(); render(); });
window.addEventListener("memories-changed", render);

$("meBoard")?.addEventListener("click", () => $("boardBtn").click());  // the leaderboard opens from Me

// the chat button in the feed shows the same unread count as the one on the map
const badge = $("inboxBadge");
if (badge) new MutationObserver(() => { $("feedChatBadge").hidden = badge.hidden; $("feedChatBadge").textContent = badge.textContent; })
  .observe(badge, { attributes: true, childList: true, characterData: true, subtree: true });

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    stopFeed?.(); stopFeed = null; posts = {}; me = u; nowSent = ""; widened = new Set();
    Object.values(commentStops).forEach(s => s()); commentStops = {}; comments = {};
    setUpTabs();
    if (!u) { setUpTabs.done = false; return; }
    const listen = q => onSnapshot(q, s => {
      posts = Object.fromEntries(s.docs.map(d => [d.id, { ...d.data(), id: d.id }]));
      widen(); listenComments(); render();
      window.dispatchEvent(new Event("feed-changed"));  // the map's "Friends' spots"
    }, err => {
      // the newest-first query needs a Firestore index (DEPLOY.md); until it's made, show them unsorted
      if (err.code === "failed-precondition" && !listen.fallback) {
        console.warn("feed: create the index from this link:", err.message);
        listen.fallback = true;
        stopFeed = listen(query(collection(db, "feed"), where("viewers", "array-contains", u.uid), limit(POSTS)));
      } else console.warn("feed:", err.message);
    });
    listen.fallback = false;
    stopFeed = listen(query(collection(db, "feed"), where("viewers", "array-contains", u.uid), orderBy("at", "desc"), limit(POSTS)));
    render();
  });
}
