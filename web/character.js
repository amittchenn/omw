// omw characters: soft, glossy 3D-style people (think Memoji or Bitmoji), drawn right here in the browser.
// A look is a small list of choices, e.g. { gender: "woman", skin: "e0ac85", hair: "pigtails", hat: "bow", glasses: "tinted", eyeSize: 2, ... }.
// drawCharacter(look) returns an SVG picture; renderJpeg() turns it into a small JPEG to use as your profile picture.
// Every face shape shares the same top of the head, so every hairstyle and hat fits every face,
// and the Adjust sliders move the features (glasses and brows follow the eyes; hair and hats follow the face width).

export const SKINS = ["fde0cf", "f5cdb3", "eab897", "e0ac85", "c98d62", "a86b43", "8a5230", "5e3720"];
export const HAIR_COLORS = ["16100c", "3b2417", "5c3a22", "8a5a33", "b07a45", "f2c94c", "efd9a0", "e0612f", "a33b1d", "c9c4bf",
                            "ff8fc6", "9b6bff", "3f7bff", "2fbf71"];
export const EYE_COLORS = ["3a2112", "6b4423", "8a6a3a", "4d7a3a", "3f6f9a", "7da2c8", "6d7278"];
export const HAT_COLORS = ["1d1f27", "e8453c", "ff8a1f", "ffd23f", "3fbf6b", "2f80ed", "8e5cf7", "ff7eb6", "8b5a2b", "f4f1ea"];
export const TOP_COLORS = ["f4f1ea", "1d1f27", "8a8f9c", "e8453c", "ff8a1f", "ffd23f", "3fbf6b", "2f80ed", "1f3a68", "8e5cf7", "ff7eb6", "8b5a2b"];
export const BGS = ["ffd000", "ffb3c7", "b9a8ff", "8fe3c0", "9fd4ff", "ffc49c", "f1f0f7", "2b2b3a"];
export const PARTS = {
  gender: ["man", "woman"],
  face: ["round", "oval", "square", "heart"],
  hair: ["crew", "sidePart", "quiff", "buzz", "spiky", "curly", "afro", "long", "wavy", "bob", "bun", "ponytail", "pigtails", "locs", "hijab", "bald"],
  hat: ["none", "cap", "backwards", "beanie", "catBeanie", "beret", "bucket", "cowboy", "headband", "headphones", "bow", "bunny", "crown"],
  eyes: ["round", "almond", "lashes", "hooded", "narrow", "happy", "wink"],
  brows: ["natural", "arched", "straight", "thick", "thin"],
  nose: ["soft", "button", "wide", "long"],
  mouth: ["smile", "grin", "tongue", "open", "smirk", "neutral"],
  beard: ["none", "stubble", "mustache", "goatee", "full"],
  glasses: ["none", "round", "square", "tinted", "sunglasses", "stars"],
  top: ["tee", "hoodie", "collar", "turtleneck", "jacket"],
};
export const COLOR_PARTS = { skin: SKINS, hairColor: HAIR_COLORS, eyeColor: EYE_COLORS, hatColor: HAT_COLORS, topColor: TOP_COLORS, bg: BGS };
// the Adjust sliders: each goes from -5 to 5 (0 = the usual)
export const ADJUST = {
  faceWidth: ["Face width"], eyeSize: ["Eye size"], eyeSpacing: ["Eye spacing"], eyeHeight: ["Eye height"],
  browHeight: ["Brow height"], noseSize: ["Nose size"], mouthSize: ["Mouth size"], mouthHeight: ["Mouth height"],
};

// Man and Woman each get their own set of choices: their own hairstyles, eyes and brows, and beards only for Man.
// Anything not listed here (face, nose, mouth, hats, glasses, outfits, colors) is the same for both.
export const OPTIONS = {
  man: { hair: ["crew", "sidePart", "quiff", "buzz", "spiky", "curly", "afro", "locs", "bald"],
         eyes: ["round", "almond", "hooded", "narrow", "happy", "wink"],
         brows: ["natural", "straight", "thick"],
         beard: ["none", "stubble", "mustache", "goatee", "full"] },
  woman: { hair: ["long", "wavy", "bob", "bun", "ponytail", "pigtails", "curly", "afro", "locs", "hijab"],
           eyes: ["lashes", "round", "almond", "hooded", "happy", "wink"],
           brows: ["arched", "natural", "thin", "straight"],
           beard: ["none"] },
};
export const optionsFor = (look, part) => OPTIONS[look.gender]?.[part] || PARTS[part];
// switching Man <-> Woman: each hairstyle trades for its look-alike on the other side, and anything not in the new set resets
const HAIR_SWAP = { crew: "long", sidePart: "wavy", quiff: "bob", buzz: "bun", spiky: "ponytail", bald: "long",
                    long: "crew", wavy: "sidePart", bob: "quiff", bun: "buzz", ponytail: "spiky", pigtails: "crew", hijab: "crew" };
function fitGender(l) {
  for (const part of ["hair", "eyes", "brows", "beard"]) {
    const opts = optionsFor(l, part);
    if (!opts.includes(l[part])) l[part] = part === "hair" && opts.includes(HAIR_SWAP[l.hair]) ? HAIR_SWAP[l.hair] : opts[0];
  }
  return l;
}
export const withGender = (look, gender) => fitGender({ ...look, gender });

// only known choices make it into the drawing (a profile could hold anything)
export function cleanLook(l = {}) {
  const old = { ...l };
  // looks saved before hats existed: the beanie was a hairstyle, and its color was the outfit color
  if (old.hair === "beanie") { old.hat = old.hat || "beanie"; old.hair = old.gender === "woman" ? "long" : "crew"; }
  if (!old.hatColor && HAT_COLORS.includes(old.outfitColor)) old.hatColor = old.outfitColor;
  if (old.mouth === undefined && old.expression) old.mouth = old.expression;
  const out = {};
  for (const [k, opts] of Object.entries({ ...PARTS, ...COLOR_PARTS })) out[k] = opts.includes(old[k]) ? old[k] : opts[0];
  if (!SKINS.includes(old.skin)) out.skin = SKINS[3];
  if (!HAIR_COLORS.includes(old.hairColor)) out.hairColor = HAIR_COLORS[1];
  if (!HAT_COLORS.includes(old.hatColor)) out.hatColor = HAT_COLORS[5];
  if (!TOP_COLORS.includes(old.topColor)) out.topColor = TOP_COLORS[7];
  for (const k of Object.keys(ADJUST)) out[k] = Number.isInteger(old[k]) ? Math.max(-5, Math.min(5, old[k])) : 0;
  if (old.gender === "nonbinary") out.gender = old.gender;  // no longer offered, but avatars saved with it keep looking the same
  return fitGender(out);
}

