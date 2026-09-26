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
import { calendarHangouts } from "./gcal.js";
import { checkInHtml, leaderboardHangouts } from "./leaderboard.js";
import { liveHangouts, sharingNow, shareStart } from "./live.js";
import { chatHangouts, unreadCount, postLeft } from "./chat.js";
import { COLOR_PARTS, optionsFor, cleanLook, randomLook, withGender, characterSrc, renderJpeg } from "./character.js";

const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const MODES = { driving: "Drive", walking: "Walk", cycling: "Bike", transit: "Transit" };
const MODE_ICON = { driving: "car", walking: "footprints", cycling: "bike", transit: "bus" };
const ID_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";  // no 0/O or 1/I/L, so IDs are easy to read out loud

let me = null, profile = {}, friendIds = [], friends = {}, incoming = [], outgoing = [], hangouts = [], invites = [], calToken = "", stop = [];
let hangoutDocs = {};  // every hangout you're invited to or going to, by id

const say = (text, ok = false) => { $("addMsg").textContent = text; $("addMsg").className = ok ? "ok" : ""; };
const randomId = () => Array.from(crypto.getRandomValues(new Uint32Array(6)), n => ID_CHARS[n % ID_CHARS.length]).join("");
const cleanId = v => v.toUpperCase().replace(/[^A-Z0-9]/g, "");
// ---------- avatars: make one with AI, build your own character (character.js), or use your own photo ----------
// friends see it as a small JPEG saved on your profile. Nothing changes until you tap Save.
// avatar = { style: "ai", traits, extra, bg } (the drawing itself is in private/{uid}.avatarArt, so you can change the color later)
//        | { style: "real", v: 2, look }, plus useUpload / usePhoto  (older omw avatars had other styles; their saved picture keeps working)
const AV_BGS = ["ffd66b", "ffb3c7", "c7b8ff", "9fe6c8", "a8d8ff", "ffc49c", "f1f0f7", "2b2b3a"];
const hashOf = s => [...String(s)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7);
const usesUpload = (a, upload) => !!(a?.useUpload && upload);
const usesPhoto = (a, user) => !a?.useUpload && !!user?.photoURL && (a?.style ? !!a.usePhoto : true);
const myLook = () => cleanLook(profile.avatar?.style === "real" ? profile.avatar.look : randomLook(me.uid));
const loadImg = src => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => no(new Error("Couldn't load that avatar.")); i.src = src; });
// the AI's drawing on its color, as a 256 px JPEG
async function onColor(src, bg) {
  const img = await loadImg(src), c = document.createElement("canvas"), g = c.getContext("2d");
  c.width = c.height = 256;
  g.fillStyle = "#" + bg; g.fillRect(0, 0, 256, 256);
  g.imageSmoothingQuality = "high";
  g.drawImage(img, 0, 6, 256, 256);
  return c.toDataURL("image/jpeg", 0.88);
}
// the picture for a profile: your upload, your Google/Facebook photo (the default), your AI avatar or your character
async function photoFor(a, user, upload, saved, art) {
  if (usesUpload(a, upload)) return upload;
  if (usesPhoto(a, user)) return user.photoURL;
  if (a?.style === "ai" && art) return onColor(art, a.bg);
  // characters saved before the 3D-style redraw (no v: 2) are drawn again in the new style
  if (a?.style === "real") return a.v === 2 && /^data:image\/jpeg/.test(saved || "") ? saved : renderJpeg(a.look);
  if (a?.style && saved) return saved;  // an older avatar, or an AI one (already saved)
  return renderJpeg(randomLook(user.uid));  // no photo at all: a character to start with
}
// shrink the AI's 1024 px drawing to 512 px (still see-through), small enough to keep
async function shrinkArt(src) {
  const img = await loadImg(src), c = document.createElement("canvas");
  c.width = c.height = 512;
  c.getContext("2d").imageSmoothingQuality = "high";
  c.getContext("2d").drawImage(img, 0, 0, 512, 512);
  const webp = c.toDataURL("image/webp", 0.9);
  return webp.startsWith("data:image/webp") ? webp : c.toDataURL("image/png");
}
// only real pictures: web links or uploaded images (anything else someone saved could break the page)
const safePhoto = s => typeof s === "string" && /^(https:\/\/|data:image\/(jpeg|png|webp);base64,)[^"'<>\s]*$/.test(s) ? s : "";

// shrink an uploaded picture to a 256 px square (center crop), as a small JPEG
function shrinkPhoto(file, size = 256) {
  return new Promise((ok, no) => {
    if (!file.type.startsWith("image/")) return no(new Error("That's not a picture."));
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      const side = Math.min(img.width, img.height), canvas = document.createElement("canvas");
      canvas.width = canvas.height = size;
      canvas.getContext("2d").drawImage(img, (img.width - side) / 2, (img.height - side) / 2, side, side, 0, 0, size, size);
      URL.revokeObjectURL(url);
      ok(canvas.toDataURL("image/jpeg", 0.85));
    };
    img.onerror = () => { URL.revokeObjectURL(url); no(new Error("Couldn't open that picture. Try a JPG or PNG.")); };
    img.src = url;
  });
}
let ccTab = "hair";  // which part of your character you're changing
let draft = null;  // what you're trying on in the editor: { mode: "ai" | "character" | "old" | "upload" | "photo", look, art, bg, ... }

