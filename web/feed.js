// The feed: the home screen on phones and in the iPhone / iPad app, like BeReal / Beli. Group photos from your friends' hangouts,
// who's out, on their way or free right now, and the places your friends rate best. Tabs at the bottom: Feed, Map, +, Ranks, Me.
// feed/{hangout id} = { by, byName, members, names, photo (small JPEG data URL), at, start, title, venueName, address,
//   venue: [lat, lng] | null, late: { uid: minutes late }, viewers: [uid], likes: [uid], ratings: { uid: 9 | 5.5 | 2 } }
// viewers = the people who went plus each one's friends: whoever posts adds their own friends, the others add theirs when their app
// sees the post. Posting to the feed is a choice when you post the group photo (on by default), and the poster can take it off.
// Report and block (App Store rule for apps where people see each other's posts): reports/{post}_{you} for us to review,
// and users/{uid}.blocked hides everything posted by or with that person.
// Your status for friends lives on your profile: users/{uid}.freeUntil (you tapped "I'm free") and .now = { kind: "out" | "omw", until }.
import { firebaseConfig } from "./firebase-config.js";
import { initializeApp, getApps, getApp } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-app.js";
import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.12.2/firebase-auth.js";
import { getFirestore, collection, doc, query, where, orderBy, limit, onSnapshot, setDoc, updateDoc, deleteDoc, arrayUnion, arrayRemove }
  from "https://www.gstatic.com/firebasejs/10.12.2/firebase-firestore.js";

const POSTS = 30;            // newest posts loaded (each carries its photo)
const ON_TIME_MIN = 5;       // later than this and the post says who was late
const RATINGS = [[9, "Loved it"], [5.5, "It was fine"], [2, "Didn't like it"]];  // Beli's three buckets, as a score out of 10
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const phone = () => matchMedia("(max-width: 860px)").matches;
const tick = () => window.Capacitor?.Plugins?.Haptics?.impact({ style: "LIGHT" }).catch(() => {});  // a light tap in the iPhone app

let db, me = null, posts = {}, stopFeed = null, view = "friends", tab = "feed", freeMenu = false, widened = new Set(), nowSent = "", menuFor = null;

// ---------- helpers ----------
const friends = () => (window.myFriends || []).filter(p => !p.isMe);
const friendOf = uid => (window.myFriends || []).find(p => p.user_id === uid);
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
  $("feed").querySelectorAll("[data-feed-view]").forEach(b => b.classList.toggle("on", b.dataset.feedView === view));
  $("feedBody").innerHTML = view === "places" ? placesHtml() : friendsRow() + upNext() + snapBanner() + postsHtml();
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
    ${list.length ? "" : `<button class="ff-friend" data-tab-go="me">${`<span class="ff big add">${icon("user-round-plus")}</span>`}<b>Add friends</b><small>by friend ID</small></button>`}
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
    When you or your friends hang out, the group photo shows up here.<button class="fe-go" data-tab-go="plan">${icon("plus")} Plan a hangout</button></div>`;
  return list.map(p => {
    const members = [...p.members].sort((a, b) => (b === me.uid) - (a === me.uid) || !!friendOf(b) - !!friendOf(a));
    const names = members.map(u => u === me.uid ? "You" : first(p.names?.[u]));
    const who = names.length <= 3 ? names.join(", ").replace(/, ([^,]*)$/, " & $1") : `${names.slice(0, 2).join(", ")} & ${names.length - 2} more`;
    const liked = p.likes?.includes(me.uid), mine = p.members.includes(me.uid), s = score(p), km = kmFromMe(p.venue);
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
            km != null ? (km < 1 ? `${Math.round(km * 1000)} m away` : `${km.toFixed(1)} km away`) : ""].filter(Boolean).join(" · "))}</small></span>
        </div>` : ""}
      </div>
      ${mine && !myRating && p.venueName ? `<div class="fp-rate"><span>How was ${esc(p.venueName)}?</span>
        <div>${RATINGS.map(([v, l]) => `<button data-rate="${esc(p.id)}" data-score="${v}">${esc(l)}</button>`).join("")}</div></div>` : ""}
      <footer>
        <button class="fp-like ${liked ? "on" : ""}" data-like="${esc(p.id)}" aria-label="${liked ? "Unlike" : "Like"}">${icon("heart")}<span>${p.likes?.length || ""}</span></button>
        ${myRating ? `<small class="fp-mine">You: ${esc(RATINGS.find(r => r[0] === myRating)?.[1] || myRating)}</small>` : ""}
        <span class="fp-gap"></span>
        ${p.venue ? `<button class="fp-plan" data-plan-at="${esc(p.id)}">Plan this with friends</button>` : ""}
      </footer>
    </article>`;
  }).join("");
}

function postMenu(p) {
  const poster = p.by === me.uid ? "you" : first(p.names?.[p.by]);
  return `<div class="fp-menu">${p.by === me.uid
    ? `<button data-unshare-post="${esc(p.id)}">${icon("eye")} Take it off the feed</button>`
    : `<button data-report="${esc(p.id)}">${icon("flag")} Report this post</button>
       <button data-block="${esc(p.by)}">${icon("user-x")} Block ${esc(poster)}</button>`}
    <button data-hide-post="${esc(p.id)}">${icon("x")} Hide this post</button></div>`;
}

function placesHtml() {  // Beli-style: the spots your friends rated, best first
  const by = {};
  for (const p of visible()) {
    if (!p.venueName) continue;
    const k = `${p.venueName}|${p.address || ""}`;
    const v = by[k] ||= { name: p.venueName, address: p.address, venue: p.venue, id: p.id, ratings: [], visits: 0, people: new Set() };
    v.ratings.push(...Object.values(p.ratings || {}));
    v.visits++;
    p.members.forEach(u => v.people.add(u === me.uid ? "You" : first(p.names?.[u])));
    if (p.venue) v.venue = p.venue;
  }
  const list = Object.values(by).map(v => ({ ...v, score: v.ratings.length ? v.ratings.reduce((a, b) => a + b, 0) / v.ratings.length : null }))
    .sort((a, b) => (b.score ?? -1) - (a.score ?? -1) || b.visits - a.visits);
  if (!list.length) return `<div class="feed-empty">${icon("star")}<b>No places yet</b>
    After a hangout, everyone who went rates the spot. Your friends' favorites end up here.</div>`;
  return `<div class="pl-list">${list.map((v, i) => `<div class="pl-row">
    <span class="pl-rank">${i + 1}</span>
    <span class="pl-name"><b>${esc(v.name)}</b><small>${v.visits} visit${v.visits === 1 ? "" : "s"} · ${esc([...v.people].slice(0, 3).join(", "))}</small></span>
    <span class="fp-score ${v.score == null ? "none" : ""}">${v.score == null ? "new" : v.score.toFixed(1)}</span>
    ${v.venue ? `<button class="pl-go" data-plan-at="${esc(v.id)}" aria-label="Plan a hangout at ${esc(v.name)}">${icon("plus")}</button>` : ""}
  </div>`).join("")}</div>`;
}

