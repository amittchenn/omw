// omw characters: chunky, glossy 3D-style heads (think Memoji / a sticker sheet), drawn right here in the browser.
// A look is a small list of choices, e.g. { gender: "woman", skin: "e0ac85", hair: "pigtails", hat: "bow", glasses: "tinted", ... }.
// drawCharacter(look) returns an SVG picture; renderJpeg() turns it into a small JPEG to use as your profile picture.

export const SKINS = ["fde0cf", "f5cdb3", "eab897", "e0ac85", "c98d62", "a86b43", "8a5230", "5e3720"];
export const HAIR_COLORS = ["16100c", "3b2417", "5c3a22", "8a5a33", "b07a45", "f2c94c", "efd9a0", "e0612f", "a33b1d", "c9c4bf",
                            "ff8fc6", "9b6bff", "3f7bff", "2fbf71"];
export const EYE_COLORS = ["3a2112", "6b4423", "8a6a3a", "4d7a3a", "3f6f9a", "7da2c8", "6d7278"];
export const HAT_COLORS = ["1d1f27", "e8453c", "ff8a1f", "ffd23f", "3fbf6b", "2f80ed", "8e5cf7", "ff7eb6", "8b5a2b", "f4f1ea"];
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
};
export const COLOR_PARTS = { skin: SKINS, hairColor: HAIR_COLORS, eyeColor: EYE_COLORS, hatColor: HAT_COLORS, bg: BGS };

// Man and Woman each get their own set of choices: their own hairstyles, eyes and brows, and beards only for Man.
// Anything not listed here (face, nose, mouth, hats, glasses, colors) is the same for both.
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
    hat: roll("ht") < 45 ? one("h2", PARTS.hat.slice(1)) : "none", hatColor: one("hk", HAT_COLORS),
    glasses: roll("g") < 40 ? one("g2", PARTS.glasses.slice(1)) : "none", bg: one("bg", BGS.slice(0, 6)) });
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
// a glossy highlight streak, the thing that makes a shape look like soft plastic
const gloss = (d, o = 0.45) => `<path d="${d}" fill="none" stroke="#fff" stroke-opacity="${o}" stroke-width="5" stroke-linecap="round" filter="url(#soft)"/>`;

// ---------- the head (200 x 200 drawing; the head is centered at 100,108) ----------
const FACES = {
  round: "M100,54 C131,54 152,76 152,108 C152,141 129,162 100,162 C71,162 48,141 48,108 C48,76 69,54 100,54Z",
  oval: "M100,52 C128,52 147,74 147,106 C147,141 127,165 100,165 C73,165 53,141 53,106 C53,74 72,52 100,52Z",
  square: "M100,54 C136,54 151,70 151,104 C151,138 142,162 100,162 C58,162 49,138 49,104 C49,70 64,54 100,54Z",
  heart: "M100,54 C134,54 152,74 152,103 C152,133 127,162 100,165 C73,162 48,133 48,103 C48,74 66,54 100,54Z",
};
const EYE_Y = 110, EYE_X = [81, 119];