const pic = (p, cls = "") => safePhoto(p.photo)
  ? `<div class="avatar ${cls}" style="background-image:url('${esc(safePhoto(p.photo))}')"></div>`
  : `<div class="avatar ${cls}" style="--c:#ffb000"><span>${esc((p.name || "?").slice(0, 2).toUpperCase())}</span></div>`;

// tell the planner who's in "My friends" (you + everyone who accepted)
function publish() {
  const toPerson = (uid, p) => ({ user_id: uid, name: p.name || "Friend", travel_mode: p.travelMode || "driving",
                                  home: p.home ? [p.home.lat, p.home.lng] : null, photo: safePhoto(p.photo), real: true, code: p.code || "",
                                  busy: p.busy || [],
                                  // how many minutes after their alert they really left, from their check-ins (the model learns from these)
                                  habits: (Array.isArray(p.habits) ? p.habits : []).filter(x => typeof x?.delay === "number").slice(-30).map(x => x.delay),
                                  // every check-in they've made (any hangout, even ones you weren't at): minutes late, for the leaderboard
                                  checkins: (Array.isArray(p.habits) ? p.habits : []).filter(x => typeof x?.late === "number").slice(-50)
                                    .map(x => ({ id: String(x.id || ""), late: x.late })) });
  window.myFriends = me ? [{ ...toPerson(me.uid, profile), name: "You", realName: profile.name || "Me", isMe: true },
                           ...friendIds.filter(id => friends[id]).map(id => toPerson(id, friends[id]))] : [];
  window.myCategories = profile.categories || [];  // hangout categories you made (emoji + name)
  window.dispatchEvent(new Event("friends-changed"));
}

// ---------- drawing the panel ----------
function renderMe() {
  $("meAvatar").outerHTML = pic(profile, "big").replace('class="avatar', 'id="meAvatar" title="Change your avatar" class="avatar');
  $("meAvatar").onclick = () => { $("avatarEditor").hidden = !$("avatarEditor").hidden; draft = null; if (!$("avatarEditor").hidden) openAvatarEditor(); };
  if (safePhoto(profile.photo)) { $("userPic").style.backgroundImage = `url("${safePhoto(profile.photo)}")`; $("userPic").textContent = ""; }
  if (!$("avatarEditor").hidden) renderAvatarEditor();  // your draft stays as it is
  if (document.activeElement !== $("meName")) $("meName").value = profile.name || "";
  $("meCode").textContent = profile.code || "······";
  $("meModes").querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.mode === (profile.travelMode || "driving")));
  $("meHome").innerHTML = profile.home
    ? `${icon("circle-check")} <b>${esc(profile.homeName || "Home set")}</b>${profile.homeAddress ? `<small>${esc(profile.homeAddress)}</small>` : ""}`
    : `${icon("triangle-alert")} Not set yet. The planner needs it to time your alerts.`;
  if ($("setHome").dataset.busy !== "1") $("setHome").textContent = profile.home ? "Update to where I am now" : "Use my current location";
  if (document.activeElement !== $("schedText")) $("schedText").value = profile.scheduleText || "";
  renderBusy(profile.busy || []);
}

// what the AI can be asked for (the server has the same list and ignores anything else)
const AI_PARTS = [
  ["skin", "Skin", { light: "fde0cf", fair: "f5cdb3", tan: "e0ac85", medium: "c98d62", brown: "8a5230", dark: "5e3720" }],
  ["hair", "Hair", ["short", "sidePart", "curly", "afro", "spiky", "buzz", "long", "wavy", "bob", "bun", "ponytail", "pigtails", "braids", "locs", "hijab", "bald"]],
  ["hairColor", "Hair color", { black: "16100c", darkBrown: "3b2417", brown: "8a5a33", blonde: "f2c94c", ginger: "e0612f", gray: "b9b4ae",
                                white: "f4f1ea", pink: "ff9ccf", purple: "9b6cff", blue: "3d8bff", green: "3fbf6b", rainbow: "rainbow" }],
  ["hat", "Hat", ["none", "cap", "backwards", "beanie", "catBeanie", "beret", "bucket", "cowboy", "headband", "headphones", "bow", "bunny", "crown", "strawberry"]],
  ["glasses", "Glasses", ["none", "round", "square", "sunglasses", "tinted", "stars", "hearts"]],
  ["face", "Face", ["smile", "grin", "tongue", "wink", "surprised", "cool", "calm"]],
  ["extras", "Extras", ["freckles", "beard", "mustache", "earrings", "lashes", "blush", "noseRing"]],
];
const LABELS = { sidePart: "Side part", buzz: "Buzz cut", catBeanie: "Cat beanie", backwards: "Backwards cap", bucket: "Bucket hat",
                 cowboy: "Cowboy hat", headband: "Sweatband", bunny: "Bunny ears", tinted: "Rainbow shades", stars: "Star glasses",
                 hearts: "Heart shades", round: "Round", square: "Square", tongue: "Tongue out", noseRing: "Nose ring", lashes: "Lashes",
                 darkBrown: "Dark brown", strawberry: "Strawberry" };
const nice = v => LABELS[v] || (v === "none" ? "None" : v.replace(/^./, c => c.toUpperCase()));
let aiReady = null;  // is the server set up to draw avatars?
let myArt = "";      // your AI avatar's drawing (from private/{uid})
let making = 0;      // which request is drawing right now (0: none)