const hash = s => {
  let h = 2166136261;
  for (const ch of String(s)) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
  h = Math.imul(h ^ (h >>> 16), 2246822507); h = Math.imul(h ^ (h >>> 13), 3266489909);  // mix the bits so similar seeds differ
  return (h ^ (h >>> 16)) >>> 0;
};
export function randomLook(seed = Math.random().toString(36)) {
  const one = (k, list) => list[hash(seed + k) % list.length], roll = k => hash(seed + k) % 100;
  const gender = one("g0", PARTS.gender);
  const pick = (k, part) => one(k, optionsFor({ gender }, part));
  return cleanLook({ gender, skin: one("s", SKINS), face: one("f", PARTS.face), hair: pick("h", "hair"),
    hairColor: one("hc", roll("hx") < 75 ? HAIR_COLORS.slice(0, 7) : HAIR_COLORS), eyes: pick("e", "eyes"), eyeColor: one("ec", EYE_COLORS),
    brows: pick("b", "brows"), nose: one("n", PARTS.nose), mouth: one("m", ["smile", "grin", "smile", "tongue", "open", "smirk"]),
    beard: gender === "man" && roll("bd") < 30 ? one("bd2", PARTS.beard.slice(1)) : "none",
    hat: roll("ht") < 35 ? one("h2", PARTS.hat.slice(1)) : "none", hatColor: one("hk", HAT_COLORS),
    glasses: roll("g") < 35 ? one("g2", PARTS.glasses.slice(1)) : "none", top: one("t", PARTS.top), topColor: one("tc", TOP_COLORS),
    bg: one("bg", BGS.slice(0, 6)) });
}

// ---------- colors ----------
function shade(hex, amt) {  // amt > 0 lighter, < 0 darker
  const n = parseInt(String(hex).replace("#", ""), 16), mix = (c, t) => Math.round(c + (t - c) * Math.abs(amt));
  const t = amt > 0 ? 255 : 0;
  return "#" + [n >> 16, (n >> 8) & 255, n & 255].map(c => mix(c, t).toString(16).padStart(2, "0")).join("");
}
function blend(a, b, w) {
  const x = parseInt(a, 16), y = parseInt(b, 16);
  return "#" + [16, 8, 0].map(s => Math.round(((x >> s) & 255) * (1 - w) + ((y >> s) & 255) * w).toString(16).padStart(2, "0")).join("");
}
const isLight = hex => { const n = parseInt(hex, 16); return (0.3 * (n >> 16) + 0.59 * ((n >> 8) & 255) + 0.11 * (n & 255)) > 170; };
// a soft glossy highlight streak, the thing that makes a shape look like smooth vinyl
const gloss = (d, o = 0.45, w = 5) => `<path d="${d}" fill="none" stroke="#fff" stroke-opacity="${o}" stroke-width="${w}" stroke-linecap="round" filter="url(#soft)"/>`;
// a shape that's thick in the middle and thin at the ends (brows, lash lines), along a curve from a through b1, b2 to c
function taper([ax, ay], [b1x, b1y], [b2x, b2y], [cx, cy], w0, w1, w2) {
  const pt = t => { const u = 1 - t; return [u * u * u * ax + 3 * u * u * t * b1x + 3 * u * t * t * b2x + t * t * t * cx,
                                              u * u * u * ay + 3 * u * u * t * b1y + 3 * u * t * t * b2y + t * t * t * cy]; };
  const N = 14, top = [], bot = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N, [x, y] = pt(t), [x2, y2] = pt(Math.min(1, t + 0.01)), [x1, y1] = pt(Math.max(0, t - 0.01));
    const dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1, nx = -dy / len, ny = dx / len;
    const w = (t < 0.5 ? w0 + (w1 - w0) * t * 2 : w1 + (w2 - w1) * (t - 0.5) * 2) / 2;
    top.push(`${(x + nx * w).toFixed(2)},${(y + ny * w).toFixed(2)}`); bot.unshift(`${(x - nx * w).toFixed(2)},${(y - ny * w).toFixed(2)}`);
  }
  return `M${top.join(" L")} L${bot.join(" L")}Z`;
}

// ---------- the head (200 x 200 drawing; the head is centered at 100,108) ----------
// every face shape has the same top half, so hair and hats sit the same on all of them; only the cheeks and chin differ
const FACE_TOP = "M48,108 C48,76 69,54 100,54 C131,54 152,76 152,108";
const FACES = {
  round: [" C152,141 129,162 100,162 C71,162 48,141 48,108Z", 162],
  oval: [" C151,146 128,168 100,168 C72,168 49,146 48,108Z", 168],
  square: [" C152,137 147,157 124,162 C114,164.5 86,164.5 76,162 C53,157 48,137 48,108Z", 164],
  heart: [" C152,133 128,158 100,168 C72,158 48,133 48,108Z", 168],
};
const facePath = l => FACE_TOP + FACES[l.face][0];

// where the features sit, after the Adjust sliders
function layout(l) {
  const ex = 20 + l.eyeSpacing * 1.3, ey = 111 + l.eyeHeight * 1.3;
  return { fw: 1 + l.faceWidth * 0.018, ex: [100 - ex, 100 + ex], ey, es: 1.12 + l.eyeSize * 0.045,
           by: ey - 17 + l.browHeight * 1.2, ns: 1 + l.noseSize * 0.06, ny: 125 + l.eyeHeight * 0.4,
           ms: 1 + l.mouthSize * 0.05, my: 139 + l.mouthHeight * 1.3 };
}

function eye(x, flip, l, L, closed) {
  const s = flip ? -1 : 1, lid = "#1f130e", es = L.es;
  const lash = l.eyes === "lashes" || (l.gender === "woman" && l.eyes !== "narrow");
  const g = inner => `<g transform="translate(${x},${L.ey}) scale(${s * es},${es})">${inner}</g>`;
  const socket = `<ellipse cy="-3" rx="14" ry="12" fill="${shade(l.skin, -0.25)}" opacity=".16" filter="url(#soft)"/>`;
  if (closed || l.eyes === "happy")  // happy ^ ^
    return g(`${socket}<path d="${taper([-10, 3], [-6, -6], [6, -6], [10, 3], 1.6, 3.8, 1.6)}" fill="${lid}"/>
      ${lash ? `<path d="${taper([8.6, 0.5], [10.5, -1.5], [12, -3], [13.5, -5], 2.2, 1.6, 0.6)}" fill="${lid}"/>` : ""}`);
  const ry = { round: 10, almond: 8.2, lashes: 9.6, hooded: 9, narrow: 5.6, wink: 10 }[l.eyes] || 10;
  const shape = l.eyes === "almond" ? `M-10.5,1 C-7,-${ry + 1.5} 7,-${ry + 1.5} 10.5,-1.5 C7,${ry - 0.5} -7,${ry} -10.5,1Z`
                                    : `M-10,0 A10,${ry} 0 1 0 10,0 A10,${ry} 0 1 0 -10,0Z`;
  const cid = `ec${Math.round(x)}${flip ? "r" : "l"}`;
  const topLid = l.eyes === "almond" ? [[-10.8, 1.2], [-7, -ry - 2.4], [7, -ry - 2.4], [11, -1.4]] : [[-10.6, 0.5], [-8, -ry - 3.1], [8, -ry - 3.1], [10.8, -0.5]];
  const hood = l.eyes === "hooded" ? `<path d="M-12,-1 C-7,-${ry + 4} 7,-${ry + 4} 12,-1 C8,-${ry - 2.5} -8,-${ry - 2.5} -12,-1Z" fill="url(#skinG)"/>` : "";
  return g(`${socket}
    <clipPath id="${cid}"><path d="${shape}"/></clipPath>
    <path d="${shape}" fill="url(#sclera)"/>
    <g clip-path="url(#${cid})">
      <circle cx=".4" cy="1" r="7.4" fill="url(#iris)"/><circle cx=".4" cy="1" r="7.4" fill="none" stroke="${shade(l.eyeColor, -0.45)}" stroke-width="1.1" opacity=".8"/>
      <circle cx=".4" cy="1" r="3.7" fill="#0b0705"/>
      <ellipse cx="0" cy="-${ry}" rx="12" ry="5" fill="#3a2a30" opacity=".22" filter="url(#soft)"/>
      <circle cx="-2.6" cy="-2.7" r="2.5" fill="#fff"/><circle cx="3.2" cy="3.6" r="1.1" fill="#fff" opacity=".85"/>
    </g>
    <path d="${taper(...topLid, 1.2, lash ? 3.4 : 2.6, lash ? 2.4 : 1.2)}" fill="${lid}"/>
    ${lash ? `<path d="${taper([8.8, -2.6], [11, -4], [12.6, -5.2], [14.6, -7.4], 2.6, 1.8, 0.4)}" fill="${lid}"/>` : ""}
    <path d="M-7.5,${ry * 0.82} C-3,${ry + 1.8} 3,${ry + 1.8} 7.5,${ry * 0.82}" fill="none" stroke="${shade(l.skin, -0.35)}" stroke-width="1.2" stroke-linecap="round" opacity=".45"/>
    ${hood}${l.eyes === "narrow" ? `<path d="M-11,-3 C-5,-7.5 5,-7.5 11,-3 C6,-5.4 -6,-5.4 -11,-3Z" fill="${lid}" opacity=".85"/>` : ""}`);
}

