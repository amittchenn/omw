// omw characters: your own flat-style person, stacked from the hand-drawn layers in web/avatar/
// (long hair behind the head, then skin, short hair on top of it, shirt, eyes and mouth, all on the same 512 px frame).
// A look is a small list of choices, e.g. { skin: "d5c7a7", hair: "sLong", hairColor: "7a4900", eyes: "rLash", mouth: "smile", ... }.
// characterSrc(look) gives a picture for the editor; renderJpeg() turns it into the small JPEG friends see.

export const SKINS = ["fff6e2", "f7e9c9", "d5c7a7", "9f9272", "5f5438"];
export const HAIR_COLORS = ["000000", "3d2500", "7a4900", "cc4e00", "ffeb99"];
export const TOP_COLORS = ["38b6ff", "004aad", "7ed957", "ffde59", "ffbd59", "ff5757", "ffc2c2", "e2a9f1"];
export const BGS = ["ffd000", "ffb3c7", "b9a8ff", "8fe3c0", "9fd4ff", "ffc49c", "f1f0f7", "2b2b3a"];
export const PARTS = {
  gender: ["woman", "man"],
  hair: ["sShort", "sLong", "wLong", "braid", "crew", "sidePart", "quiff", "curly", "buzz"],
  eyes: ["rLash", "r", "v"],
  mouth: ["smile", "grin", "open", "tongue", "smirk", "neutral"],
  top: ["roundneck", "vneck", "buttoned"],
};
export const LABELS = { crew: "Crew cut", sidePart: "Side part", quiff: "Quiff", curly: "Curly", buzz: "Buzz cut", sShort: "Bob", sLong: "Long", wLong: "Wavy", braid: "Braids", rLash: "Lashes", r: "Round", v: "Happy",
                        smile: "Smile", grin: "Grin", open: "Surprised", tongue: "Tongue out", smirk: "Smirk", neutral: "Straight face",
                        roundneck: "Round neck", vneck: "V-neck", buttoned: "Buttoned" };
export const COLOR_PARTS = { skin: SKINS, hairColor: HAIR_COLORS, topColor: TOP_COLORS, bg: BGS };
export const ADJUST = {};  // no sliders for this style
// Woman and Man each get their own hairstyles (long ones behind the head, short ones on top of it); everything else is shared
const FRONT = new Set(["crew", "sidePart", "quiff", "curly", "buzz"]);
export const OPTIONS = { woman: { hair: PARTS.hair.filter(h => !FRONT.has(h)) }, man: { hair: PARTS.hair.filter(h => FRONT.has(h)) } };
export const optionsFor = (look, part) => OPTIONS[look?.gender]?.[part] || PARTS[part] || [];
// switching Woman <-> Man: each hairstyle trades for its look-alike on the other side
const HAIR_SWAP = { sShort: "crew", sLong: "sidePart", wLong: "curly", braid: "quiff", crew: "sShort", sidePart: "sLong", quiff: "braid", curly: "wLong", buzz: "sShort" };
export const withGender = (look, gender) => { const l = cleanLook(look);
  return cleanLook({ ...l, gender, hair: optionsFor({ gender }, "hair").includes(l.hair) ? l.hair : HAIR_SWAP[l.hair] }); };

// ---------- looks saved with the old drawn characters turn into the closest match here ----------
const rgb = h => [0, 8, 16].map(s => (parseInt(h, 16) >> (16 - s)) & 255);
const nearest = (hex, list) => /^[0-9a-f]{6}$/i.test(hex || "")
  ? list.reduce((best, c) => { const d = rgb(c).reduce((s, v, i) => s + (v - rgb(hex)[i]) ** 2, 0); return d < best[1] ? [c, d] : best; }, [list[0], Infinity])[0]
  : null;
const OLD_HAIR = { long: "sLong", ponytail: "sLong", hijab: "sLong", wavy: "wLong", afro: "curly", locs: "curly", pigtails: "braid", bun: "braid",
                   bob: "sShort", spiky: "quiff", bald: "buzz" };
const OLD_EYES = { lashes: "rLash", happy: "v", wink: "v" };
const OLD_TOP = { collar: "buttoned", jacket: "buttoned" };