const TABS = { gender: "Gender", skin: "Skin", face: "Face", hair: "Hair", hairColor: "Hair color", hat: "Hat", hatColor: "Hat color",
               eyes: "Eyes", eyeColor: "Eye color", brows: "Brows", nose: "Nose", mouth: "Mouth", beard: "Beard", glasses: "Glasses",
               bg: "Background" };
const ZOOM = { face: "head", hair: "head", eyes: "face", eyeColor: "face", brows: "face", nose: "face", mouth: "face", beard: "head", glasses: "face", hat: "head" };
const GENDERS = { man: "Man", woman: "Woman" };
const partName = v => GENDERS[v] || (v === "none" ? "None" : v.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, c => c.toUpperCase()));

const savedDraft = () => {
  const a = profile.avatar || {};
  return { mode: usesUpload(a, profile.upload) ? "upload" : usesPhoto(a, me) ? "photo"
               : a.style === "ai" && myArt ? "ai" : a.style === "real" || !safePhoto(profile.photo) ? "character" : "old",
           look: myLook(), bg: a.style === "ai" && a.bg ? a.bg : AV_BGS[hashOf(me.uid) % 6],
           upload: profile.upload || "", art: a.style === "ai" ? myArt : "", traits: a.traits || {}, extra: a.extra || "",
           made: myArt ? [myArt] : [], selfie: "", tab: draft?.tab };
};
const changed = () => { const s = savedDraft();
  return draft.mode !== s.mode || draft.upload !== s.upload || (draft.mode === "ai" && (draft.art !== s.art || draft.bg !== s.bg))
      || (draft.mode === "character" && JSON.stringify(draft.look) !== JSON.stringify(s.look)); };

// with an AI avatar on screen, the choices change that one (only what you pick) instead of drawing a new one
const aiEditing = () => draft.tab === "create" && draft.mode === "ai" && !!draft.art && draft.aiMode !== "new";

async function openAvatarEditor() {
  draft = null;
  renderAvatarEditor();
  if (aiReady === null) fetch("/ai/avatar").then(r => r.json()).then(d => { aiReady = !!d.ready; }).catch(() => { aiReady = false; })
    .finally(() => !$("avatarEditor").hidden && renderAvatarEditor());
  if (profile.avatar?.style === "ai" && !myArt) {
    try { myArt = (await getDoc(doc(db, "private", me.uid))).data()?.avatarArt || ""; } catch { /* keep the saved picture */ }
    if (myArt && !$("avatarEditor").hidden && draft && !changed()) { draft = null; renderAvatarEditor(); }
  }
}

