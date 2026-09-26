// omw characters: a shaded, Bitmoji-style person drawn right here in the browser (no outside service).
// A look is a small list of choices, e.g. { skin: "e0ac85", face: "oval", hair: "sidePart", hairColor: "3b2417", eyes: "almond", ... }.
// drawCharacter(look, bg) returns an SVG picture; renderJpeg() turns it into a small JPEG to use as your profile picture.

export const SKINS = ["fde0cf", "f5cdb3", "eab897", "e0ac85", "c98d62", "a86b43", "8a5230", "5e3720"];
export const HAIR_COLORS = ["16100c", "3b2417", "5c3a22", "8a5a33", "b07a45", "d6b06c", "efd9a0", "a33b1d", "c9c4bf", "f2f0ec", "e86aa2", "4f7bd9"];
export const EYE_COLORS = ["4a2b16", "6b4423", "8a6a3a", "4d7a3a", "3f6f9a", "7da2c8", "6d7278"];
export const OUTFIT_COLORS = ["1f2430", "3c4a5c", "25557c", "4c8ee8", "7cc7ff", "3aa876", "a7e0b0", "f2d15c", "ff9f68", "ff6f91", "c0392b", "8e6fd8", "e9e9ee", "ffffff"];
export const BGS = ["ffd000", "ffb3c7", "b9a8ff", "8fe3c0", "9fd4ff", "ffc49c", "f1f0f7", "2b2b3a"];
export const PARTS = {
  gender: ["man", "woman", "nonbinary"],
  face: ["oval", "round", "square", "heart"],
  hair: ["crew", "sidePart", "quiff", "buzz", "curly", "afro", "long", "wavy", "bob", "bun", "locs", "bald", "beanie", "hijab"],
  eyes: ["almond", "round", "hooded", "narrow", "lashes", "happy"],
  brows: ["natural", "arched", "straight", "thick", "thin"],
  nose: ["soft", "button", "wide", "long"],
  mouth: ["smile", "grin", "neutral", "smirk", "open"],
  beard: ["none", "stubble", "mustache", "goatee", "full"],
  glasses: ["none", "round", "square", "sunglasses"],
  outfit: ["tee", "vneck", "hoodie", "collar", "sweater", "jacket"],
};
export const COLOR_PARTS = { skin: SKINS, hairColor: HAIR_COLORS, eyeColor: EYE_COLORS, outfitColor: OUTFIT_COLORS, bg: BGS };

// only known choices make it into the drawing (a profile could hold anything)
export function cleanLook(l = {}) {
  const out = {};
  for (const [k, opts] of Object.entries({ ...PARTS, ...COLOR_PARTS })) out[k] = opts.includes(l[k]) ? l[k] : opts[0];
  if (!SKINS.includes(l.skin)) out.skin = SKINS[3];
  if (!HAIR_COLORS.includes(l.hairColor)) out.hairColor = HAIR_COLORS[1];
  if (!OUTFIT_COLORS.includes(l.outfitColor)) out.outfitColor = OUTFIT_COLORS[3];
  return out;
}

// hairstyles people usually pick for each; everyone can still choose any of them
const HAIR_FOR = { man: ["crew", "sidePart", "quiff", "buzz", "curly", "afro", "locs"],
                   woman: ["long", "wavy", "bob", "bun", "curly", "afro", "locs"],
                   nonbinary: ["crew", "sidePart", "quiff", "buzz", "curly", "afro", "long", "wavy", "bob", "bun", "locs"] };
// switching gender in the editor: swap in a matching hairstyle and drop the beard, like Bitmoji's first step
export function withGender(look, gender) {
  const l = { ...look, gender };
  if (gender === "nonbinary") return l;
  if (!HAIR_FOR[gender].includes(l.hair) && !["bald", "beanie", "hijab"].includes(l.hair)) l.hair = HAIR_FOR[gender][0];
  if (gender === "woman") l.beard = "none";
  return l;
}