// ---------- tabs ----------
function go(t) {
  if (t === "ranks") return $("boardBtn").click();     // the leaderboard page (who's always late)
  if (t === "me") return $("userPic").click();          // profile and friends
  tab = t === "plan" ? "map" : t;
  document.documentElement.classList.toggle("on-feed", tab === "feed");
  $("feed").hidden = tab !== "feed";
  $("tabs").querySelectorAll("[data-tab]").forEach(b => b.classList.toggle("on", b.dataset.tab === tab));
  if (tab === "feed") return render();
  window.invalidateMap?.();
  if (t === "plan") { window.openSheet?.(); setTimeout(() => $("museText")?.focus(), 250); }
}
window.showTab = go;

const native = !!window.Capacitor?.isNativePlatform?.();
function setUpTabs() {
  const on = !!me && (phone() || native);  // the iPhone and iPad app always have the tabs; on the website only phones do
  $("tabs").hidden = !on;
  document.documentElement.classList.toggle("has-tabs", on);
  if (!on) { $("feed").hidden = true; document.documentElement.classList.remove("on-feed"); return; }
  if (!setUpTabs.done) { setUpTabs.done = true; go("feed"); }  // the app opens on the feed
}
matchMedia("(max-width: 860px)").addEventListener("change", setUpTabs);

// ---------- taps ----------
document.addEventListener("click", async e => {
  const t = e.target.closest("[data-tab], [data-tab-go], [data-feed-view], [data-free-menu], [data-free], [data-plan-with], [data-plan-at], [data-open-plan], [data-like], [data-rate], [data-post-menu], [data-report], [data-block], [data-hide-post], [data-unshare-post], #feedChats");
  if (!t || !t.closest("#feed, #tabs")) return;
  const ds = t.dataset;
  tick();
  if (ds.tab || ds.tabGo) return go(ds.tab || ds.tabGo);
  if (ds.feedView) { view = ds.feedView; return render(); }
  if (t.id === "feedChats") return $("inboxBtn").click();
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
  if (ds.planWith) { go("map"); window.planWith?.([ds.planWith]); return; }
  if (ds.planAt) {
    const p = posts[ds.planAt];
    if (!p?.venue) return;
    go("map"); window.planAt?.(p.venue, p.venueName, p.address || "");
    return;
  }
  if (ds.openPlan) return window.openPlanCard?.(ds.openPlan);
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
  if (ds.unsharePost) { menuFor = null; return window.unshareFromFeed(ds.unsharePost).catch(err => alert(friendly(err, "take it off"))); }
  if (ds.like) return like(ds.like);
  if (ds.rate) return updateDoc(doc(db, "feed", ds.rate), { [`ratings.${me.uid}`]: Number(ds.score) }).catch(err => alert(friendly(err, "rate it")));
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

// ---------- posting (memories.js calls these) ----------
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

// the people who went each show it to their own friends
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

// the chat button in the feed shows the same unread count as the one on the map
const badge = $("inboxBadge");
if (badge) new MutationObserver(() => { $("feedChatBadge").hidden = badge.hidden; $("feedChatBadge").textContent = badge.textContent; })
  .observe(badge, { attributes: true, childList: true, characterData: true, subtree: true });

if (firebaseConfig.apiKey && !firebaseConfig.apiKey.startsWith("PASTE")) {
  const app = getApps().length ? getApp() : initializeApp(firebaseConfig);
  db = getFirestore(app);
  onAuthStateChanged(getAuth(app), u => {
    stopFeed?.(); stopFeed = null; posts = {}; me = u; nowSent = ""; widened = new Set();
    setUpTabs();
    if (!u) { setUpTabs.done = false; return; }
    const listen = q => onSnapshot(q, s => {
      posts = Object.fromEntries(s.docs.map(d => [d.id, { ...d.data(), id: d.id }]));
      widen(); render();
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