function renderAvatarEditor() {
  if (!draft) draft = savedDraft();
  draft.tab ||= aiReady === false || draft.mode === "character" ? "build" : "create";
  const m = draft.mode, onBg = m === "ai", l = draft.look, editing = aiEditing();
  draft.changes ||= {};
  const t = editing ? draft.changes : draft.traits, anyWord = editing ? "Keep" : "Any";
  const preview = m === "upload" ? safePhoto(draft.upload) : m === "photo" ? safePhoto(me.photoURL) : m === "old" ? safePhoto(profile.photo)
                : m === "ai" ? draft.art : characterSrc(l);
  const box = document.querySelector("#avatarEditor .cc-opts, #avatarEditor .ai-form");
  const keep = box?.scrollTop || 0, keepTabs = document.querySelector("#avatarEditor .cc-tabs")?.scrollLeft || 0;
  // building: each gender has its own choices; a tab with nothing to pick (Beard for Woman) is hidden
  const tabs = Object.keys(TABS).filter(k => COLOR_PARTS[k] || optionsFor(l, k).length > 1);
  if (!tabs.includes(ccTab)) ccTab = "gender";
  const colors = COLOR_PARTS[ccTab], opts = colors || optionsFor(l, ccTab);
  const rows = Object.fromEntries([...document.querySelectorAll("#avatarEditor [data-row]")].map(r => [r.dataset.row, r.scrollLeft]));
  const chips = (key, opts) => Array.isArray(opts)
    ? `<button class="${!t[key] || (key === "extras" && !t.extras?.length) ? "on" : ""}" data-trait="${key}" data-val="">${anyWord}</button>` +
      opts.map(v => `<button class="${(key === "extras" ? (t.extras || []).includes(v) : t[key] === v) ? "on" : ""}" data-trait="${key}" data-val="${v}">${nice(v)}</button>`).join("")
    : `<button class="sw any ${editing ? "keep" : ""} ${!t[key] ? "on" : ""}" data-trait="${key}" data-val="" title="${editing ? "Keep as it is" : "Any: the AI picks"}">${editing ? "Keep" : icon("shuffle")}</button>` +
      Object.entries(opts).map(([v, c]) => `<button class="sw ${t[key] === v ? "on" : ""}" style="background:${c === "rainbow" ? "conic-gradient(#ff5b5b,#ffd23f,#3fbf6b,#3d8bff,#9b6cff,#ff5b5b)" : "#" + c}" data-trait="${key}" data-val="${v}" title="${nice(v)}"></button>`).join("");
  const busy = !!making;
  $("avatarEditor").innerHTML = `
    <div class="cc-top">
      <div class="cc-preview ${onBg ? "pick ai" : ""} ${busy ? "busy" : ""}" style="${onBg ? `background:#${draft.bg}` : ""}">
        ${preview ? `<img src="${esc(preview)}" alt="Preview">` : ""}${busy ? `<i class="av-spin"></i>` : ""}</div>
      <div><b>${onBg ? "Your avatar" : m === "character" ? "Your character" : m === "upload" ? "Your photo" : m === "photo" ? "Your account photo" : "Your current avatar"}</b>
        <small>${busy ? "Drawing your avatar… about 20 seconds." : onBg ? "Pick a color too, then tap Save." : m === "character" ? "Try things on below, then tap Save." : "Make or build an avatar below to use it instead."}</small>
        <div class="cc-actions">
          ${draft.tab === "build" ? `<button data-random="1">${icon("shuffle")} Surprise me</button>` : ""}
          ${draft.upload && m !== "upload" ? `<button data-use-upload="1">${icon("image")} Use my photo</button>` : ""}
          ${me.photoURL && m !== "photo" ? `<button data-use-photo="1">${icon("user")} Account photo</button>` : ""}
          <label class="cc-upload">${icon("upload")} Upload photo<input type="file" accept="image/*" id="photoFile" hidden></label>
        </div></div>
    </div>
    <div class="note av-err" id="photoMsg">${esc(draft.err || "")}</div>
    ${draft.tab === "create" ? `<div class="cc-bgs">${AV_BGS.map(c => `<button class="${onBg && c === draft.bg ? "on" : ""}" style="background:#${c}" data-bg="${c}" title="Background"></button>`).join("")}</div>` : ""}
    <div class="cc-seg"><button class="${draft.tab === "create" ? "on" : ""}" data-av-tab="create">${icon("sparkles")} Create with AI</button>
      <button class="${draft.tab === "build" ? "on" : ""}" data-av-tab="build">${icon("user")} Build your own</button></div>
    ${draft.tab === "build"
      ? `<div class="cc-tabs">${tabs.map(k => `<button class="${k === ccTab ? "on" : ""}" data-tab="${k}">${TABS[k]}</button>`).join("")}</div>
         <div class="cc-opts ${colors ? "colors" : ""}">${colors
          ? opts.map(c => `<button class="${c === l[ccTab] ? "on" : ""}" style="background:#${c}" data-set="${ccTab}" data-val="${c}" title="Color"></button>`).join("")
          : opts.map(v => `<button class="${v === l[ccTab] ? "on" : ""}" data-set="${ccTab}" data-val="${v}" title="${partName(v)}">
              <img src="${esc(characterSrc(ccTab === "gender" ? withGender(l, v) : { ...l, [ccTab]: v }, ZOOM[ccTab] || "full"))}" alt="${partName(v)}">${v === "none" || GENDERS[v] ? `<small>${partName(v)}</small>` : ""}</button>`).join("")}</div>`
      : aiReady === false ? `<p class="ai-off">AI avatars aren't turned on for this app yet. Build your own for now.</p>`
      : `<div class="ai-form">
          ${draft.made.length ? `<div class="ai-made"><small>Yours so far</small><div>${draft.made.map((src, i) => `<button class="${m === "ai" && draft.art === src ? "on" : ""}" style="background:#${draft.bg}" data-made="${i}"><img src="${esc(src)}" alt=""></button>`).join("")}</div></div>` : ""}
          ${m === "ai" && draft.art ? `<div class="ai-mode"><button class="${editing ? "on" : ""}" data-ai-mode="edit">${icon("pencil")} Change this one</button>
            <button class="${editing ? "" : "on"}" data-ai-mode="new">${icon("sparkles")} Start new</button></div>
            <p class="ai-note">${editing ? "Pick only what should change. Everything else stays the same." : "Draws a brand-new avatar from your picks."}</p>` : ""}
          ${editing ? "" : `<div class="ai-row"><small>Start from a selfie <em>(optional)</em></small><div class="ai-selfie">
            ${draft.selfie ? `<img src="${esc(draft.selfie)}" alt="Your selfie"><button data-no-selfie="1">Remove</button>`
                           : `<label class="cc-upload">${icon("camera")} Add a selfie<input type="file" accept="image/*" id="selfieFile" hidden></label>`}
            <span>${draft.selfie ? "The AI will make it look like you." : "Or just pick below."}</span></div></div>`}
          ${AI_PARTS.map(([key, label, opts]) => `<div class="ai-row"><small>${label}${key === "extras" ? " <em>(pick any)</em>" : ""}</small>
            <div class="ai-chips ${Array.isArray(opts) ? "" : "sws"}" data-row="${key}">${chips(key, opts)}</div></div>`).join("")}
          <div class="ai-row"><small>${editing ? "Anything else to change?" : "Anything else?"}</small>
            <input id="aiExtra" maxlength="100" placeholder="${editing ? "e.g. make the cap red, add a nose ring" : "e.g. pink streak, gap tooth, dimples"}" value="${esc(editing ? draft.changeText || "" : draft.extra)}"></div>
          <button class="wide dark ai-go" data-make="1" ${busy ? "disabled" : ""}>${busy ? "Drawing…"
            : editing ? `${icon("pencil")} Apply changes` : `${icon("sparkles")} ${draft.made.length ? "Make another" : "Create my avatar"}`}</button>
          ${draft.selfie ? `<p class="ai-note">Your selfie is only sent to the AI to draw your avatar. omw! doesn't keep it.</p>` : ""}
        </div>`}
    <div class="cc-save">
      <button class="wide" data-cancel="1">Cancel</button>
      <button class="wide dark" data-save="1" ${changed() && !(m === "ai" && !draft.art) ? "" : "disabled"}>Save</button>
    </div>`;
  const nb = document.querySelector("#avatarEditor .cc-opts, #avatarEditor .ai-form");
  if (nb && box && nb.className === box.className) nb.scrollTop = keep;
  if (document.querySelector("#avatarEditor .cc-tabs")) document.querySelector("#avatarEditor .cc-tabs").scrollLeft = keepTabs;
  // each row of choices stays where you scrolled it; opened fresh, it shows what's picked
  document.querySelectorAll("#avatarEditor [data-row]").forEach(r => {
    const on = r.querySelector(".on");
    r.scrollLeft = r.dataset.row in rows ? rows[r.dataset.row] : on ? Math.max(0, on.offsetLeft - r.offsetLeft - 40) : 0;
  });
}

async function makeAvatar() {
  const id = making = Date.now(), d = draft, editing = aiEditing();
  if (editing && !Object.values(d.changes).some(v => Array.isArray(v) ? v.length : v) && !d.changeText?.trim()) {
    making = 0; d.err = "Pick what should change first."; return renderAvatarEditor();
  }
  d.err = "";
  renderAvatarEditor();
  try {
    const res = await fetch("/ai/avatar", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(editing ? { traits: d.changes, extra: d.changeText || "", base: d.art }
                                   : { traits: d.traits, extra: d.extra, selfie: d.selfie || null }) });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Couldn't draw that. Try again.");
    const art = await shrinkArt(data.image);
    d.made = [art, ...d.made].slice(0, 6);
    if (editing) Object.assign(d, { changes: {}, changeText: "" });
    if (draft === d) Object.assign(d, { mode: "ai", art });
  } catch (e) {
    d.err = e.message;
  } finally {
    if (making === id) making = 0;
    if (draft === d && !$("avatarEditor").hidden) renderAvatarEditor();
  }
}