const BROWS = {  // one brow from its inner end (by the nose, thick) to its tail (thin): [inner, control, control, tail, widths]
  natural: [[-11, 0.5], [-5, -4.5], [5, -5], [11, 0.5], [3.8, 3.4, 1.3]],
  arched: [[-11, 1], [-5, -5.5], [4, -7], [11, 1], [3.2, 3, 1.1]],
  straight: [[-11, -0.5], [-4, -2], [4, -2.2], [11, -0.5], [4, 3.6, 1.8]],
  thick: [[-11, 0.5], [-5, -5], [5, -5.5], [11, 0.5], [6.2, 5.4, 2.4]],
  thin: [[-11, 0.5], [-5, -4], [5, -4.5], [11, 0.5], [2.4, 2, 0.8]],
};
function brows(l, L) {
  const [a, b1, b2, c, [w0, w1, w2]] = BROWS[l.brows];
  const col = shade(l.hairColor, ["f4f1ea", "c9c4bf", "efd9a0", "f2c94c", "ff8fc6"].includes(l.hairColor) ? -0.4 : -0.08);
  const lift = l.mouth === "open" ? -3 : 0;  // surprised: brows up
  const d = taper(a, b1, b2, c, w0, w1, w2), k = L.es * 0.5 + 0.5;
  // drawn with the inner end toward the middle of the face on both sides
  return `<g fill="${col}"><path transform="translate(${L.ex[0]},${L.by + lift}) scale(-${k},1)" d="${d}"/>
    <path transform="translate(${L.ex[1]},${L.by + lift}) scale(${k},1)" d="${d}"/></g>`;
}

function nose(l, L) {
  const [rx, ry, bridge] = { soft: [6.5, 5, 0], button: [5, 4.2, 0], wide: [8.5, 5.4, 0], long: [5.5, 6, 1] }[l.nose];
  const dark = shade(l.skin, -0.3);
  return `<g transform="translate(100,${L.ny}) scale(${L.ns})">
    ${bridge ? `<path d="M3,-18 C4,-12 5,-6 5.5,-2" fill="none" stroke="${dark}" stroke-width="2.4" stroke-linecap="round" opacity=".22" filter="url(#soft)"/>` : ""}
    <ellipse cx="1.5" cy="${ry * 0.6}" rx="${rx + 1.5}" ry="${ry * 0.7}" fill="${dark}" opacity=".22" filter="url(#soft)"/>
    <ellipse rx="${rx}" ry="${ry}" fill="url(#noseG)"/>
    <ellipse cx="-${rx * 0.45}" cy="${ry * 0.55}" rx="${rx * 0.26}" ry="${ry * 0.2}" fill="${shade(l.skin, -0.5)}" opacity=".45"/>
    <ellipse cx="${rx * 0.45}" cy="${ry * 0.55}" rx="${rx * 0.26}" ry="${ry * 0.2}" fill="${shade(l.skin, -0.5)}" opacity=".45"/>
    <ellipse cx="-${rx * 0.3}" cy="-${ry * 0.38}" rx="${rx * 0.34}" ry="${ry * 0.26}" fill="#fff" opacity=".6"/>
  </g>`;
}

function mouth(l, L) {
  const dark = "#58202a", tongue = "url(#tongueG)", teeth = "#fffdf8";
  const lip = l.gender === "woman" ? blend(l.skin, "c9405a", 0.55) : blend(l.skin, "a8505a", 0.35);
  const inner = (() => { switch (l.mouth) {
    case "grin": return `<path d="M-17,-3 C-12,15 12,15 17,-3 C7,0 -7,0 -17,-3Z" fill="${dark}"/>
      <clipPath id="grinC"><path d="M-17,-3 C-12,15 12,15 17,-3 C7,0 -7,0 -17,-3Z"/></clipPath>
      <g clip-path="url(#grinC)"><path d="M-16,-3 C-7,0 7,0 16,-3 L16,2.5 C7,4.5 -7,4.5 -16,2.5Z" fill="${teeth}"/>
        <ellipse cy="12" rx="9" ry="5.5" fill="${tongue}"/></g>
      <path d="M-17,-3 C-12,15 12,15 17,-3" fill="none" stroke="${lip}" stroke-width="2" stroke-linecap="round"/>
      <path d="M-19,-4.5 C-18.5,-2.5 -17.5,-1.5 -16.5,-1 M19,-4.5 C18.5,-2.5 17.5,-1.5 16.5,-1" fill="none" stroke="${shade(l.skin, -0.3)}" stroke-width="1.4" stroke-linecap="round" opacity=".6"/>`;
    case "tongue": return `<path d="M-14,-2 C-9,8 9,8 14,-2 C5,1 -5,1 -14,-2Z" fill="${dark}"/>
      <path d="M-7,1.5 C-7,14 7,14 7,1.5 C4,3.5 -4,3.5 -7,1.5Z" fill="${tongue}"/>
      <path d="M0,3 L0,9" stroke="#c9505e" stroke-width="1.2" stroke-linecap="round"/>
      <ellipse cx="-3" cy="6" rx="2" ry="1.4" fill="#fff" opacity=".45"/>
      <path d="M-14,-2 C-5,1 5,1 14,-2" fill="none" stroke="${lip}" stroke-width="2.6" stroke-linecap="round"/>`;
    case "open": return `<ellipse cy="3" rx="7.5" ry="8.5" fill="${dark}"/><ellipse cy="8" rx="5" ry="3" fill="${tongue}"/>
      <ellipse cy="3" rx="7.5" ry="8.5" fill="none" stroke="${lip}" stroke-width="2"/>`;
    case "smirk": return `<path d="${taper([-12, 1.5], [-4, 3.5], [6, 2], [14, -5], 2.2, 3.4, 2)}" fill="${dark}"/>
      <path d="M13,-6.5 C15,-5.5 16,-3.5 15.5,-1.5" fill="none" stroke="${shade(l.skin, -0.3)}" stroke-width="1.5" stroke-linecap="round" opacity=".7"/>`;
    case "neutral": return `<path d="${taper([-9, 0.5], [-4, 1.2], [4, 1.2], [9, 0.5], 2, 3, 2)}" fill="${dark}"/>
      <path d="M-6,5 C-2,6.5 2,6.5 6,5" fill="none" stroke="${lip}" stroke-width="2.4" stroke-linecap="round" opacity=".6"/>`;
    default: return `<path d="${taper([-13, -4], [-7, 7], [7, 7], [13, -4], 2, 3.6, 2)}" fill="${dark}"/>
      <path d="M-7,6.5 C-3,9.5 3,9.5 7,6.5" fill="none" stroke="${lip}" stroke-width="2.4" stroke-linecap="round" opacity=".7"/>
      <path d="M-14.5,-5.5 C-14,-3.5 -13,-2.5 -12,-2 M14.5,-5.5 C14,-3.5 13,-2.5 12,-2" fill="none" stroke="${shade(l.skin, -0.3)}" stroke-width="1.3" stroke-linecap="round" opacity=".55"/>`;
  } })();
  return `<g transform="translate(100,${L.my}) scale(${L.ms})">${inner}</g>`;
}

