"""
AI avatars: turns the choices someone makes in the avatar editor (and an optional selfie) into a 3D cartoon head
in a glossy 3D emoji style, using OpenAI's image model.
Needs OPENAI_API_KEY. AVATAR_IMAGE_MODEL picks the model (default gpt-image-1), AVATAR_QUALITY low | medium | high.
"""
import base64
import os
import time
from collections import defaultdict, deque

import httpx
from dotenv import load_dotenv

load_dotenv()

MODEL = os.getenv("AVATAR_IMAGE_MODEL", "gpt-image-1")
QUALITY = os.getenv("AVATAR_QUALITY", "medium")
DAILY_LIMIT = int(os.getenv("AVATAR_DAILY_LIMIT", "200"))  # for the whole app, so a bug or a spammer can't run up the bill
PER_HOUR = int(os.getenv("AVATAR_PER_HOUR", "12"))          # for one person (by IP address)

# every choice the editor offers, and how it's described to the model (nothing else gets through)
CHOICES = {
    "skin": {"light": "very light skin", "fair": "fair skin", "tan": "light tan skin", "medium": "medium brown skin",
             "brown": "brown skin", "dark": "dark brown skin"},
    "hair": {"short": "short neat hair", "sidePart": "short side-parted hair", "curly": "short curly hair", "afro": "a big round afro",
             "spiky": "spiky messy hair", "buzz": "a buzz cut", "long": "long straight hair", "wavy": "long wavy hair",
             "bob": "a bob haircut with bangs", "bun": "hair in a top bun", "ponytail": "a high ponytail", "pigtails": "two pigtails",
             "braids": "box braids", "locs": "locs", "hijab": "a hijab covering the hair", "bald": "a bald head"},
    "hairColor": {"black": "black", "darkBrown": "dark brown", "brown": "brown", "blonde": "golden blonde", "ginger": "ginger orange",
                  "gray": "silver gray", "white": "white", "pink": "pastel pink", "purple": "purple", "blue": "bright blue",
                  "green": "green", "rainbow": "rainbow-dyed"},
    "hat": {"none": "no hat", "cap": "a baseball cap", "backwards": "a backwards baseball cap", "beanie": "a knit beanie",
            "catBeanie": "a beanie with cat ears", "beret": "a beret", "bucket": "a bucket hat", "cowboy": "a cowboy hat",
            "headband": "a rainbow sweatband", "headphones": "big headphones", "bow": "a big bow on top", "bunny": "bunny ears",
            "crown": "a little gold crown", "strawberry": "a strawberry hat"},
    "glasses": {"none": "no glasses", "round": "round glasses", "square": "square glasses", "sunglasses": "black sunglasses",
                "tinted": "rainbow-tinted shades", "stars": "star-shaped glasses", "hearts": "heart-shaped sunglasses"},
    "face": {"smile": "a friendly smile", "grin": "a big open-mouth grin", "tongue": "sticking the tongue out playfully",
             "wink": "a wink and a smile", "surprised": "a surprised 'o' mouth", "cool": "a cool confident smirk", "calm": "eyes closed, calm and happy"},
    "extras": {"freckles": "freckles", "beard": "a short beard", "mustache": "a mustache", "earrings": "small earrings",
               "lashes": "long eyelashes", "blush": "rosy cheeks", "noseRing": "a nose ring"},
}

STYLE = ("A single cute avatar in a glossy 3D emoji style: a chibi cartoon head like a high-end 3D sticker, a big rounded head "
         "with small rounded ears, soft studio lighting with a gentle rim light, smooth matte skin with rosy cheeks, chunky sculpted "
         "glossy hair, big friendly eyes with bright highlights, playful accessories that look like soft vinyl toys, vivid colors. Just the head and a little neck, centered, facing forward, the whole head, hair and hat visible "
         "(nothing cut off), on a fully transparent background. No text, no border, no body, no shadow on the ground.")

used = deque()                      # when each avatar was made today (whole app)
by_ip = defaultdict(deque)          # when each IP made its avatars this hour


class TooMany(Exception):
    pass


def ready():
    return bool(os.getenv("OPENAI_API_KEY"))


def describe(traits, extra, has_selfie):
    """The prompt: the style, then only the choices that were actually picked."""
    t = traits or {}
    lines = []
    if t.get("skin") in CHOICES["skin"]: lines.append(CHOICES["skin"][t["skin"]])
    hair = CHOICES["hair"].get(t.get("hair"))
    color = CHOICES["hairColor"].get(t.get("hairColor"))
    if hair and t.get("hair") not in ("bald", "hijab"): lines.append(f"{color} {hair}" if color else hair)
    elif hair: lines.append(hair)
    elif color: lines.append(f"{color} hair")
    for part in ("hat", "glasses", "face"):
        if t.get(part) in CHOICES[part]: lines.append(CHOICES[part][t[part]])
    extras = [CHOICES["extras"][x] for x in (t.get("extras") or [])[:7] if x in CHOICES["extras"]]
    if extras: lines.append(", ".join(extras))
    extra = " ".join(str(extra or "").split())[:100]
    prompt = STYLE
    if has_selfie:
        prompt += (" The image is a photo of the person this avatar is for: make it look like them (face shape, skin tone, "
                   "hair style and color, facial hair, glasses) but drawn in the avatar style, not photorealistic.")
    if lines: prompt += " The avatar has: " + "; ".join(lines) + "."
    if extra: prompt += f" Also: {extra}."
    if not lines and not has_selfie and not extra: prompt += " Make up a fun, unique look."
    return prompt