const hash = s => {
  let h = 2166136261;
  for (const ch of String(s)) h = Math.imul(h ^ ch.charCodeAt(0), 16777619);
  h = Math.imul(h ^ (h >>> 16), 2246822507); h = Math.imul(h ^ (h >>> 13), 3266489909);  // mix the bits so similar seeds differ
  return (h ^ (h >>> 16)) >>> 0;
};
export function randomLook(seed = Math.random().toString(36)) {
  const one = (k, list) => list[hash(seed + k) % list.length], roll = k => hash(seed + k) % 100;
  const gender = one("g0", ["man", "woman", "man", "woman", "nonbinary"]);
  return cleanLook({ gender, skin: one("s", SKINS), face: one("f", PARTS.face), hair: one("h", HAIR_FOR[gender]),
    hairColor: one("hc", HAIR_COLORS.slice(0, 8)), eyes: one("e", PARTS.eyes.slice(0, 5)), eyeColor: one("ec", EYE_COLORS),
    brows: one("b", PARTS.brows.slice(0, 4)), nose: one("n", PARTS.nose), mouth: one("m", ["smile", "grin", "smile", "smirk"]),
    beard: gender === "man" && roll("bd") < 35 ? one("bd2", PARTS.beard.slice(1)) : "none", glasses: roll("g") < 20 ? one("g2", ["round", "square"]) : "none",
    outfit: one("o", PARTS.outfit), outfitColor: one("oc", OUTFIT_COLORS), bg: "ffd000" });
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

// ---------- the parts (200 x 200 drawing, face centered at x = 100) ----------
const FACES = {
  oval: "M100,46 C125,46 139,64 139,92 C139,119 124,141 100,145 C76,141 61,119 61,92 C61,64 75,46 100,46Z",
  round: "M100,47 C128,47 141,66 141,94 C141,123 124,143 100,143 C76,143 59,123 59,94 C59,66 72,47 100,47Z",
  square: "M100,46 C127,46 140,62 140,90 C140,112 138,127 126,137 C117,143 109,145 100,145 C91,145 83,143 74,137 C62,127 60,112 60,90 C60,62 73,46 100,46Z",
  heart: "M100,46 C127,46 140,62 140,88 C140,112 123,136 100,147 C77,136 60,112 60,88 C60,62 73,46 100,46Z",
};
const EYE_SHAPES = {  // one eye, centered on 0,0 (x from -11 to 11)
  almond: ["M-11,0.5 C-6,-6 6,-6.5 11,-0.5 C6,5 -6,5.5 -11,0.5Z", "M-11,0.5 C-6,-6 6,-6.5 11,-0.5"],
  round: ["M-10,0 C-10,-8 10,-8 10,0 C10,7 -10,7 -10,0Z", "M-10,0 C-10,-8 10,-8 10,0"],
  hooded: ["M-11,0 C-6,-4 6,-4.5 11,-1 C6,4.5 -6,5 -11,0Z", "M-12,-1.5 C-6,-6 6,-6.5 12,-2.5"],
  narrow: ["M-11,0 C-5,-3.8 5,-3.8 11,0 C5,3.2 -5,3.2 -11,0Z", "M-11,0 C-5,-3.8 5,-3.8 11,0"],
  lashes: ["M-11,0.5 C-6,-6 6,-6.5 11,-0.5 C6,5 -6,5.5 -11,0.5Z", "M-11,0.5 C-6,-6 6,-6.5 11,-0.5"],
};
const BROWS = {  // one brow over the eye at 0,0; filled shapes, thicker toward the middle
  natural: "M-12,-10 C-6,-15 4,-16 12,-13 L12,-10.5 C4,-13 -6,-12 -12,-7.5Z",
  arched: "M-12,-9 C-5,-18 5,-18 12,-12 L11.5,-9.5 C5,-14.5 -4,-14.5 -12,-6.5Z",
  straight: "M-12,-11.5 C-4,-13 4,-13 12,-12 L12,-9 C4,-10 -4,-10 -12,-8.5Z",
  thick: "M-12,-10 C-6,-17 4,-18 12,-14 L12,-9.5 C4,-12.5 -6,-11.5 -12,-6Z",
  thin: "M-12,-10 C-6,-14.5 4,-15 12,-12.5 L12,-11.3 C4,-13.2 -6,-12.7 -12,-8.8Z",
};

function eye(x, flip, l, id) {
  const iris = l.eyeColor, s = flip ? -1 : 1, lid = "#2a1c16";
  if (l.eyes === "happy")  // closed, smiling eyes
    return `<g transform="translate(${x},97) scale(${s},1)"><path d="M-9,1.5 C-5,-5 5,-5 9,1.5" fill="none" stroke="${lid}" stroke-width="2.4" stroke-linecap="round"/>
      ${l.gender === "woman" ? `<path d="M-8,-0.5 L-11.5,-3" stroke="${lid}" stroke-width="1.5" stroke-linecap="round"/>` : ""}</g>`;
  const [shape, top] = EYE_SHAPES[l.eyes];
  // lashes flick out from the outer corner (x < 0 is the outside; the other eye is mirrored)
  const lashes = l.eyes === "lashes" || l.gender === "woman"
    ? `<path d="M-6.5,-4.8 L-8,-8.6 M-9,-3 L-11.8,-6.4 M-10.8,-0.6 L-14.4,-2.8" stroke="${lid}" stroke-width="${l.eyes === "lashes" ? 1.8 : 1.4}" stroke-linecap="round"/>` : "";
  return `<g transform="translate(${x},97) scale(${s},1)">
    <clipPath id="e${id}"><path d="${shape}"/></clipPath>
    <path d="${shape}" fill="#fbf8f5"/>
    <g clip-path="url(#e${id})">
      <circle cx="0.5" cy="0" r="5.4" fill="url(#iris)"/><circle cx="0.5" cy="0" r="5.4" fill="none" stroke="${shade(iris, -0.5)}" stroke-width="0.8"/>
      <circle cx="0.5" cy="0" r="2.4" fill="#0d0907"/><circle cx="-1.3" cy="-1.9" r="1.4" fill="#fff" opacity=".9"/>
      <path d="${top}" fill="none" stroke="#000" stroke-opacity=".18" stroke-width="5"/>
    </g>
    <path d="${top}" fill="none" stroke="${lid}" stroke-width="2" stroke-linecap="round"/>${lashes}
    <path d="M-9,-8 C-4,-11 4,-11.5 9,-8.5" fill="none" stroke="#000" stroke-opacity=".08" stroke-width="1.4" stroke-linecap="round"/>
  </g>`;
}

function nose(l) {
  const c = shade(l.skin, -0.28);
  const d = {
    soft: ["M97,101 C96.5,108 95,112 93.5,115.5", "M93,116 C95.5,119 104.5,119 107,116"],
    button: ["M98,106 C97.5,110 96,112.5 95,114.5", "M94.5,115.5 C97,118 103,118 105.5,115.5"],
    wide: ["M96.5,101 C96,108 93.5,112 91,115", "M90,115.5 C93,120 107,120 110,115.5"],
    long: ["M97.5,99 C97,108 95.5,114 94,118", "M93.5,118.5 C96,121.5 104,121.5 106.5,118.5"],
  }[l.nose];
  return `<path d="${d[0]}" fill="none" stroke="${c}" stroke-width="1.6" stroke-linecap="round" opacity=".7"/>
    <path d="${d[1]}" fill="none" stroke="${c}" stroke-width="2" stroke-linecap="round"/>
    <path d="M101.5,102 C102,108 102.5,111 103,113" fill="none" stroke="#fff" stroke-opacity=".28" stroke-width="2.4" stroke-linecap="round"/>`;
}

function mouth(l) {
  const lip = l.gender === "woman" ? blend(l.skin, "c2525e", 0.6) : blend(l.skin, "b8474f", 0.45), dark = shade(lip, -0.25), y = l.nose === "long" ? 131 : 129;
  const g = d => `<g transform="translate(0,${y - 129})">${d}</g>`;
  switch (l.mouth) {
    case "grin": return g(`<path d="M86,125 C92,138 108,138 114,125 C108,127 92,127 86,125Z" fill="#5b1a1f"/>
      <path d="M88.5,126 C94,127.6 106,127.6 111.5,126 L110.5,129.4 C104,130.8 96,130.8 89.5,129.4Z" fill="#fff"/>
      <path d="M92,134.5 C97,136.5 103,136.5 108,134.5 C104,133 96,133 92,134.5Z" fill="#e0777d"/>
      <path d="M86,125 C92,138 108,138 114,125" fill="none" stroke="${lip}" stroke-width="2.4" stroke-linecap="round"/>
      <path d="M86,125 C92,127 108,127 114,125" fill="none" stroke="${dark}" stroke-width="1.2" stroke-linecap="round"/>`);
    case "neutral": return g(`<path d="M89,129 C94,126.5 98,127.5 100,128 C102,127.5 106,126.5 111,129 C106,129.5 94,129.5 89,129Z" fill="${dark}"/>
      <path d="M89,129 C95,134.5 105,134.5 111,129 C105,130 95,130 89,129Z" fill="${lip}"/>`);
    case "smirk": return g(`<path d="M89,129.5 C95,128.5 103,128 112,124.5 C106,131 95,133.5 89,129.5Z" fill="${lip}"/>
      <path d="M89,129.5 C95,129 103,128 112,124.5" fill="none" stroke="${dark}" stroke-width="1.5" stroke-linecap="round"/>`);
    case "open": return g(`<ellipse cx="100" cy="131" rx="8" ry="6.5" fill="#5b1a1f"/><path d="M93,128 C97,126.5 103,126.5 107,128 L106,129.8 C102,129 98,129 94,129.8Z" fill="#fff"/>
      <ellipse cx="100" cy="131" rx="8" ry="6.5" fill="none" stroke="${lip}" stroke-width="2.6"/>`);
    default: return g(`<path d="M87,126 C93,127 97,126.5 100,127.5 C103,126.5 107,127 113,126 C107,129.5 93,129.5 87,126Z" fill="${dark}"/>
      <path d="M87,126 C93,136 107,136 113,126 C107,129.5 93,129.5 87,126Z" fill="${lip}"/>
      <path d="M94,131.8 C98,133 102,133 106,131.8" fill="none" stroke="#fff" stroke-opacity=".3" stroke-width="1.6" stroke-linecap="round"/>`);
  }
}

function beard(l) {
  const c = l.hairColor, dark = shade(c, -0.2);
  const stache = `<path d="M86,124 C90,118 97,118.5 100,120.5 C103,118.5 110,118 114,124 C109,122.5 104,123 100,124 C96,123 91,122.5 86,124Z" fill="${dark}"/>`;
  switch (l.beard) {
    case "stubble": return `<path d="M63,104 C65,128 82,146 100,147 C118,146 135,128 137,104 C131,118 122,123 113,122 C106,119 94,119 87,122 C78,123 69,118 63,104Z" fill="${c}" opacity=".22"/>
      <path d="M86,124 C91,119 109,119 114,124 C108,122.5 92,122.5 86,124Z" fill="${c}" opacity=".3"/>`;
    case "mustache": return stache;
    case "goatee": return stache + `<path d="M91,136 C94,133.5 106,133.5 109,136 C109,143 104,147 100,147 C96,147 91,143 91,136Z" fill="${dark}"/>`;
    case "full": return `<path d="M61,100 C62,132 80,152 100,153 C120,152 138,132 139,100 C133,114 126,120 116,121 C108,118 92,118 84,121 C74,120 67,114 61,100Z" fill="url(#hairG)"/>
      <path d="M88,131 C94,137 106,137 112,131 C106,133.5 94,133.5 88,131Z" fill="${shade(c, -0.35)}" opacity=".6"/>` + stache;
    default: return "";
  }
}

function glasses(l) {
  if (l.glasses === "none") return "";
  if (l.glasses === "sunglasses") return `<g fill="#15171c" stroke="#15171c" stroke-width="2">
    <path d="M69,92 C69,89 97,89 97,92 C97,103 93,108 83,108 C73,108 69,103 69,92Z"/><path d="M131,92 C131,89 103,89 103,92 C103,103 107,108 117,108 C127,108 131,103 131,92Z"/>
    <path d="M97,93 C99,91.5 101,91.5 103,93" fill="none"/><path d="M69,93 L61,91 M131,93 L139,91" fill="none"/></g>
    <path d="M74,94 L80,94" stroke="#fff" stroke-opacity=".35" stroke-width="2.4" stroke-linecap="round"/><path d="M108,94 L114,94" stroke="#fff" stroke-opacity=".35" stroke-width="2.4" stroke-linecap="round"/>`;
  const lens = l.glasses === "round"
    ? `<circle cx="84" cy="97" r="12.5"/><circle cx="116" cy="97" r="12.5"/>`
    : `<rect x="70" y="88" width="28" height="18" rx="4"/><rect x="102" y="88" width="28" height="18" rx="4"/>`;
  return `<g fill="#fff" fill-opacity=".12" stroke="#1d1d22" stroke-width="2.2">${lens}</g>
    <g fill="none" stroke="#1d1d22" stroke-width="2.2"><path d="M96.5,95 C98.5,93 101.5,93 103.5,95"/><path d="M71.5,95 L61,92.5 M128.5,95 L139,92.5"/></g>`;
}

// hair: [behind the head, over the head]
function hair(l) {
  const c = l.hairColor, hl = shade(c, 0.35);
  const strands = d => `<path d="${d}" fill="none" stroke="${hl}" stroke-opacity=".35" stroke-width="1.6" stroke-linecap="round"/>`;
  const curls = (cx, cy, rx, ry, from, to, n, r) => Array.from({ length: n }, (_, i) => {
    const a = (from + (to - from) * i / (n - 1)) * Math.PI / 180;
    return `<circle cx="${(cx + rx * Math.cos(a)).toFixed(1)}" cy="${(cy + ry * Math.sin(a)).toFixed(1)}" r="${r + (i % 2) * 1.5}"/>`;
  }).join("");
  switch (l.hair) {
    case "crew": return ["", `<path d="M60,94 C55,55 75,35 100,35 C126,35 146,53 140,94 C138,79 134,69 128,63 C116,66 96,64 80,58 C72,66 64,77 60,94Z" fill="url(#hairG)"/>`
      + strands("M84,45 C92,42 104,41 114,43 M78,52 C88,49 100,49 110,51")];
    case "sidePart": return ["", `<path d="M58,96 C51,52 76,28 104,30 C133,30 151,52 142,96 C140,77 136,67 130,61 C114,59 96,57 76,50 C86,59 72,70 65,81 C61,86 59,90 58,96Z" fill="url(#hairG)"/>`
      + strands("M80,44 C95,36 116,36 132,46 M76,50 C92,44 112,44 128,52")];
    case "quiff": return ["", `<path d="M60,94 C56,58 68,41 82,37 C86,20 118,14 130,30 C143,39 147,62 140,94 C138,77 132,66 124,60 C108,64 90,58 80,56 C70,66 64,78 60,94Z" fill="url(#hairG)"/>`
      + strands("M88,34 C98,24 114,22 124,30 M84,42 C96,32 114,30 128,40")];
    case "buzz": return ["", `<path d="M61,90 C59,58 76,41 100,41 C124,41 141,58 139,90 C135,73 124,61 100,60 C76,61 65,73 61,90Z" fill="${c}" opacity=".85"/>`];
    case "curly": return ["", `<g fill="url(#hairG)">${curls(100, 74, 42, 34, 180, 360, 13, 9)}<path d="M60,90 C58,56 76,40 100,40 C124,40 142,56 140,90 C134,72 122,62 100,62 C78,62 66,72 60,90Z"/></g>`];
    case "afro": return [`<g fill="url(#hairG)">${curls(100, 78, 50, 46, 150, 390, 18, 15)}<ellipse cx="100" cy="76" rx="50" ry="44"/></g>`,
      `<path d="M62,88 C62,64 78,52 100,52 C122,52 138,64 138,88 C132,74 120,66 100,66 C80,66 68,74 62,88Z" fill="url(#hairG)"/>`];
    case "long": return [`<path d="M57,90 C50,38 150,38 143,90 L149,172 C132,180 68,180 51,172Z" fill="url(#hairG)"/>`,
      `<path d="M60,98 C54,50 80,35 100,35 C124,35 148,50 140,98 C136,74 124,62 106,57 C104,64 97,63 93,58 C78,63 64,75 60,98Z" fill="url(#hairG)"/>`
      + strands("M92,42 C80,48 70,62 66,80 M110,42 C124,48 132,62 136,80")];
    case "wavy": return [`<path d="M57,90 C50,38 150,38 143,90 C150,110 142,120 150,138 C156,152 146,164 150,174 C130,182 70,182 50,174 C54,164 44,152 50,138 C58,120 50,110 57,90Z" fill="url(#hairG)"/>`,
      `<path d="M60,100 C52,50 80,34 100,34 C124,34 150,50 140,100 C138,76 128,63 110,58 C98,66 80,62 70,70 C64,78 61,88 60,100Z" fill="url(#hairG)"/>`
      + strands("M84,42 C74,50 66,64 64,80 M116,42 C128,50 134,62 137,78")];
    case "bob": return [`<path d="M55,92 C49,42 151,42 145,92 C147,112 147,128 141,140 C128,146 72,146 59,140 C53,128 53,112 55,92Z" fill="url(#hairG)"/>`,
      `<path d="M59,88 C57,50 79,37 100,37 C121,37 143,50 141,88 C124,78 76,78 59,88Z" fill="url(#hairG)"/>` + strands("M80,46 C92,40 108,40 120,46")];
    case "bun": return [`<circle cx="100" cy="30" r="17" fill="url(#hairG)"/>`,
      `<path d="M60,92 C56,54 78,38 100,38 C122,38 144,54 140,92 C136,72 124,60 100,58 C76,60 64,72 60,92Z" fill="url(#hairG)"/>` + strands("M78,50 C90,44 110,44 122,50")];
    case "locs": return [`<g fill="url(#hairG)">${[52, 60, 68, 132, 140, 148].map(x => `<rect x="${x - 5}" y="60" width="10" height="${x < 100 ? 110 - (x - 52) : 110 - (148 - x)}" rx="5"/>`).join("")}</g>`,
      `<g fill="url(#hairG)"><path d="M58,94 C54,54 76,36 100,36 C124,36 146,54 142,94 C136,72 124,60 100,58 C76,60 64,72 58,94Z"/>${curls(100, 60, 38, 20, 190, 350, 9, 6)}</g>`];
    case "beanie": {
      const hat = l.outfitColor === "ffffff" || l.outfitColor === "e9e9ee" ? "c0392b" : l.outfitColor;
      return ["", `<path d="M58,82 C56,42 78,24 100,24 C122,24 144,42 142,82Z" fill="#${hat}"/>
        <path d="M58,82 C56,42 78,24 100,24 C122,24 144,42 142,82Z" fill="url(#shadeTop)"/>
        <rect x="55" y="72" width="90" height="16" rx="8" fill="${shade(hat, -0.18)}"/>
        ${[66, 76, 86, 96, 106, 116, 126, 136].map(x => `<path d="M${x},74 L${x},86" stroke="${shade(hat, -0.32)}" stroke-width="1.5"/>`).join("")}
        <circle cx="100" cy="22" r="8" fill="${shade(hat, 0.2)}"/>`];
    }
    case "hijab": {
      const cloth = shade(l.outfitColor, l.outfitColor === "ffffff" ? -0.08 : 0.12);
      return [`<path d="M48,98 C42,36 158,36 152,98 C152,136 148,168 150,200 L50,200 C52,168 48,136 48,98Z" fill="${cloth}"/>
        <path d="M48,98 C42,36 158,36 152,98 C152,136 148,168 150,200 L50,200 C52,168 48,136 48,98Z" fill="url(#shadeTop)"/>`,
        `<path d="M61,92 C60,58 78,44 100,44 C122,44 140,58 139,92 C134,70 120,58 100,58 C80,58 66,70 61,92Z" fill="${cloth}"/>
         <path d="M61,92 C60,58 78,44 100,44 C122,44 140,58 139,92" fill="none" stroke="${shade(cloth, -0.12)}" stroke-width="1.5"/>`];
    }
    default: return ["", ""];  // bald
  }
}

function outfit(l) {
  const c = "#" + l.outfitColor, dark = shade(l.outfitColor, -0.18), line = shade(l.outfitColor, -0.3);
  const L = { man: 18, woman: 32, nonbinary: 25 }[l.gender], R = 200 - L;
  const shape = `M${L},200 C${L + 2},172 ${L + 24},158 74,154 L126,154 C${R - 24},158 ${R - 2},172 ${R},200Z`;
  const body = `<path d="${shape}" fill="${c}"/><path d="${shape}" fill="url(#shadeBody)"/>`;
  switch (l.outfit) {
    case "vneck": return body + `<path d="M82,154 L100,182 L118,154Z" fill="url(#neckG)"/><path d="M82,154 L100,182 L118,154" fill="none" stroke="${dark}" stroke-width="3"/>`;
    case "hoodie": return `<path d="M64,150 C64,134 136,134 136,150 L130,170 L70,170Z" fill="${dark}"/>` + body
      + `<path d="M76,154 C84,172 116,172 124,154" fill="none" stroke="${dark}" stroke-width="5"/>
         <path d="M92,166 L90,190 M108,166 L110,190" stroke="#f4f4f4" stroke-width="2.4" stroke-linecap="round"/>`;
    case "collar": return body + `<path d="M84,154 C90,164 110,164 116,154" fill="${dark}"/>
      <path d="M80,152 L96,168 L88,176 L76,158Z M120,152 L104,168 L112,176 L124,158Z" fill="${shade(l.outfitColor, 0.25)}" stroke="${line}" stroke-width="1.2"/>
      ${[178, 190].map(y => `<circle cx="100" cy="${y}" r="1.8" fill="${line}"/>`).join("")}`;
    case "sweater": return body + `<path d="M80,154 C86,168 114,168 120,154" fill="none" stroke="${dark}" stroke-width="7"/>
      <path d="M80,154 C86,168 114,168 120,154" fill="none" stroke="${line}" stroke-width="1" stroke-dasharray="1.5 2.5"/>`;
    case "jacket": { const sides = `M${L},200 C${L + 2},172 ${L + 24},158 74,154 L86,154 L100,200Z M${R},200 C${R - 2},172 ${R - 24},158 126,154 L114,154 L100,200Z`;
      return `<path d="${shape}" fill="#f2f2f2"/><path d="${sides}" fill="${c}"/><path d="${sides}" fill="url(#shadeBody)"/>
      <path d="M74,154 L92,178 L86,154 M126,154 L108,178 L114,154" fill="${dark}"/>`; }
    default: return body + `<path d="M80,154 C86,168 114,168 120,154" fill="none" stroke="${dark}" stroke-width="3.5"/>`;
  }
}

// view: "full" (the picture), "head" (zoomed on hair), "face" (zoomed on eyes/mouth)
export function drawCharacter(look, view = "full") {
  const l = cleanLook(look), skin = "#" + l.skin, [hairBack, hairFront] = hair(l);
  const box = { full: "0 0 200 200", head: "22 6 156 156", face: "58 66 84 84" }[view] || "0 0 200 200";
  const ear = x => `<ellipse cx="${x}" cy="99" rx="7.5" ry="11" fill="url(#skinG)"/>
    <path d="M${x < 100 ? x + 2 : x - 2},93 C${x < 100 ? x - 3 : x + 3},96 ${x < 100 ? x - 3 : x + 3},103 ${x < 100 ? x + 1 : x - 1},106" fill="none" stroke="${shade(l.skin, -0.25)}" stroke-width="1.5" stroke-linecap="round"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}" width="256" height="256">
  <defs>
    <radialGradient id="skinG" cx="45%" cy="38%" r="70%"><stop offset="0" stop-color="${shade(l.skin, 0.12)}"/><stop offset=".6" stop-color="${skin}"/><stop offset="1" stop-color="${shade(l.skin, -0.14)}"/></radialGradient>
    <linearGradient id="neckG" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${shade(l.skin, -0.3)}"/><stop offset=".45" stop-color="${shade(l.skin, -0.1)}"/><stop offset="1" stop-color="${shade(l.skin, -0.06)}"/></linearGradient>
    <linearGradient id="hairG" x1="0" y1="0" x2=".3" y2="1"><stop offset="0" stop-color="${shade(l.hairColor, 0.16)}"/><stop offset=".55" stop-color="#${l.hairColor}"/><stop offset="1" stop-color="${shade(l.hairColor, -0.22)}"/></linearGradient>
    <radialGradient id="iris" cx="45%" cy="40%" r="60%"><stop offset="0" stop-color="${shade(l.eyeColor, 0.35)}"/><stop offset="1" stop-color="#${l.eyeColor}"/></radialGradient>
    <linearGradient id="shadeBody" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".14"/><stop offset="1" stop-color="#000" stop-opacity=".16"/></linearGradient>
    <linearGradient id="shadeTop" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".18"/><stop offset="1" stop-color="#000" stop-opacity=".12"/></linearGradient>
    <radialGradient id="bgG" cx="50%" cy="35%" r="75%"><stop offset="0" stop-color="${shade(l.bg, 0.25)}"/><stop offset="1" stop-color="#${l.bg}"/></radialGradient>
  </defs>
  <rect x="-10" y="-10" width="220" height="220" fill="url(#bgG)"/>
  ${outfit(l)}
  ${hairBack}
  <path d="M85,126 L85,158 C92,166 108,166 115,158 L115,126Z" fill="url(#neckG)"/>
  ${l.hair === "hijab" ? "" : ear(61) + ear(139)}
  <path d="${FACES[l.face]}" fill="url(#skinG)"/>
  <path d="${FACES[l.face]}" fill="none" stroke="${shade(l.skin, -0.18)}" stroke-width="1" opacity=".6"/>
  <ellipse cx="77" cy="113" rx="8" ry="5" fill="#ff6b6b" opacity=".13"/><ellipse cx="123" cy="113" rx="8" ry="5" fill="#ff6b6b" opacity=".13"/>
  ${beard(l)}
  ${nose(l)}
  ${mouth(l)}
  ${eye(84, false, l, "L")}${eye(116, true, l, "R")}
  <g fill="${shade(l.hairColor, l.hairColor === "f2f0ec" || l.hairColor === "c9c4bf" ? -0.25 : -0.05)}">
    <path transform="translate(84,97)" d="${BROWS[l.brows]}"/><path transform="translate(116,97) scale(-1,1)" d="${BROWS[l.brows]}"/>
  </g>
  ${hairFront}
  ${glasses(l)}
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