// beards follow the actual jaw: they're the face shape itself, cut off above the mouth
function beard(l, L) {
  if (l.beard === "none") return "";
  const c = l.hairColor, dark = shade(c, -0.15), my = L.my;
  const stache = `<g transform="translate(100,${my - 5}) scale(${L.ms})"><path d="M-16,3 C-11,-5 -3,-4 0,-1 C3,-4 11,-5 16,3 C10,1 5,1.5 0,3 C-5,1.5 -10,1 -16,3Z" fill="${dark}"/></g>`;
  const chinY = FACES[l.face][1];
  switch (l.beard) {
    case "stubble": return `<g clip-path="url(#faceClip)"><g filter="url(#stubble)"><g clip-path="url(#jawClip)"><path d="${facePath(l)}" fill="${shade(c, -0.1)}" opacity=".32"/></g></g></g>`;
    case "mustache": return stache;
    case "goatee": return stache + `<path d="M88,${chinY - 14} C92,${chinY - 17} 108,${chinY - 17} 112,${chinY - 14} C112,${chinY - 4} 106,${chinY + 1} 100,${chinY + 1} C94,${chinY + 1} 88,${chinY - 4} 88,${chinY - 14}Z" fill="${dark}"/>`;
    case "full": return `<g clip-path="url(#jawClip)"><path d="${facePath(l)}" fill="url(#hairG)" transform="translate(100 108) scale(1.04) translate(-100 -108)"/></g>
      <g transform="translate(100,${my}) scale(${L.ms})"><path d="M-15,-3 C-10,10 10,10 15,-3 C8,3 -8,3 -15,-3Z" fill="${shade(c, -0.4)}" opacity=".6"/></g>` + stache;
    default: return "";
  }
}

function glasses(l, L) {
  if (l.glasses === "none") return "";
  const [a, b] = L.ex, y = L.ey, k = L.es * 0.6 + 0.4, earL = 100 - 51 * L.fw, earR = 100 + 51 * L.fw;
  const arms = (col, w) => `<path d="M${a - 15 * k},${y - 4} L${earL + 2},${y - 7} M${b + 15 * k},${y - 4} L${earR - 2},${y - 7}" fill="none" stroke="${col}" stroke-width="${w}" stroke-linecap="round"/>`;
  const bridge = (col, w, half) => `<path d="M${a + half},${y - 3} C${(a + b) / 2 - 3},${y - 7} ${(a + b) / 2 + 3},${y - 7} ${b - half},${y - 3}" fill="none" stroke="${col}" stroke-width="${w}"/>`;
  const lensShine = `<path d="M${a - 8 * k},${y - 6 * k} L${a - 1 * k},${y - 9 * k} M${b - 8 * k},${y - 6 * k} L${b - 1 * k},${y - 9 * k}" stroke="#fff" stroke-opacity=".7" stroke-width="2.6" stroke-linecap="round"/>`;
  const lens = (cx, shape, fill, stroke, sw) => shape === "round" ? `<circle cx="${cx}" cy="${y}" r="${14 * k}" fill="${fill}" stroke="${stroke}" stroke-width="${sw}"/>`
    : `<rect x="${cx - 16 * k}" y="${y - 12 * k}" width="${32 * k}" height="${24 * k}" rx="${(shape === "soft" ? 11 : 6) * k}" fill="${fill}" stroke="${stroke}" stroke-width="${sw}"/>`;
  const shadow = `<g opacity=".18" filter="url(#soft)" transform="translate(0,4)">${lens(a, l.glasses === "round" ? "round" : "rect", "#000", "none", 0)}${lens(b, l.glasses === "round" ? "round" : "rect", "#000", "none", 0)}</g>`;
  switch (l.glasses) {
    case "stars": {
      const star = cx => `<path transform="translate(${cx},${y}) scale(${k})" d="M0,-15 L4.4,-5.2 L15,-4.6 L6.8,2.2 L9.4,12.6 L0,6.8 L-9.4,12.6 L-6.8,2.2 L-15,-4.6 L-4.4,-5.2Z"/>`;
      return `${arms("#f2b705", 3)}<g fill="url(#tint)" fill-opacity=".85" stroke="#f2b705" stroke-width="3" stroke-linejoin="round">${star(a)}${star(b)}</g>${bridge("#f2b705", 3, 10 * k)}${lensShine}`;
    }
    case "sunglasses": return `${shadow}${arms("#14161b", 3.2)}
      <g fill="url(#darkLens)">${[a, b].map(cx => `<path transform="translate(${cx},${y}) scale(${k})" d="M-16,-9 C-16,-12 16,-12 16,-9 C16,5 11,12 0,12 C-11,12 -16,5 -16,-9Z"/>`).join("")}</g>
      ${bridge("#14161b", 3.2, 16 * k)}${lensShine}`;
    case "tinted": return `${shadow}${arms("#d9dbe2", 2.6)}${lens(a, "soft", "url(#tint)", "#d9dbe2", 2.6)}${lens(b, "soft", "url(#tint)", "#d9dbe2", 2.6)}${bridge("#d9dbe2", 2.6, 16 * k)}${lensShine}`;
    default: {
      const shape = l.glasses === "round" ? "round" : "rect", half = (shape === "round" ? 14 : 16) * k;
      return `${shadow}${arms("#1d1d22", 3)}${lens(a, shape, "#fff", "#1d1d22", 3)}${lens(b, shape, "#fff", "#1d1d22", 3)}`.replace(/fill="#fff"/g, 'fill="#fff" fill-opacity=".12"')
        + bridge("#1d1d22", 3, half) + lensShine;
    }
  }
}