function eye(x, flip, l, closed) {
  const s = flip ? -1 : 1, lid = "#23150f";
  if (closed || l.eyes === "happy")  // ^ ^
    return `<path transform="translate(${x},${EYE_Y}) scale(${s},1)" d="M-9,3 C-5,-5 5,-5 9,3" fill="none" stroke="${lid}" stroke-width="3.6" stroke-linecap="round"/>`;
  const ry = { round: 10, almond: 8.5, lashes: 10, hooded: 9, narrow: 5.5, wink: 10 }[l.eyes] || 10;
  const lashes = l.eyes === "lashes" || l.gender === "woman"
    ? `<path d="M-7,-${ry - 1} L-9,-${ry + 3} M-9.5,-${ry - 3.5} L-12.5,-${ry} M-10.5,-${ry - 6.5} L-14,-${ry - 4}" stroke="${lid}" stroke-width="2" stroke-linecap="round"/>` : "";
  const hood = l.eyes === "hooded" ? `<path d="M-10.5,-2 C-6,-${ry + 2} 6,-${ry + 2} 10.5,-2 L10.5,-${ry + 2} L-10.5,-${ry + 2}Z" fill="url(#skinG)"/>
      <path d="M-10.5,-2 C-6,-${ry - 1} 6,-${ry - 1} 10.5,-2" fill="none" stroke="${lid}" stroke-width="2.4" stroke-linecap="round"/>` : "";
  const narrow = l.eyes === "narrow" ? `<path d="M-10,-3 C-5,-6 5,-6 10,-3" fill="none" stroke="${lid}" stroke-width="2.6" stroke-linecap="round"/>` : "";
  return `<g transform="translate(${x},${EYE_Y}) scale(${s},1)">
    <clipPath id="ec${x}"><ellipse rx="9.5" ry="${ry}"/></clipPath>
    <ellipse rx="9.5" ry="${ry}" fill="#fff"/>
    <g clip-path="url(#ec${x})">
      <circle cx="0.5" cy="1" r="7.6" fill="url(#iris)"/><circle cx="0.5" cy="1" r="3.8" fill="#0b0705"/>
      <circle cx="-2.4" cy="-2.6" r="2.6" fill="#fff"/><circle cx="3" cy="3.4" r="1.2" fill="#fff" opacity=".8"/>
      <ellipse cy="-${ry}" rx="10" ry="3.5" fill="#000" opacity=".12"/>
    </g>
    <ellipse rx="9.5" ry="${ry}" fill="none" stroke="${lid}" stroke-width="1.6"/>${hood}${narrow}${lashes}
  </g>`;
}

const BROWS = {  // one brow, drawn over the eye at 0,0
  natural: ["M-10,-17 C-4,-21 5,-21 10,-18", 3.4],
  arched: ["M-10,-15 C-5,-23 5,-23 10,-17", 3],
  straight: ["M-10,-18 C-3,-19.5 4,-19.5 10,-18.5", 3.6],
  thick: ["M-10,-17 C-4,-22 5,-22 10,-18.5", 5.2],
  thin: ["M-10,-17 C-4,-20.5 5,-20.5 10,-18", 2],
};
function brows(l) {
  const [d, w] = BROWS[l.brows], c = shade(l.hairColor, ["f2f0ec", "c9c4bf", "efd9a0", "f2c94c"].includes(l.hairColor) ? -0.35 : -0.1);
  const lift = l.mouth === "open" ? -3 : 0;  // surprised: brows up
  return `<g fill="none" stroke="${c}" stroke-width="${w}" stroke-linecap="round">
    <path transform="translate(${EYE_X[0]},${EYE_Y + lift})" d="${d}"/><path transform="translate(${EYE_X[1]},${EYE_Y + lift}) scale(-1,1)" d="${d}"/></g>`;
}

function nose(l) {
  const [rx, ry, y] = { soft: [6, 4.5, 126], button: [4.5, 4, 126], wide: [8, 5, 127], long: [5, 6, 124] }[l.nose];
  return `<ellipse cx="100" cy="${y}" rx="${rx}" ry="${ry}" fill="${shade(l.skin, -0.07)}"/>
    <ellipse cx="100" cy="${y + ry * 0.55}" rx="${rx * 0.8}" ry="${ry * 0.45}" fill="${shade(l.skin, -0.2)}" opacity=".5" filter="url(#soft)"/>
    <ellipse cx="${100 - rx * 0.35}" cy="${y - ry * 0.35}" rx="${rx * 0.35}" ry="${ry * 0.3}" fill="#fff" opacity=".55"/>`;
}