def describe_changes(changes, text):
    """Editing an avatar they already have: only what should change, everything else stays exactly the same."""
    c = changes or {}
    lines = []
    if c.get("skin") in CHOICES["skin"]: lines.append(f"make the skin {CHOICES['skin'][c['skin']]}")
    if c.get("hair") in CHOICES["hair"]: lines.append(f"change the hair to {CHOICES['hair'][c['hair']]}")
    if c.get("hairColor") in CHOICES["hairColor"]: lines.append(f"make the hair color {CHOICES['hairColor'][c['hairColor']]}")
    if c.get("hat") == "none": lines.append("remove the hat")
    elif c.get("hat") in CHOICES["hat"]: lines.append(f"change the headwear to {CHOICES['hat'][c['hat']]}")
    if c.get("glasses") == "none": lines.append("remove the glasses")
    elif c.get("glasses") in CHOICES["glasses"]: lines.append(f"change the eyewear to {CHOICES['glasses'][c['glasses']]}")
    if c.get("face") in CHOICES["face"]: lines.append(f"change the expression to {CHOICES['face'][c['face']]}")
    extras = [CHOICES["extras"][x] for x in (c.get("extras") or [])[:7] if x in CHOICES["extras"]]
    if extras: lines.append("add " + ", ".join(extras))
    text = " ".join(str(text or "").split())[:100]
    if text: lines.append(text)
    return ("Edit this avatar. Keep it the exact same character: same face, proportions, art style, lighting, pose, size, "
            "framing and transparent background. Only make these changes: " + "; ".join(lines or ["small touch-ups"]) + ".")


def check_limits(ip):
    now = time.time()
    while used and now - used[0] > 86400: used.popleft()
    q = by_ip[ip]
    while q and now - q[0] > 3600: q.popleft()
    if len(used) >= DAILY_LIMIT: raise TooMany("omw! has made all its avatars for today. Build your own for now.")
    if len(q) >= PER_HOUR: raise TooMany("That's a lot of avatars! Wait a bit before making more.")
    used.append(now); q.append(now)


def make_avatar(traits, extra="", selfie_b64=None, ip="?", base=None):
    """Returns a transparent PNG (base64) of the new avatar. base = (bytes, mime) of an avatar to change instead."""
    if not ready(): raise RuntimeError("AI avatars aren't set up yet (the server needs OPENAI_API_KEY).")
    check_limits(ip)
    prompt = describe_changes(traits, extra) if base else describe(traits, extra, bool(selfie_b64))
    headers = {"Authorization": f"Bearer {os.getenv('OPENAI_API_KEY')}"}
    data = {"model": MODEL, "prompt": prompt, "size": "1024x1024", "n": 1, "quality": QUALITY,
            "background": "transparent", "output_format": "png"}
    if base:  # change the one they have
        data = {k: str(v) for k, v in data.items()}
        data["input_fidelity"] = "high"  # keeps the character the same
        files = [("image[]", ("avatar." + base[1].split("/")[1], base[0], base[1]))]
        r = httpx.post("https://api.openai.com/v1/images/edits", headers=headers, data=data, files=files, timeout=150)
        if r.status_code == 400 and "input_fidelity" in r.text:
            data.pop("input_fidelity")
            r = httpx.post("https://api.openai.com/v1/images/edits", headers=headers, data=data, files=files, timeout=150)
    elif not selfie_b64:  # just the description
        r = httpx.post("https://api.openai.com/v1/images/generations", headers=headers, json=data, timeout=150)
    else:  # redraw their selfie as an avatar
        data = {k: str(v) for k, v in data.items()}
        data["input_fidelity"] = "high"  # keeps more of the person's face
        files = [("image[]", ("me.jpg", base64.b64decode(selfie_b64), "image/jpeg"))]
        r = httpx.post("https://api.openai.com/v1/images/edits", headers=headers, data=data, files=files, timeout=150)
        if r.status_code == 400 and "input_fidelity" in r.text:  # a model that doesn't take it
            data.pop("input_fidelity")
            r = httpx.post("https://api.openai.com/v1/images/edits", headers=headers, data=data, files=files, timeout=150)
    if r.status_code != 200:
        try: msg = r.json()["error"]["message"]
        except Exception: msg = r.text[:200]
        if "safety" in msg.lower() or "moderation" in msg.lower():
            raise ValueError("The AI wouldn't draw that one. Try different choices or another photo.")
        raise RuntimeError(f"The AI couldn't draw it: {msg}")
    return r.json()["data"][0]["b64_json"]