// hair: [behind the head, over the head]. Smooth styles get a few strands so they read as hair, not a helmet.
let clipN = 0;
function strands(d, c, spread = 1) {
  const id = "hc" + (++clipN);
  const lines = [-3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5].map(i => `<path d="M${100 + i * 6},34 C${100 + i * 12 * spread},48 ${100 + i * 17 * spread},70 ${100 + i * 20 * spread},110"/>`).join("");
  const dark = parseInt(c, 16) < 0x404040;
  return `<clipPath id="${id}"><path d="${d}"/></clipPath><g clip-path="url(#${id})" fill="none" stroke-linecap="round" filter="url(#hairSoft)">
    <g stroke="${shade(c, -0.4)}" stroke-width="2.2" opacity=".28">${lines}</g>
    <g stroke="${shade(c, 0.45)}" stroke-width="1.4" opacity="${dark ? 0.1 : 0.18}" transform="translate(3.5,1)">${lines}</g></g>`;
}
function hair(l) {
  const c = l.hairColor;
  const curls = (cx, cy, rx, ry, from, to, n, r) => Array.from({ length: n }, (_, i) => {
    const a = (from + (to - from) * i / (n - 1)) * Math.PI / 180;
    return `<circle cx="${(cx + rx * Math.cos(a)).toFixed(1)}" cy="${(cy + ry * Math.sin(a)).toFixed(1)}" r="${r + (i % 2) * 2}"/>`;
  }).join("");
  const top = (d, shine = "M78,56 C88,49 104,47 116,50", s = true) => `<path d="${d}" fill="url(#hairG)"/>${s ? strands(d, c) : ""}${gloss(shine)}`;
  const back = d => `<path d="${d}" fill="url(#hairG)"/>${strands(d, c, 1.3)}`;
  switch (l.hair) {
    case "crew": return ["", top("M47,112 C40,60 68,34 100,34 C134,34 161,58 153,112 C150,92 143,80 134,74 C118,80 92,78 74,68 C62,80 52,94 47,112Z")];
    case "sidePart": return ["", top("M46,114 C38,58 70,30 104,32 C140,32 164,58 154,114 C151,90 145,78 136,71 C118,70 94,66 74,58 C84,70 66,82 57,94 C51,100 48,106 46,114Z", "M82,46 C98,38 120,39 136,50")];
    case "quiff": return ["", top("M48,112 C42,64 58,44 76,38 C80,14 124,8 138,30 C156,40 160,70 152,112 C148,92 141,80 132,73 C114,78 92,72 78,68 C64,80 53,94 48,112Z", "M88,30 C100,18 118,18 128,28")];
    case "buzz": return ["", `<path d="M50,106 C47,68 70,46 100,46 C130,46 153,68 150,106 C144,86 128,72 100,71 C72,72 56,86 50,106Z" fill="${c}" opacity=".92"/>`];
    case "spiky": {
      const spikes = Array.from({ length: 9 }, (_, i) => { const x = 46 + i * 13.5, h = [16, 26, 32, 36, 38, 36, 32, 26, 16][i];
        return `M${x - 9},80 L${x},${56 - h} L${x + 9},80`; }).join(" ");
      return ["", top(`M46,112 C40,72 60,52 100,52 C140,52 160,72 154,112 C150,94 142,84 132,80 C112,84 88,84 68,80 C58,86 50,98 46,112Z ${spikes}Z`, "M84,40 L96,22 M104,20 L116,38", false)];
    }
    case "curly": return ["", `<g fill="url(#hairG)">${curls(100, 78, 50, 38, 175, 365, 14, 10)}<path d="M48,108 C44,64 70,44 100,44 C130,44 156,64 152,108 C146,86 128,72 100,72 C72,72 54,86 48,108Z"/></g>${gloss("M76,50 C88,43 108,42 122,48")}`];
    case "afro": return [`<g fill="url(#hairG)">${curls(100, 86, 60, 52, 150, 390, 20, 16)}<ellipse cx="100" cy="84" rx="60" ry="52"/></g>`,
      `<path d="M52,104 C52,74 72,60 100,60 C128,60 148,74 148,104 C140,86 124,78 100,78 C76,78 60,86 52,104Z" fill="url(#hairG)"/>${gloss("M72,44 C88,32 112,32 128,44")}`];
    case "long": return [back("M44,104 C36,40 164,40 156,104 L162,186 C140,194 60,194 38,186Z"),
      top("M48,116 C40,58 72,36 100,36 C130,36 162,58 152,116 C148,88 134,72 112,66 C108,74 98,73 94,66 C76,72 56,86 48,116Z")];
    case "wavy": return [back("M44,104 C36,40 164,40 156,104 C164,124 152,136 162,154 C170,170 156,180 160,190 C136,198 64,198 40,190 C44,180 30,170 38,154 C48,136 36,124 44,104Z"),
      top("M47,118 C38,60 72,34 100,34 C130,34 164,58 153,118 C150,90 138,74 116,68 C102,78 80,72 68,82 C58,92 50,104 47,118Z")];
    case "bob": return [back("M40,106 C32,44 168,44 160,106 C162,128 162,146 154,158 C136,166 64,166 46,158 C38,146 38,128 40,106Z"),
      top("M46,104 C44,58 72,40 100,40 C128,40 156,58 154,104 C132,90 68,90 46,104Z")];
    case "bun": return [`<circle cx="100" cy="30" r="20" fill="url(#hairG)"/>`,
      top("M48,108 C44,62 72,42 100,42 C128,42 156,62 152,108 C146,84 128,70 100,68 C72,70 54,84 48,108Z") + gloss("M90,20 C96,14 106,14 110,20")];
    case "ponytail": return [back("M140,66 C176,70 180,120 164,160 C160,140 158,112 146,96Z"),
      top("M47,110 C42,60 72,40 100,40 C128,40 158,60 153,110 C146,84 128,70 100,68 C72,70 54,84 47,110Z") + `<circle cx="147" cy="72" r="6" fill="#${l.hatColor}"/>`];
    case "pigtails": return [`<g fill="url(#hairG)"><path d="M48,92 C18,92 12,140 26,166 C32,140 40,122 54,112Z"/><path d="M152,92 C182,92 188,140 174,166 C168,140 160,122 146,112Z"/></g>`,
      top("M47,110 C42,60 72,40 100,40 C128,40 158,60 153,110 C146,84 128,70 100,68 C72,70 54,84 47,110Z")
      + `<circle cx="49" cy="92" r="6" fill="#${l.hatColor}"/><circle cx="151" cy="92" r="6" fill="#${l.hatColor}"/>`];
    case "locs": return [`<g fill="url(#hairG)">${[40, 50, 60, 140, 150, 160].map(x => `<rect x="${x - 5.5}" y="70" width="11" height="${x < 100 ? 118 - (x - 40) : 118 - (160 - x)}" rx="5.5"/>`).join("")}</g>`,
      `<g fill="url(#hairG)"><path d="M46,110 C42,62 70,40 100,40 C130,40 158,62 154,110 C146,84 128,70 100,68 C72,70 54,84 46,110Z"/>${curls(100, 64, 44, 22, 190, 350, 10, 7)}</g>`];
    case "hijab": {
      const cloth = "#" + l.hatColor;
      return [`<path d="M38,110 C30,30 170,30 162,110 C162,150 156,176 160,200 L40,200 C44,176 38,150 38,110Z" fill="${cloth}"/>
        <path d="M38,110 C30,30 170,30 162,110 C162,150 156,176 160,200 L40,200 C44,176 38,150 38,110Z" fill="url(#shadeTop)"/>`,
        `<path d="M52,108 C50,66 72,48 100,48 C128,48 150,66 148,108 C140,80 124,66 100,66 C76,66 60,80 52,108Z" fill="${cloth}"/>
         <path d="M52,108 C50,66 72,48 100,48 C128,48 150,66 148,108" fill="none" stroke="${shade(l.hatColor, -0.15)}" stroke-width="2"/>${gloss("M70,48 C86,38 114,38 130,48")}`];
    }
    default: return ["", gloss("M80,62 C90,58 106,57 116,60", 0.35)];  // bald: just a shine
  }
}