function mouth(l) {
  const dark = "#4a1418", tongue = "#ef6f7b", teeth = "#fff";
  const lip = l.gender === "woman" ? blend(l.skin, "d0455a", 0.5) : shade(l.skin, -0.35);
  switch (l.mouth) {
    case "grin": return `<path d="M83,136 C88,154 112,154 117,136 C107,139 93,139 83,136Z" fill="${dark}"/>
      <path d="M85.5,137 C94,139.5 106,139.5 114.5,137 L113.5,141 C105,143 95,143 86.5,141Z" fill="${teeth}"/>
      <path d="M91,148.5 C96,145 104,145 109,148.5 C105,151.5 95,151.5 91,148.5Z" fill="${tongue}"/>
      <path d="M83,136 C88,154 112,154 117,136" fill="none" stroke="${lip}" stroke-width="1.6" stroke-linecap="round"/>`;
    case "tongue": return `<path d="M86,137 C91,148 109,148 114,137 C105,140 95,140 86,137Z" fill="${dark}"/>
      <path d="M93,141 C93,152 107,152 107,141 C104,143 96,143 93,141Z" fill="${tongue}"/>
      <path d="M100,142 L100,148" stroke="${shade("ef6f7b", -0.2)}" stroke-width="1.2" stroke-linecap="round"/>
      <ellipse cx="97" cy="145" rx="2" ry="1.4" fill="#fff" opacity=".45"/>
      <path d="M86,137 C95,140 105,140 114,137" fill="none" stroke="${dark}" stroke-width="2.4" stroke-linecap="round"/>`;
    case "open": return `<ellipse cx="100" cy="143" rx="7.5" ry="8.5" fill="${dark}"/><ellipse cx="100" cy="148" rx="5" ry="3" fill="${tongue}"/>
      <ellipse cx="100" cy="143" rx="7.5" ry="8.5" fill="none" stroke="${lip}" stroke-width="1.6"/>`;
    case "smirk": return `<path d="M88,141 C96,143 106,141 114,134" fill="none" stroke="${dark}" stroke-width="3.2" stroke-linecap="round"/>
      <path d="M113,133 C115,134 116,136 115.5,138" fill="none" stroke="${dark}" stroke-width="1.8" stroke-linecap="round"/>`;
    case "neutral": return `<path d="M91,140 C96,141 104,141 109,140" fill="none" stroke="${dark}" stroke-width="3.2" stroke-linecap="round"/>`;
    default: return `<path d="M87,136 C92,146 108,146 113,136" fill="none" stroke="${dark}" stroke-width="3.4" stroke-linecap="round"/>
      ${l.gender === "woman" ? `<path d="M90,140 C95,144.5 105,144.5 110,140" fill="none" stroke="${lip}" stroke-width="1.4" stroke-linecap="round" opacity=".7"/>` : ""}`;
  }
}

function beard(l) {
  const c = l.hairColor, dark = shade(c, -0.15);
  const stache = `<path d="M84,134 C89,127 97,128 100,131 C103,128 111,127 116,134 C110,132 105,132.5 100,134 C95,132.5 90,132 84,134Z" fill="${dark}"/>`;
  switch (l.beard) {
    case "stubble": return `<path d="M52,120 C56,146 76,162 100,163 C124,162 144,146 148,120 C141,138 128,146 116,142 C108,139 92,139 84,142 C72,146 59,138 52,120Z" fill="${c}" opacity=".25"/>`;
    case "mustache": return stache;
    case "goatee": return stache + `<path d="M90,149 C94,146 106,146 110,149 C110,157 105,161 100,161 C95,161 90,157 90,149Z" fill="${dark}"/>`;
    case "full": return `<path d="M50,114 C51,148 74,169 100,170 C126,169 149,148 150,114 C143,132 132,139 118,137 C110,134 90,134 82,137 C68,139 57,132 50,114Z" fill="url(#hairG)"/>
      <path d="M86,139 C92,148 108,148 114,139" fill="${shade(c, -0.4)}" opacity=".7"/>` + stache;
    default: return "";
  }
}