async function saveAvatar() {
  if (draft.mode === "old") { draft = null; $("avatarEditor").hidden = true; return; }
  const m = draft.mode;
  const avatar = m === "ai" ? { style: "ai", traits: draft.traits, extra: draft.extra, bg: draft.bg }
               : { style: "real", v: 2, look: cleanLook(draft.look) };
  // keep what you had underneath a photo, so switching back later still works
  if (m === "upload" || m === "photo") Object.assign(avatar, profile.avatar?.style === "ai" && myArt ? profile.avatar : {}, { useUpload: m === "upload", usePhoto: m === "photo" });
  else Object.assign(avatar, { useUpload: false, usePhoto: false });
  const upload = draft.upload || undefined, art = m === "ai" ? draft.art : myArt;
  const photo = await photoFor(avatar, me, upload, profile.photo, art);
  if (m === "ai" && art !== myArt) { myArt = art; await setDoc(doc(db, "private", me.uid), { avatarArt: art }, { merge: true }); }
  profile = { ...profile, avatar, photo, ...(upload ? { upload } : {}) };  // show it right away
  draft = null;
  $("avatarEditor").hidden = true;
  renderMe();
  await saveProfile({ avatar, photo, ...(upload ? { upload } : {}) });
}

const DAY_ORDER = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const ampm = hhmm => { const [h, m] = hhmm.split(":").map(Number); return `${(h + 11) % 12 + 1}${m ? ":" + String(m).padStart(2, "0") : ""}${h < 12 ? "am" : "pm"}`; };
function renderBusy(blocks) {
  const sorted = [...blocks].sort((a, b) => DAY_ORDER.indexOf(a.day) - DAY_ORDER.indexOf(b.day) || a.start.localeCompare(b.start));
  $("schedChips").innerHTML = sorted.length
    ? sorted.map(b => `<span class="busy-chip"><b>${esc(b.day)}</b> ${ampm(b.start)}–${ampm(b.end)} · ${esc(b.label)}</span>`).join("")
    : `<div class="note">No busy times saved yet, so the planner assumes you're always free.</div>`;
}

function updateBadge() {  // friend requests on your avatar, hangout invitations on the calendar button
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
        <button class="mini" data-decline="${esc(r.from)}" title="Decline">${icon("x")}</button></div>`).join("") +
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
          <small>${icon(MODE_ICON[f.travelMode || "driving"])} ${MODES[f.travelMode || "driving"]} · ${f.home ? "home set" : "no home yet"}</small></div>
          <button class="mini" data-remove="${esc(id)}" title="Remove friend">${icon("x")}</button></div>`;
      }).join("")
    : `<div class="nobody">No friends yet. Share your ID or add someone's above.</div>`;
}

// ---------- calendars ----------
const icsTime = iso => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const endOf = h => new Date(new Date(h.start).getTime() + (h.durationMin || 120) * 6e4).toISOString();
const whenText = h => new Date(h.start).toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