// hats: [behind the head, on top]
function hat(l) {
  const c = "#" + l.hatColor, dark = shade(l.hatColor, -0.2), light = shade(l.hatColor, 0.25);
  const dome = `M46,84 C44,38 72,20 100,20 C128,20 156,38 154,84 C136,78 64,78 46,84Z`;
  switch (l.hat) {
    case "cap": return ["", `<path d="${dome}" fill="${c}"/><path d="${dome}" fill="url(#shadeTop)"/>
      <path d="M100,22 L100,80" stroke="${dark}" stroke-width="1.5" opacity=".6"/><circle cx="100" cy="21" r="4" fill="${dark}"/>
      <path d="M42,80 C60,68 140,68 158,80 C164,90 154,98 100,94 C46,98 36,90 42,80Z" fill="${dark}"/>
      <path d="M44,80 C62,71 138,71 156,80" fill="none" stroke="${light}" stroke-width="2" opacity=".6"/>${gloss("M66,40 C80,30 98,28 112,30")}`];
    case "backwards": return ["", `<path d="${dome}" fill="${c}"/><path d="${dome}" fill="url(#shadeTop)"/>
      <path d="M76,82 C82,66 118,66 124,82" fill="${dark}"/><rect x="80" y="74" width="40" height="5" rx="2.5" fill="${shade(l.hatColor, -0.35)}"/>
      <path d="M46,84 C64,78 136,78 154,84" fill="none" stroke="${dark}" stroke-width="4"/><circle cx="100" cy="21" r="4" fill="${dark}"/>${gloss("M66,40 C80,30 98,28 112,30")}`];
    case "beanie": case "catBeanie": {  // sits a little higher than the others, so the brows show
      const ears = l.hat === "catBeanie" ? `<path d="M52,54 L50,12 L82,34Z M148,54 L150,12 L118,34Z" fill="${c}"/><path d="M56,44 L55,22 L72,34Z M144,44 L145,22 L128,34Z" fill="${light}" opacity=".7"/>` : "";
      return ["", `<g transform="translate(0,-7)">${ears}<path d="M46,92 C42,40 70,18 100,18 C130,18 158,40 154,92Z" fill="${c}"/><path d="M46,92 C42,40 70,18 100,18 C130,18 158,40 154,92Z" fill="url(#shadeTop)"/>
        <rect x="42" y="78" width="116" height="20" rx="10" fill="${dark}"/>
        ${[54, 66, 78, 90, 102, 114, 126, 138, 150].map(x => `<path d="M${x - 2},81 L${x - 2},95" stroke="${shade(l.hatColor, -0.34)}" stroke-width="2" stroke-linecap="round"/>`).join("")}
        ${l.hat === "beanie" ? `<circle cx="100" cy="16" r="10" fill="${light}"/>` : ""}${gloss("M64,40 C78,28 96,24 112,26")}</g>`];
    }
    case "beret": return ["", `<path d="M40,74 C36,50 70,34 106,36 C146,38 170,56 160,76 C150,90 54,92 40,74Z" fill="${c}"/>
      <path d="M40,74 C36,50 70,34 106,36 C146,38 170,56 160,76" fill="url(#shadeTop)"/><path d="M104,36 L106,26" stroke="${dark}" stroke-width="4" stroke-linecap="round"/>
      <path d="M46,80 C70,88 136,88 156,78" fill="none" stroke="${dark}" stroke-width="3"/>${gloss("M66,52 C82,44 104,42 122,44")}`];
    case "bucket": return ["", `<path d="M56,78 C54,40 76,24 100,24 C124,24 146,40 144,78Z" fill="${c}"/><path d="M56,78 C54,40 76,24 100,24 C124,24 146,40 144,78Z" fill="url(#shadeTop)"/>
      <path d="M32,96 C40,74 160,74 168,96 C150,90 50,90 32,96Z" fill="${dark}"/><path d="M56,76 C80,70 120,70 144,76" fill="none" stroke="${shade(l.hatColor, -0.35)}" stroke-width="3"/>${gloss("M72,40 C84,32 100,30 114,32")}`];
    case "cowboy": return ["", `<path d="M62,74 C58,34 76,18 88,26 C94,30 106,30 112,26 C124,18 142,34 138,74Z" fill="${c}"/>
      <path d="M62,74 C58,34 76,18 88,26 C94,30 106,30 112,26 C124,18 142,34 138,74Z" fill="url(#shadeTop)"/><rect x="62" y="64" width="76" height="9" fill="${shade(l.hatColor, -0.4)}"/>
      <path d="M20,70 C30,92 170,92 180,70 C176,84 150,96 100,96 C50,96 24,84 20,70Z" fill="${dark}"/>${gloss("M76,36 C82,28 90,28 94,32")}`];
    case "headband": return ["", `<path d="M48,86 C60,68 140,68 152,86 L150,98 C138,82 62,82 50,98Z" fill="url(#rainbow)"/>
      <path d="M48,86 C60,68 140,68 152,86" fill="none" stroke="#fff" stroke-opacity=".5" stroke-width="2"/>`];
    case "headphones": return ["", `<path d="M44,110 C36,40 164,40 156,110" fill="none" stroke="${c}" stroke-width="9" stroke-linecap="round"/>
      <path d="M44,110 C36,40 164,40 156,110" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="3" stroke-linecap="round"/>
      <rect x="32" y="96" width="22" height="34" rx="10" fill="${c}"/><rect x="146" y="96" width="22" height="34" rx="10" fill="${c}"/>
      <rect x="32" y="96" width="22" height="34" rx="10" fill="url(#shadeTop)"/><rect x="146" y="96" width="22" height="34" rx="10" fill="url(#shadeTop)"/>`];
    case "bow": return ["", `<g transform="translate(128,50) rotate(18)"><path d="M0,0 C-10,-18 -34,-14 -30,2 C-28,16 -10,14 0,0Z M0,0 C10,-18 34,-14 30,2 C28,16 10,14 0,0Z" fill="${c}"/>
      <path d="M0,0 C-10,-18 -34,-14 -30,2 M0,0 C10,-18 34,-14 30,2" fill="none" stroke="${light}" stroke-width="2" opacity=".6"/><circle r="7" fill="${dark}"/></g>`];
    case "bunny": return [`<g fill="${c}"><ellipse cx="72" cy="22" rx="13" ry="36" transform="rotate(-12 72 22)"/><ellipse cx="128" cy="22" rx="13" ry="36" transform="rotate(12 128 22)"/></g>
      <g fill="#ffc2d8"><ellipse cx="72" cy="24" rx="6" ry="26" transform="rotate(-12 72 24)"/><ellipse cx="128" cy="24" rx="6" ry="26" transform="rotate(12 128 24)"/></g>`,
      `<path d="M50,70 C62,48 138,48 150,70" fill="none" stroke="${c}" stroke-width="7" stroke-linecap="round"/>`];
    case "crown": return ["", `<path d="M62,64 L58,26 L80,46 L100,18 L120,46 L142,26 L138,64Z" fill="#ffc53d" stroke="#e39b00" stroke-width="2.5" stroke-linejoin="round"/>
      <rect x="60" y="58" width="80" height="10" rx="4" fill="#f0a500"/><circle cx="100" cy="44" r="5" fill="#e8453c"/><circle cx="78" cy="52" r="3.5" fill="#2f80ed"/><circle cx="122" cy="52" r="3.5" fill="#3fbf6b"/>
      ${gloss("M70,40 L74,56", 0.6)}`];
    default: return ["", ""];
  }
}