function glasses(l) {
  const [a, b] = EYE_X, y = EYE_Y;
  switch (l.glasses) {
    case "none": return "";
    case "stars": {
      const star = cx => `<path transform="translate(${cx},${y})" d="M0,-15 L4.4,-5.2 L15,-4.6 L6.8,2.2 L9.4,12.6 L0,6.8 L-9.4,12.6 L-6.8,2.2 L-15,-4.6 L-4.4,-5.2Z"/>`;
      return `<g fill="url(#tint)" fill-opacity=".85" stroke="#f2b705" stroke-width="3" stroke-linejoin="round">${star(a)}${star(b)}</g>
        <path d="M94,${y - 2} C97,${y - 5} 103,${y - 5} 106,${y - 2}" fill="none" stroke="#f2b705" stroke-width="3"/>`;
    }
    case "sunglasses": return `<g fill="#14161b"><path d="M64,${y - 9} C64,${y - 12} 97,${y - 12} 97,${y - 9} C97,${y + 5} 92,${y + 12} 80,${y + 12} C68,${y + 12} 64,${y + 5} 64,${y - 9}Z"/>
        <path d="M136,${y - 9} C136,${y - 12} 103,${y - 12} 103,${y - 9} C103,${y + 5} 108,${y + 12} 120,${y + 12} C132,${y + 12} 136,${y + 5} 136,${y - 9}Z"/></g>
        <path d="M97,${y - 7} C99,${y - 9} 101,${y - 9} 103,${y - 7} M64,${y - 8} L52,${y - 10} M136,${y - 8} L148,${y - 10}" fill="none" stroke="#14161b" stroke-width="3"/>
        <path d="M70,${y - 6} L78,${y - 6} M109,${y - 6} L117,${y - 6}" stroke="#fff" stroke-opacity=".5" stroke-width="3" stroke-linecap="round"/>`;
    case "tinted": return `<g stroke="#d9dbe2" stroke-width="2.6"><rect x="63" y="${y - 12}" width="35" height="24" rx="11" fill="url(#tint)" fill-opacity=".78"/>
        <rect x="102" y="${y - 12}" width="35" height="24" rx="11" fill="url(#tint)" fill-opacity=".78"/></g>
        <path d="M98,${y - 4} C99.5,${y - 6} 100.5,${y - 6} 102,${y - 4} M63,${y - 6} L51,${y - 9} M137,${y - 6} L149,${y - 9}" fill="none" stroke="#d9dbe2" stroke-width="2.6"/>
        <path d="M69,${y - 7} L80,${y - 8} M108,${y - 7} L119,${y - 8}" stroke="#fff" stroke-opacity=".75" stroke-width="3" stroke-linecap="round"/>`;
    default: {
      const lens = l.glasses === "round" ? `<circle cx="${a}" cy="${y}" r="14"/><circle cx="${b}" cy="${y}" r="14"/>`
                                         : `<rect x="${a - 16}" y="${y - 12}" width="32" height="24" rx="6"/><rect x="${b - 16}" y="${y - 12}" width="32" height="24" rx="6"/>`;
      return `<g fill="#fff" fill-opacity=".14" stroke="#1d1d22" stroke-width="3">${lens}</g>
        <path d="M${a + (l.glasses === "round" ? 14 : 16)},${y - 2} C98,${y - 5} 102,${y - 5} ${b - (l.glasses === "round" ? 14 : 16)},${y - 2} M${a - 15},${y - 3} L51,${y - 7} M${b + 15},${y - 3} L149,${y - 7}" fill="none" stroke="#1d1d22" stroke-width="3"/>`;
    }
  }
}