// only known choices make it into the picture (a profile could hold anything)
export function cleanLook(l = {}) {
  const pick = (k, list, old) => list.includes(l[k]) ? l[k] : old?.[l[k]] || (k === "hair" && l[k] ? "sShort" : list[0]);
  const hair = pick("hair", PARTS.hair, OLD_HAIR);
  // Man / Woman: kept if saved, otherwise read from the hairstyle; the hairstyle always fits it
  const gender = PARTS.gender.includes(l.gender) ? l.gender : FRONT.has(hair) ? "man" : "woman";
  return {
    gender,
    hair: optionsFor({ gender }, "hair").includes(hair) ? hair : HAIR_SWAP[hair],
    skin: SKINS.includes(l.skin) ? l.skin : nearest(l.skin, SKINS) || SKINS[2],
    hairColor: HAIR_COLORS.includes(l.hairColor) ? l.hairColor : nearest(l.hairColor, HAIR_COLORS) || HAIR_COLORS[1],
    eyes: pick("eyes", PARTS.eyes, OLD_EYES),
    mouth: pick("mouth", PARTS.mouth),
    top: pick("top", PARTS.top, OLD_TOP),
    topColor: TOP_COLORS.includes(l.topColor) ? l.topColor : nearest(l.topColor, TOP_COLORS) || TOP_COLORS[0],
    bg: BGS.includes(l.bg) ? l.bg : BGS[0],
  };
}

const hash = s => {
  let h = 2166136261;
  for (const ch of String(s)) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
  h = Math.imul(h ^ (h >>> 16), 2246822507); h = Math.imul(h ^ (h >>> 13), 3266489909);  // mix the bits so similar seeds differ
  return (h ^ (h >>> 16)) >>> 0;
};
export function randomLook(seed = Math.random().toString(36)) {
  const one = (k, list) => list[hash(seed + k) % list.length], gender = one("g", PARTS.gender);
  return cleanLook({ gender, skin: one("s", SKINS), hair: one("h", optionsFor({ gender }, "hair")), hairColor: one("hc", HAIR_COLORS), eyes: one("e", PARTS.eyes),
                     mouth: one("m", ["smile", "grin", "smile", "tongue", "open", "smirk"]), top: one("t", PARTS.top),
                     topColor: one("tc", TOP_COLORS), bg: one("bg", BGS.slice(0, 6)) });
}

// ---------- the layers ----------
const layersOf = l => { const hair = `hair/${l.hair}/${l.hairColor}`;
  return [...(FRONT.has(l.hair) ? [] : [hair]), `skin/${l.skin}`, ...(FRONT.has(l.hair) ? [hair] : []), `shirt/${l.top}/${l.topColor}`, `eyes/${l.eyes}`, `mouth/${l.mouth}`]; };
const imgs = new Map();  // layer -> Promise<Image>
function layer(path) {
  if (!imgs.has(path)) imgs.set(path, new Promise((ok, no) => {
    const img = new Image();
    img.onload = () => { img.ready = true; ok(img); };
    img.onerror = () => { imgs.delete(path); no(new Error("Couldn't draw your character.")); };
    img.src = new URL(`./avatar/${path}.png`, import.meta.url).href;
    layer.el[path] = img;
  }));
  return imgs.get(path);
}
layer.el = {};

// what part of the picture each view shows: [left, top, size] as parts of the frame
const VIEWS = { full: [0, 0, 1], head: [.13, .02, .74], face: [.26, .2, .48] };
function draw(l, view, px, bg = true) {
  const c = document.createElement("canvas"), [x, y, s] = VIEWS[view] || VIEWS.full;
  c.width = c.height = px;
  const g = c.getContext("2d");
  if (bg) { g.fillStyle = "#" + l.bg; g.fillRect(0, 0, px, px); }
  g.imageSmoothingQuality = "high";
  for (const p of layersOf(l)) g.drawImage(layer.el[p], x * 512, y * 512, s * 512, s * 512, 0, 0, px, px);
  return c;
}

// a picture for the editor, right away. Layers not loaded yet? A plain placeholder for now, and
// "characters-ready" fires once they are, so the editor can draw again.
const cache = new Map();
let waiting = null;
export function characterSrc(look, view = "full") {
  const l = cleanLook(look), key = JSON.stringify(l) + view;
  if (cache.has(key)) return cache.get(key);
  const paths = layersOf(l), missing = paths.filter(p => !layer.el[p]?.ready);
  if (missing.length) {
    const all = Promise.all(paths.map(layer));
    waiting = waiting ? Promise.all([waiting, all]) : all;
    const now = waiting;
    now.then(() => { if (waiting === now) { waiting = null; window.dispatchEvent(new Event("characters-ready")); } }, () => { waiting = null; });
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#${l.bg}"/></svg>`)}`;
  }
  const src = draw(l, view, view === "full" ? 384 : 192).toDataURL("image/png");
  if (cache.size > 300) cache.clear();
  cache.set(key, src);
  return src;
}

// the picture friends see: a 256 px JPEG (small, and works everywhere a photo does)
export async function renderJpeg(look) {
  const l = cleanLook(look);
  await Promise.all(layersOf(l).map(layer));
  return draw(l, "full", 256).toDataURL("image/jpeg", 0.9);
}