// neck, shoulders and the outfit (below the chin, y 150-232)
function body(l) {
  const c = "#" + l.topColor, dark = shade(l.topColor, -0.2), deep = shade(l.topColor, -0.35), light = shade(l.topColor, 0.3);
  const torso = "M16,234 C18,202 42,184 78,177 C88,184 112,184 122,177 C158,184 182,202 184,234Z";
  const neck = `<path d="M84,148 L84,178 C92,186 108,186 116,178 L116,148Z" fill="url(#skinG)"/>`;
  const base = `<g filter="url(#puffBody)"><path d="${torso}" fill="${c}"/></g>${gloss("M40,200 C50,190 62,186 72,184", 0.35, 6)}${gloss("M160,200 C150,190 138,186 128,184", 0.2, 6)}`;
  switch (l.top) {
    case "hoodie": return `${neck}${base}
      <path d="M64,184 C62,164 138,164 136,184 C126,178 74,178 64,184Z" fill="${dark}"/>
      <path d="M78,178 C86,190 114,190 122,178 C114,184 86,184 78,178Z" fill="${deep}"/>
      <path d="M90,186 L88,212 M110,186 L112,212" stroke="${isLight(l.topColor) ? "#8a8f9c" : "#f4f1ea"}" stroke-width="2.2" stroke-linecap="round"/>
      <circle cx="88" cy="213" r="2.4" fill="${deep}"/><circle cx="112" cy="213" r="2.4" fill="${deep}"/>
      <path d="M70,234 C72,222 128,222 130,234" fill="none" stroke="${dark}" stroke-width="2" opacity=".6"/>`;
    case "collar": return `${neck}${base}
      <path d="M86,180 L100,204 L114,180Z" fill="url(#skinG)"/>
      <path d="M78,176 L98,206 L90,212 L72,184Z M122,176 L102,206 L110,212 L128,184Z" fill="${light}"/>
      <path d="M78,176 L98,206 L90,212 L72,184Z M122,176 L102,206 L110,212 L128,184Z" fill="none" stroke="${dark}" stroke-width="1.5" stroke-linejoin="round"/>
      <circle cx="100" cy="214" r="2" fill="${deep}"/><circle cx="100" cy="226" r="2" fill="${deep}"/>`;
    case "turtleneck": return `${neck}${base}
      <rect x="80" y="160" width="40" height="26" rx="12" fill="${c}"/><rect x="80" y="160" width="40" height="26" rx="12" fill="url(#shadeTop)"/>
      ${[86, 93, 100, 107, 114].map(x => `<path d="M${x},164 L${x},183" stroke="${dark}" stroke-width="1.6" stroke-linecap="round" opacity=".7"/>`).join("")}`;
    case "jacket": return `${neck}<g filter="url(#puffBody)"><path d="${torso}" fill="#f4f1ea"/></g>
      <path d="M78,177 C88,188 112,188 122,177" fill="none" stroke="#d6d2c8" stroke-width="3"/>
      <g filter="url(#puffBody)"><path d="M16,234 C18,202 42,184 78,177 L94,234Z M184,234 C182,202 158,184 122,177 L106,234Z" fill="${c}"/></g>
      <path d="M78,177 L86,200 L80,206 L94,234 M122,177 L114,200 L120,206 L106,234" fill="none" stroke="${deep}" stroke-width="2" stroke-linejoin="round"/>
      ${gloss("M40,200 C50,190 62,186 72,184", 0.3, 6)}`;
    default: return `${neck}${base}<path d="M78,177 C86,190 114,190 122,177" fill="none" stroke="${dark}" stroke-width="4" stroke-linecap="round"/>`;  // tee
  }
}

// view: "full" (the picture), "head" (zoomed on hair and hats), "face" (zoomed on eyes and mouth)
// hats that cover the top of the head, and where their edge is: hair above that line is hidden, so nothing pokes through
const HAT_LINE = { cap: 80, backwards: 82, beanie: 84, catBeanie: 84, bucket: 84, cowboy: 76, beret: 76 };