function googleLink(h) {  // one-tap "add this one event" link
  const q = new URLSearchParams({ action: "TEMPLATE", text: h.title, dates: `${icsTime(h.start)}/${icsTime(endOf(h))}`,
                                  location: [h.venueName, h.address].filter(Boolean).join(", "),
                                  details: `Planned in omw! with ${h.attendees.map(u => nameOf(h, u)).join(", ")}.` });
  return `https://calendar.google.com/calendar/render?${q}`;
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
function arrivedText(h, u) {
  const t = h.arrivals?.[u];
  if (!t) return "";
  const late = Math.round((new Date(t) - new Date(h.start)) / 6e4);
  return late < -1 ? `arrived ${-late} min early` : late <= 5 ? "arrived on time" : `arrived ${late} min late`;
}
function personLine(h, u, past) {  // "(car) Priya · leaves 6:40pm" (or how it went, once it's over)
  const status = arrivedText(h, u) || (past ? "no check-in" : h.alerts?.[u] ? `leaves ${timeOf(h.alerts[u])}` : "");
  return `<div><b>${h.modes?.[u] ? icon(MODE_ICON[h.modes[u]]) : ""} ${esc(nameOf(h, u))}</b><span>${esc(status)}</span></div>`;
}
// a row of round buttons with a label under each, like the action row on a Google Maps place
const act = (ic, label, attrs, cls = "", badge = 0) =>
  `<button class="act ${cls}" ${attrs}><span class="act-ic">${icon(ic)}${badge ? `<span class="unread">${badge}</span>` : ""}</span><span>${label}</span></button>`;
function planCard(h, { past = false, next = false } = {}) {
  const invited = h.invited || h.attendees, rsvp = h.rsvp || {};
  const waiting = invited.filter(u => !h.attendees.includes(u) && rsvp[u] !== "declined");
  const declined = invited.filter(u => rsvp[u] === "declined");
  const names = us => us.map(u => esc(nameOf(h, u))).join(", ");
  const mine = h.createdBy === me.uid;
  return `<div class="plan-card ${past ? "past" : ""} ${next ? "next" : ""}" data-show="${esc(h.id)}">
    <div class="plan-head"><div class="who"><b>${esc(h.title)}</b>
        <small>${esc(whenText(h))}${h.address ? ` · ${esc(h.address)}` : ""}</small>
        <small>Planned by ${mine ? "you" : esc(h.createdByName || "a friend")}</small></div>
      ${past ? "" : `<button class="mini" data-leave="${esc(h.id)}" title="I can't make it">${icon("x")}</button>`}</div>
    ${!past && leaveTime(h) ? `<div class="plan-you">${icon("bell")} You leave at ${leaveTime(h)}</div>` : ""}
    ${past ? "" : modeChips(h, myModeFor(h), "data-my-mode")}
    <div class="plan-people">${h.attendees.map(u => personLine(h, u, past)).join("")}</div>
    ${waiting.length || declined.length ? `<small class="note">${[waiting.length && `Waiting on ${names(waiting)}`,
                                                                   declined.length && `Can't make it: ${names(declined)}`].filter(Boolean).join(" · ")}</small>` : ""}
    ${past ? "" : sharingNow(h) ? `<small class="note">${icon("radio")} Sharing your location with the people going until you get there</small>`
      : `<small class="note">${icon("radio")} Your location is shared with the group from ${timeOf(new Date(shareStart(h)).toISOString())} (when you should leave) until you arrive</small>`}
    ${past ? "" : checkInHtml(h)}
    <div class="plan-actions">
      ${!past && h.venue ? act("route", "Directions", `data-dir="${esc(h.id)}"`, "primary") : ""}
      ${h.venue ? act(past ? "map" : "map-pinned", past ? "Map" : "Live map", `data-show="${esc(h.id)}"`) : ""}
      ${act("message-circle", "Chat", `data-chat="${esc(h.id)}"`, "", unreadCount(h.id))}
      ${past ? "" : act("calendar-plus", "Calendar", `data-cal="${esc(h.id)}" title="Add to Google Calendar"`)}
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
      ${leaveTime(h) ? `<small class="leave">${icon("bell")} leave ${leaveTime(h)}</small>` : ""}</button>`).join("");
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
      ${leaveTime(h) ? `<small>${icon("bell")} Your leave-now alert would be ${leaveTime(h)}</small>` : ""}
      <small>How are you getting there?</small>${modeChips(h, inviteMode[h.id] || myModeFor(h), "data-inv-mode")}
      <div class="rsvp"><button class="mini yes" data-going="${esc(h.id)}">${icon("check")} I'm in</button>
        <button class="mini" data-decline-invite="${esc(h.id)}">Can't make it</button></div>
    </div>`).join("");
  updateBadge();
}

// ---------- how you're getting there (you pick when accepting, and can change it later) ----------
const inviteMode = {};  // hangout id -> the way you picked on an invitation, before accepting
const myModeFor = h => h.modes?.[me.uid] || profile.travelMode || "driving";
const modeChips = (h, current, attr) => `<div class="modes">${Object.entries(MODES).map(([m, label]) =>
  `<button class="mode-chip ${m === current ? "on" : ""}" ${attr}="${esc(h.id)}" data-mode="${m}">${icon(MODE_ICON[m])} ${label}</button>`).join("")}</div>`;
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
// can't make it: only you come off the hangout; the others keep it and get told in the chat.
// If you were the last one going (and nobody's still deciding), there's nothing left, so it's removed.
async function cantMakeIt(h) {
  const others = h.attendees.filter(u => u !== me.uid);
  const deciding = (h.invited || []).filter(u => u !== me.uid && !h.attendees.includes(u) && !h.rsvp?.[u]);
  if (!others.length && !deciding.length) {  // only the planner may delete it (Firestore rules); anyone else just steps off
    if (!confirm("Cancel this hangout? Nobody else is going.")) return;
    return h.createdBy === me.uid ? deleteDoc(doc(db, "hangouts", h.id)) : rsvp(h.id, "declined");
  }
  if (!confirm(`Can't make it to ${h.title}? You'll be taken off it, and the others will get a message that you can't come.`)) return;
  await postLeft(h).catch(() => {});  // while you're still in the group, so you're allowed to post
  await rsvp(h.id, "declined");
}
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
}