// hair: [behind the head, over the head]
function hair(l) {
  const c = l.hairColor;
  const curls = (cx, cy, rx, ry, from, to, n, r) => Array.from({ length: n }, (_, i) => {
    const a = (from + (to - from) * i / (n - 1)) * Math.PI / 180;
    return `<circle cx="${(cx + rx * Math.cos(a)).toFixed(1)}" cy="${(cy + ry * Math.sin(a)).toFixed(1)}" r="${r + (i % 2) * 2}"/>`;
  }).join("");
  const top = (d, shine = "M78,56 C88,49 104,47 116,50") => `<path d="${d}" fill="url(#hairG)"/>${gloss(shine)}`;
  switch (l.hair) {
    case "crew": return ["", top("M47,112 C40,60 68,34 100,34 C134,34 161,58 153,112 C150,92 143,80 134,74 C118,80 92,78 74,68 C62,80 52,94 47,112Z")];
    case "sidePart": return ["", top("M46,114 C38,58 70,30 104,32 C140,32 164,58 154,114 C151,90 145,78 136,71 C118,70 94,66 74,58 C84,70 66,82 57,94 C51,100 48,106 46,114Z", "M82,46 C98,38 120,39 136,50")];
    case "quiff": return ["", top("M48,112 C42,64 58,44 76,38 C80,14 124,8 138,30 C156,40 160,70 152,112 C148,92 141,80 132,73 C114,78 92,72 78,68 C64,80 53,94 48,112Z", "M88,30 C100,18 118,18 128,28")];
    case "buzz": return ["", `<path d="M50,106 C47,68 70,46 100,46 C130,46 153,68 150,106 C144,86 128,72 100,71 C72,72 56,86 50,106Z" fill="${c}" opacity=".9"/>`];
    case "spiky": {
      const spikes = Array.from({ length: 9 }, (_, i) => { const x = 46 + i * 13.5, h = [16, 26, 32, 36, 38, 36, 32, 26, 16][i];
        return `M${x - 9},80 L${x},${56 - h} L${x + 9},80`; }).join(" ");
      return ["", top(`M46,112 C40,72 60,52 100,52 C140,52 160,72 154,112 C150,94 142,84 132,80 C112,84 88,84 68,80 C58,86 50,98 46,112Z ${spikes}Z`, "M84,40 L96,22 M104,20 L116,38")];
    }
    case "curly": return ["", `<g fill="url(#hairG)">${curls(100, 78, 50, 38, 175, 365, 14, 10)}<path d="M48,108 C44,64 70,44 100,44 C130,44 156,64 152,108 C146,86 128,72 100,72 C72,72 54,86 48,108Z"/></g>${gloss("M76,50 C88,43 108,42 122,48")}`];
    case "afro": return [`<g fill="url(#hairG)">${curls(100, 86, 60, 52, 150, 390, 20, 16)}<ellipse cx="100" cy="84" rx="60" ry="52"/></g>`,
      `<path d="M52,104 C52,74 72,60 100,60 C128,60 148,74 148,104 C140,86 124,78 100,78 C76,78 60,86 52,104Z" fill="url(#hairG)"/>${gloss("M72,44 C88,32 112,32 128,44")}`];
    case "long": return [`<path d="M44,104 C36,40 164,40 156,104 L162,186 C140,194 60,194 38,186Z" fill="url(#hairG)"/>`,
      top("M48,116 C40,58 72,36 100,36 C130,36 162,58 152,116 C148,88 134,72 112,66 C108,74 98,73 94,66 C76,72 56,86 48,116Z")];
    case "wavy": return [`<path d="M44,104 C36,40 164,40 156,104 C164,124 152,136 162,154 C170,170 156,180 160,190 C136,198 64,198 40,190 C44,180 30,170 38,154 C48,136 36,124 44,104Z" fill="url(#hairG)"/>`,
      top("M47,118 C38,60 72,34 100,34 C130,34 164,58 153,118 C150,90 138,74 116,68 C102,78 80,72 68,82 C58,92 50,104 47,118Z")];
    case "bob": return [`<path d="M40,106 C32,44 168,44 160,106 C162,128 162,146 154,158 C136,166 64,166 46,158 C38,146 38,128 40,106Z" fill="url(#hairG)"/>`,
      top("M46,104 C44,58 72,40 100,40 C128,40 156,58 154,104 C132,90 68,90 46,104Z")];
    case "bun": return [`<circle cx="100" cy="30" r="20" fill="url(#hairG)"/>`,
      top("M48,108 C44,62 72,42 100,42 C128,42 156,62 152,108 C146,84 128,70 100,68 C72,70 54,84 48,108Z") + gloss("M90,20 C96,14 106,14 110,20")];
    case "ponytail": return [`<path d="M140,66 C176,70 180,120 164,160 C160,140 158,112 146,96Z" fill="url(#hairG)"/>`,
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
    case "beanie": case "catBeanie": {
      const ears = l.hat === "catBeanie" ? `<path d="M52,54 L50,12 L82,34Z M148,54 L150,12 L118,34Z" fill="${c}"/><path d="M56,44 L55,22 L72,34Z M144,44 L145,22 L128,34Z" fill="${light}" opacity=".7"/>` : "";
      return ["", `${ears}<path d="M46,92 C42,40 70,18 100,18 C130,18 158,40 154,92Z" fill="${c}"/><path d="M46,92 C42,40 70,18 100,18 C130,18 158,40 154,92Z" fill="url(#shadeTop)"/>
        <rect x="42" y="78" width="116" height="20" rx="10" fill="${dark}"/>
        ${[54, 66, 78, 90, 102, 114, 126, 138, 150].map(x => `<path d="M${x - 2},81 L${x - 2},95" stroke="${shade(l.hatColor, -0.34)}" stroke-width="2" stroke-linecap="round"/>`).join("")}
        ${l.hat === "beanie" ? `<circle cx="100" cy="16" r="10" fill="${light}"/>` : ""}${gloss("M64,40 C78,28 96,24 112,26")}`];
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

// view: "full" (the picture), "head" (zoomed on hair and hats), "face" (zoomed on eyes and mouth)
export function drawCharacter(look, view = "full") {
  const l = cleanLook(look), [hairBack, hairFront] = hair(l), [hatBack, hatFront] = hat(l);
  const box = { full: "0 0 200 200", head: "8 0 184 184", face: "46 72 108 108" }[view] || "0 0 200 200";
  const ear = x => `<ellipse cx="${x}" cy="114" rx="10" ry="13" fill="url(#skinG)"/>
    <ellipse cx="${x}" cy="114" rx="5" ry="7" fill="${shade(l.skin, -0.14)}" opacity=".6"/>`;
  // big hair and hats would poke out of the top of the picture: shrink the whole head a little for those
  const tall = ["afro", "spiky", "bun"].includes(l.hair) || ["cowboy", "bunny", "crown", "catBeanie"].includes(l.hat);
  const fit = view !== "full" ? "" : tall ? "translate(100 116) scale(1.0) translate(-100 -108)" : "translate(100 112) scale(1.1) translate(-100 -108)";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}" width="256" height="256">
  <defs>
    <radialGradient id="skinG" cx="40%" cy="32%" r="78%"><stop offset="0" stop-color="${shade(l.skin, 0.22)}"/><stop offset=".55" stop-color="#${l.skin}"/><stop offset="1" stop-color="${shade(l.skin, -0.2)}"/></radialGradient>
    <linearGradient id="hairG" x1="0" y1="0" x2=".35" y2="1"><stop offset="0" stop-color="${shade(l.hairColor, 0.22)}"/><stop offset=".5" stop-color="#${l.hairColor}"/><stop offset="1" stop-color="${shade(l.hairColor, -0.28)}"/></linearGradient>
    <radialGradient id="iris" cx="45%" cy="35%" r="65%"><stop offset="0" stop-color="${shade(l.eyeColor, 0.4)}"/><stop offset="1" stop-color="#${l.eyeColor}"/></radialGradient>
    <linearGradient id="shadeTop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#000" stop-opacity=".16"/></linearGradient>
    <linearGradient id="tint" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff9ad5"/><stop offset=".35" stop-color="#ffd36b"/><stop offset=".7" stop-color="#8ef0c6"/><stop offset="1" stop-color="#7cc4ff"/></linearGradient>
    <linearGradient id="rainbow" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ff5c5c"/><stop offset=".2" stop-color="#ff9f1c"/><stop offset=".4" stop-color="#ffe14d"/><stop offset=".6" stop-color="#3fd17a"/><stop offset=".8" stop-color="#3f9bff"/><stop offset="1" stop-color="#9b6bff"/></linearGradient>
    <radialGradient id="bgG" cx="50%" cy="30%" r="80%"><stop offset="0" stop-color="${shade(l.bg, 0.3)}"/><stop offset="1" stop-color="#${l.bg}"/></radialGradient>
    <radialGradient id="rim" cx="50%" cy="45%" r="55%"><stop offset=".75" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".14"/></radialGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2"/></filter>
    <filter id="blur6" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
  </defs>
  <rect x="-20" y="-20" width="240" height="240" fill="url(#bgG)"/>
  <ellipse cx="100" cy="186" rx="46" ry="9" fill="#000" opacity=".16" filter="url(#blur6)"/>
  <g transform="${fit}">
    ${hatBack}
    ${hairBack}
    ${l.hair === "hijab" ? "" : ear(49) + ear(151)}
    <path d="${FACES[l.face]}" fill="url(#skinG)"/>
    <path d="${FACES[l.face]}" fill="url(#rim)"/>
    <ellipse cx="72" cy="132" rx="11" ry="7" fill="#ff6f8a" opacity=".35" filter="url(#soft)"/>
    <ellipse cx="128" cy="132" rx="11" ry="7" fill="#ff6f8a" opacity=".35" filter="url(#soft)"/>
    ${gloss("M70,72 C78,64 90,60 100,60", 0.3)}
    ${beard(l)}
    ${nose(l)}
    ${mouth(l)}
    ${eye(EYE_X[0], false, l, false)}${eye(EYE_X[1], true, l, l.eyes === "wink")}
    ${brows(l)}
    ${hairFront}
    ${glasses(l)}
    ${hatFront}
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