export function drawCharacter(look, view = "full") {
  clipN = 0;
  const l = cleanLook(look), L = layout(l), [hairBack0, hairFront0] = hair(l), [hatBack, hatFront] = hat(l);
  const line = HAT_LINE[l.hat];
  const under = h => line && h ? `<clipPath id="underHat"><path d="M-40,${line - 2} C40,${line + 4} 160,${line + 4} 240,${line - 2} L240,260 L-40,260Z"/></clipPath><g clip-path="url(#underHat)">${h}</g>` : h;
  const hairFront = under(hairFront0), hairBack = line && ["bun"].includes(l.hair) ? "" : hairBack0;
  const box = { full: "0 0 200 200", head: "8 4 184 184", face: "46 72 108 108" }[view] || "0 0 200 200";
  const face = facePath(l);
  const ear = x => `<ellipse cx="${x}" cy="114" rx="10" ry="13" fill="url(#skinG)"/>
    <path d="M${x + (x < 100 ? 3 : -3)},106 C${x + (x < 100 ? -4 : 4)},108 ${x + (x < 100 ? -4 : 4)},120 ${x + (x < 100 ? 2 : -2)},122" fill="none" stroke="${shade(l.skin, -0.25)}" stroke-width="2.4" stroke-linecap="round" opacity=".5"/>`;
  // the whole person gets smaller in the picture when big hair or a tall hat would poke out of the top
  const tall = ["afro", "spiky", "bun"].includes(l.hair) || ["cowboy", "bunny", "crown", "catBeanie", "beanie"].includes(l.hat);
  const fit = view !== "full" ? "" : tall ? "translate(100 110) scale(.84) translate(-100 -108)" : "translate(100 104) scale(.92) translate(-100 -108)";
  const wide = `translate(100 0) scale(${L.fw} 1) translate(-100 0)`;  // Face width: head, hair and hats together
  const puff = (id, blur, height) => `<filter id="${id}" x="-15%" y="-15%" width="130%" height="130%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="${blur}" result="b"/>
      <feDiffuseLighting in="b" surfaceScale="${height}" diffuseConstant="1.18" lighting-color="#fff" result="d"><feDistantLight azimuth="235" elevation="62"/></feDiffuseLighting>
      <feSpecularLighting in="b" surfaceScale="${height}" specularConstant=".55" specularExponent="26" lighting-color="#fff" result="s"><feDistantLight azimuth="235" elevation="60"/></feSpecularLighting>
      <feGaussianBlur in="d" stdDeviation="${blur / 3}" result="d2"/><feGaussianBlur in="s" stdDeviation="${blur / 3}" result="s1"/>
      <feComposite in="SourceGraphic" in2="d2" operator="arithmetic" k1="1" result="lit"/>
      <feComposite in="s1" in2="SourceAlpha" operator="in" result="s2"/>
      <feComposite in="lit" in2="s2" operator="arithmetic" k2="1" k3=".35" result="o"/>
      <feComposite in="o" in2="SourceAlpha" operator="in"/></filter>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}" width="256" height="256">
  <defs>
    <radialGradient id="skinG" cx="42%" cy="34%" r="75%"><stop offset="0" stop-color="${shade(l.skin, 0.16)}"/><stop offset=".6" stop-color="#${l.skin}"/><stop offset="1" stop-color="${blend(l.skin, "b0584a", 0.18)}"/></radialGradient>
    <radialGradient id="noseG" cx="40%" cy="35%" r="70%"><stop offset="0" stop-color="${shade(l.skin, 0.12)}"/><stop offset="1" stop-color="${shade(l.skin, -0.06)}"/></radialGradient>
    <linearGradient id="hairG" x1="0" y1="0" x2=".35" y2="1"><stop offset="0" stop-color="${shade(l.hairColor, 0.24)}"/><stop offset=".5" stop-color="#${l.hairColor}"/><stop offset="1" stop-color="${shade(l.hairColor, -0.3)}"/></linearGradient>
    <radialGradient id="iris" cx="50%" cy="65%" r="60%"><stop offset="0" stop-color="${shade(l.eyeColor, 0.5)}"/><stop offset=".7" stop-color="#${l.eyeColor}"/><stop offset="1" stop-color="${shade(l.eyeColor, -0.3)}"/></radialGradient>
    <linearGradient id="sclera" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e7e2e6"/><stop offset=".45" stop-color="#fff"/></linearGradient>
    <linearGradient id="tongueG" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e2566a"/><stop offset="1" stop-color="#f58a97"/></linearGradient>
    <linearGradient id="darkLens" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a3f4b"/><stop offset="1" stop-color="#0c0d10"/></linearGradient>
    <linearGradient id="shadeTop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#000" stop-opacity=".16"/></linearGradient>
    <linearGradient id="tint" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff9ad5" stop-opacity=".85"/><stop offset=".35" stop-color="#ffd36b" stop-opacity=".85"/><stop offset=".7" stop-color="#8ef0c6" stop-opacity=".85"/><stop offset="1" stop-color="#7cc4ff" stop-opacity=".85"/></linearGradient>
    <linearGradient id="rainbow" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ff5c5c"/><stop offset=".2" stop-color="#ff9f1c"/><stop offset=".4" stop-color="#ffe14d"/><stop offset=".6" stop-color="#3fd17a"/><stop offset=".8" stop-color="#3f9bff"/><stop offset="1" stop-color="#9b6bff"/></linearGradient>
    <radialGradient id="bgG" cx="50%" cy="28%" r="85%"><stop offset="0" stop-color="${shade(l.bg, 0.35)}"/><stop offset="1" stop-color="${shade(l.bg, -0.04)}"/></radialGradient>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="2"/></filter>
    <filter id="hairSoft"><feGaussianBlur stdDeviation=".6"/></filter>
    <filter id="stubble" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="3"/></filter>
    <!-- a soft shadow where hair, hats and the chin meet the skin -->
    <filter id="ao" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="3.2"/><feOffset dy="3.5"/>
      <feComponentTransfer><feFuncA type="linear" slope=".38"/></feComponentTransfer></filter>
    <!-- makes flat shapes look puffy and lit from the top left, like soft 3D -->
    ${puff("puff", 7, 5)}${puff("puffHair", 5, 4)}${puff("puffBody", 9, 5)}
    <clipPath id="faceClip"><path d="${face}"/></clipPath>
    <clipPath id="neckClip"><path d="M84,140 L84,190 L116,190 L116,140Z"/></clipPath>
    <clipPath id="jawClip"><path d="M0,${L.my - 12} C40,${L.my - 2} 60,${L.my - 8} 100,${L.my - 8} C140,${L.my - 8} 160,${L.my - 2} 200,${L.my - 12} L200,240 L0,240Z"/></clipPath>
  </defs>
  <rect x="-20" y="-20" width="240" height="260" fill="url(#bgG)"/>
  <g transform="${fit}">
    <g transform="${wide}"><g filter="url(#puffHair)">${hatBack}${hairBack}</g></g>
    ${body(l)}
    <g clip-path="url(#neckClip)"><g filter="url(#ao)"><path d="${face}" transform="translate(0,2)"/></g></g>
    <g transform="${wide}">
      ${l.hair === "hijab" ? "" : `<g filter="url(#puff)">${ear(49)}${ear(151)}</g>`}
      <g filter="url(#puff)"><path d="${face}" fill="url(#skinG)"/></g>
      <g clip-path="url(#faceClip)"><g filter="url(#ao)">${hairFront}${hatFront}</g></g>
      ${beard(l, L)}
    </g>
    <ellipse cx="${L.ex[0] - 8}" cy="${L.ey + 22}" rx="11" ry="7" fill="#ff6f8a" opacity=".3" filter="url(#soft)"/>
    <ellipse cx="${L.ex[1] + 8}" cy="${L.ey + 22}" rx="11" ry="7" fill="#ff6f8a" opacity=".3" filter="url(#soft)"/>
    ${nose(l, L)}
    ${mouth(l, L)}
    ${eye(L.ex[0], false, l, L, false)}${eye(L.ex[1], true, l, L, l.eyes === "wink")}
    ${brows(l, L)}
    <g transform="${wide}"><g filter="url(#puffHair)">${hairFront}</g></g>
    ${glasses(l, L)}
    <g transform="${wide}"><g filter="url(#puffHair)">${hatFront}</g></g>
  </g>
</svg>`;
}

export const characterSrc = (look, view) => "data:image/svg+xml;charset=utf-8," + encodeURIComponent(drawCharacter(look, view));

// the picture friends see: a 256 px JPEG (small, and works everywhere a photo does)
export function renderJpeg(look) {
  return new Promise((ok, no) => {
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 256;
      canvas.getContext("2d").drawImage(img, 0, 0, 256, 256);
      ok(canvas.toDataURL("image/jpeg", 0.9));
    };
    img.onerror = () => no(new Error("Couldn't draw your character."));
    img.src = characterSrc(look);
  });
}