// ---------- actions ----------
async function sendRequest() {
  const code = cleanId($("addInput").value);
  if (code.length !== 6) return say("Friend IDs are 6 characters, like K7P2QX.");
  if (code === profile.code) return say("That's your own ID!");
  const owner = await getDoc(doc(db, "codes", code));
  if (!owner.exists()) return say("No one has that ID. Double-check it with your friend.");
  const { uid, name } = owner.data();
  if (friendIds.includes(uid)) return say(`You're already friends with ${name}.`);
  if (outgoing.some(r => r.to === uid)) return say(`You already asked ${name}. Waiting for them to accept.`);
  if (incoming.some(r => r.from === uid)) return say(`${name} already sent you a request. Accept it below.`);
  await setDoc(doc(db, "requests", `${me.uid}_${uid}`), {
    from: me.uid, to: uid, fromName: profile.name, fromPhoto: profile.photo || "", toName: name, createdAt: serverTimestamp(),
  });
  $("addInput").value = "";
  say(`Request sent to ${name}. You'll be friends once they accept.`, true);
}

async function accept(from) {
  // the database only allows these two writes because a request from them to you exists
  const batch = writeBatch(db);
  batch.set(doc(db, "users", me.uid, "friends", from), { since: serverTimestamp() });
  batch.set(doc(db, "users", from, "friends", me.uid), { since: serverTimestamp() });
  batch.delete(doc(db, "requests", `${from}_${me.uid}`));
  await batch.commit();
  say("You're now friends!", true);
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
window.saveCategories = categories => saveProfile({ categories });  // the planner's "New" and delete buttons call this

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
  // trying things on only changes the draft; Save is what changes your picture
  $("avatarEditor").onclick = run(async e => {
    const b = e.target.closest("button");
    if (!b || b.disabled) return;
    if (b.dataset.tab) { ccTab = b.dataset.tab; document.querySelector(".cc-opts").scrollTop = 0; }
    if (b.dataset.set) draft = { ...draft, mode: "character", look: b.dataset.set === "gender" ? withGender(draft.look, b.dataset.val)
                                                                                     : { ...draft.look, [b.dataset.set]: b.dataset.val } };
    if (b.dataset.random) draft = { ...draft, mode: "character", look: randomLook() };
    if (b.dataset.bg) draft = { ...draft, bg: b.dataset.bg, mode: draft.art ? "ai" : draft.mode };
    if (b.dataset.avTab) draft.tab = b.dataset.avTab;
    if (b.dataset.trait) {
      const into = aiEditing() ? "changes" : "traits", k = b.dataset.trait, v = b.dataset.val, ex = draft[into].extras || [];
      draft[into] = { ...draft[into], [k]: k !== "extras" ? v : !v ? [] : ex.includes(v) ? ex.filter(x => x !== v) : [...ex, v] };
    }
    if (b.dataset.made) draft = { ...draft, mode: "ai", art: draft.made[+b.dataset.made] };
    if (b.dataset.noSelfie) draft.selfie = "";
    if (b.dataset.aiMode) draft.aiMode = b.dataset.aiMode;
    if (b.dataset.make) return makeAvatar();
    if (b.dataset.usePhoto) draft = { ...draft, mode: "photo" };
    if (b.dataset.useUpload) draft = { ...draft, mode: "upload" };
    if (b.dataset.cancel) { draft = null; $("avatarEditor").hidden = true; return; }
    if (b.dataset.save) { b.disabled = true; b.textContent = "Saving…"; return saveAvatar(); }
    renderAvatarEditor();
  });
  $("avatarEditor").addEventListener("change", async e => {  // picked a picture: try it on, Save keeps it
    if (e.target.id !== "photoFile" || !e.target.files[0]) return;
    try { draft = { ...draft, mode: "upload", upload: await shrinkPhoto(e.target.files[0]) }; renderAvatarEditor(); }
    catch (err) { $("photoMsg").textContent = err.message; }
  });
  $("avatarEditor").addEventListener("change", async e => {  // a selfie for the AI to go from
    if (e.target.id !== "selfieFile" || !e.target.files[0]) return;
    try { draft.selfie = await shrinkPhoto(e.target.files[0], 512); renderAvatarEditor(); }
    catch (err) { $("photoMsg").textContent = err.message; }
  });
  $("avatarEditor").addEventListener("input", e => { if (e.target.id === "aiExtra" && draft) draft[aiEditing() ? "changeText" : "extra"] = e.target.value; });
  $("readSched").onclick = async () => {
    const text = $("schedText").value.trim();
    $("readSched").disabled = true; $("readSched").textContent = "Reading…"; $("schedMsg").textContent = "";
    try {
      const res = await fetch("/parse-schedule", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || res.statusText);
      await saveProfile({ busy: data.blocks, scheduleText: text });
      const by = data.read_by ? ` (read by ${data.read_by})` : "";
      $("schedMsg").textContent = data.blocks.length ? `Saved ${data.blocks.length} busy times${by}. Friends' planners will work around them.` : `Saved: no busy times found${by}.`;
      $("schedMsg").className = "ok";
    } catch (e) {
      $("schedMsg").textContent = e.message; $("schedMsg").className = "";
    } finally {
      $("readSched").disabled = false; $("readSched").innerHTML = `${icon("sparkles")} Read my schedule`;
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
  // or type it: addresses as you type (Google Places, or Mapbox/OpenStreetMap if Google isn't set up)
  let homeTimer, homeFound = [], homeSession = null;
  $("homeInput").oninput = () => {
    clearTimeout(homeTimer);
    const q = $("homeInput").value.trim();
    if (q.length < 3) { $("homeSuggest").innerHTML = ""; return; }
    homeTimer = setTimeout(async () => {
      homeSession ||= crypto.randomUUID?.() || String(Math.random()).slice(2);
      const c = profile.home || (window.myFix && { lat: window.myFix.here[0], lng: window.myFix.here[1] }) || { lat: 39.8, lng: -98.6 };
      const list = await fetch(`/places/suggest?q=${encodeURIComponent(q)}&lat=${c.lat}&lng=${c.lng}&session=${homeSession}`).then(r => r.json()).catch(() => []);
      if ($("homeInput").value.trim() !== q) return;
      homeFound = list.filter(p => p.kind === "place");
      $("homeSuggest").innerHTML = homeFound.length
        ? homeFound.map((p, i) => `<div class="opt" data-home="${i}"><i>${icon("house")}</i><div><b>${esc(p.name)}</b><span>${esc(p.address)}</span></div></div>`).join("")
        : `<div class="none">No matches yet. Keep typing the street and city.</div>`;
    }, 250);
  };
  $("homeSuggest").onmousedown = e => e.preventDefault();  // keep the box focused while you pick
  $("homeSuggest").onclick = run(async e => {
    let p = homeFound[+e.target.closest("[data-home]")?.dataset.home];
    if (!p) return;
    if (p.lat == null) p = { ...p, ...(await fetch(`/places/details?id=${encodeURIComponent(p.id)}&session=${homeSession}`).then(r => r.json())) };
    homeSession = null;
    if (p.lat == null) throw new Error("Couldn't find that address. Try another.");
    await saveProfile({ home: { lat: p.lat, lng: p.lng }, homeName: p.name, homeAddress: p.address || "" });
    $("homeInput").value = ""; $("homeSuggest").innerHTML = ""; homeFound = [];
  });
  $("homeInput").onblur = () => setTimeout(() => ($("homeSuggest").innerHTML = ""), 200);
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
    if (b?.dataset.cal) return window.open(googleLink(hangoutDocs[b.dataset.cal]), "_blank", "noopener");
    if (b?.dataset.dir) { const h = hangoutDocs[b.dataset.dir]; $("plans").hidden = true;
      const d = new Date(h.start);
      return window.openDirections({ venue: h.venue, name: h.venueName || h.title, start: new Date(d - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16), mode: myModeFor(h) }); }
    if (b?.dataset.myMode && !b.classList.contains("on")) {
      // light up the new way right away; the leave time updates when the save comes back
      const row = b.parentElement, was = row.querySelector(".on");
      if (row.classList.contains("busy")) return;
      row.querySelectorAll(".mode-chip").forEach(x => x.classList.toggle("on", x === b));
      row.classList.add("busy");
      try { await changeMode(b.dataset.myMode, b.dataset.mode); }
      catch (err) { row.querySelectorAll(".mode-chip").forEach(x => x.classList.toggle("on", x === was)); throw err; }
      finally { row.classList.remove("busy"); }
    }
    if (b?.dataset.leave) await cantMakeIt(hangoutDocs[b.dataset.leave]);
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
    const photo = await photoFor(profile.avatar, user, profile.upload, profile.photo);  // your photo, upload or character
    if (profile.photo !== photo) await setDoc(ref, { photo }, { merge: true });
    profile = { ...profile, photo };
    await ensureId(user);
    await ensureCalToken(user);

    stop.push(onSnapshot(ref, s => { profile = s.data() || {}; renderMe(); publish(); }));
    // each friend's profile stays live, so their new check-ins show up on the leaderboard right away
    const friendStops = {};
    stop.push(() => Object.values(friendStops).forEach(f => f()));
    stop.push(onSnapshot(collection(db, "users", user.uid, "friends"), s => {
      friendIds = s.docs.map(d => d.id);
      for (const id of Object.keys(friendStops)) if (!friendIds.includes(id)) { friendStops[id](); delete friendStops[id]; delete friends[id]; }
      for (const id of friendIds) {
        if (friendStops[id]) continue;
        friendStops[id] = onSnapshot(doc(db, "users", id), p => {
          if (p.exists()) friends[id] = p.data();
          renderFriends(); publish();
        }, () => {});
      }
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
        // older hangouts started their title with an emoji ("🍔 Food at ..."): show it without
        s.docs.forEach(d => { const h = { ...d.data(), id: d.id };
          h.title = String(h.title || "Hangout").replace(/^(\p{Extended_Pictographic}|\uFE0F|\u200D|\s)+/u, "");
          hangoutDocs[d.id] = h; });
        for (const id in hangoutDocs) {  // cancelled: gone from both lists
          if (!seenBy.attendees.has(id) && !seenBy.invited.has(id)) delete hangoutDocs[id];
        }
        sortHangouts();
      }));
    }
  }));
}
