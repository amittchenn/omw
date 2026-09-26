"""
Two things Muse does for a group:
1. plan_from_text: "boba with Priya and Sam Friday after 5" -> who, what, when and where, filled into the planner.
2. fair_spot: finds places near the middle of the group, gets everyone's real travel time to each one (Google Maps),
   then Muse picks the fairest one for what you asked for ("cheap", "open late") and says why.
Both fall back to plain rules if the AI is down, so the buttons always do something.
"""
import json
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

from places import search
from travel import route

PLAN_PROMPT = """You help friends plan a hangout. Turn their message into JSON only, no other text, in exactly this shape:
{"who": ["friend id", ...], "type": "category id or null", "place": "what to search on a map, or null",
 "when": "YYYY-MM-DDTHH:MM or null", "find_time": false, "summary": "one short friendly line saying what you set up",
 "note": "the invite message to send the group, written as the person inviting, casual, under 140 characters"}
Rules:
- who: ids from the friends list for everyone they mention. "everyone" or "all" means every friend. Never include the person writing.
- type: the closest category id from the list, or null.
- place: words for a map search, e.g. "boba", "Piedmont Park", "cheap tacos". null if they didn't say where or what kind of place.
- when: their local time. Use the current time given to work out "Friday", "tomorrow", "tonight" (tonight = 19:00 unless they say).
  "after 5" means 17:30. Weekday names mean the next one coming up. null if they didn't say a time.
- find_time: true if they ask to find a time that works, or say "when everyone's free".
"""

FAIR_PROMPT = """You pick the fairest place for a group to meet. Reply with JSON only: {"pick": <number>, "why": "<one or two short sentences>"}
Fair means nobody has a much longer trip than the others, and the longest trip is short. Also weigh what they asked for,
the rating, and whether it's open. In "why", mention the trip times (e.g. "everyone's within 15 minutes") and one reason it fits."""


def _json(reply):
    found = re.search(r"\{.*\}", reply or "", re.S)
    if not found:
        raise ValueError("The AI didn't reply with a plan.")
    return json.loads(found.group())


def _ask(prompt, system):
    from llm import ask  # only needed here, so the app runs without an AI key
    return ask(prompt, system=system, with_source=True)


# ---------- 1. plan from one sentence ----------
def plan_from_text(text, friends, categories, now, lat, lng):
    """friends: [{"id", "name"}], categories: [{"id", "name"}], now: the person's local time "YYYY-MM-DDTHH:MM"."""
    ids = {f["id"] for f in friends}
    cats = {c["id"] for c in categories}
    now_dt = datetime.fromisoformat(now[:16])
    prompt = (f"Current time: {now_dt:%A %Y-%m-%d %H:%M}\n"
              f"Friends (id: name):\n" + "\n".join(f"{f['id']}: {f['name']}" for f in friends) + "\n"
              f"Categories (id: name):\n" + "\n".join(f"{c['id']}: {c['name']}" for c in categories) + "\n"
              f"Message: {text[:500]}")
    reply, source = _ask(prompt, PLAN_PROMPT)
    data = _json(reply)

    who = [w for w in data.get("who") or [] if w in ids]
    # anyone named in the message counts too, even if the AI missed them
    lowered = text.lower()
    who += [f["id"] for f in friends if f["id"] not in who and f["name"] and re.search(rf"\b{re.escape(f['name'].lower())}\b", lowered)]

    when = None
    try:
        if data.get("when"):
            when = datetime.fromisoformat(str(data["when"])[:16]).strftime("%Y-%m-%dT%H:%M")
    except ValueError:
        pass

    place, options = None, []
    if data.get("place"):
        options = [p for p in search(str(data["place"])[:100], lat, lng) if p.get("lat") is not None][:3]
        place = options[0] if options else None

    return {"who": who, "type": data.get("type") if data.get("type") in cats else None, "when": when,
            "place": place, "place_options": options, "place_query": data.get("place"),
            "find_time": bool(data.get("find_time")) and not when,
            "summary": str(data.get("summary") or "")[:200], "note": str(data.get("note") or "")[:200], "read_by": source}


# ---------- 2. a fair spot for everyone ----------
def fair_spot(query, people, lat, lng, max_places=6):
    """people: [{"id", "name", "home": [lat, lng] or None, "mode"}]. lat/lng: where the map is looking (used if nobody has a home)."""
    homed = [p for p in people if p.get("home") and len(p["home"]) == 2]
    if homed:  # search around the middle of everyone's homes
        lat = sum(p["home"][0] for p in homed) / len(homed)
        lng = sum(p["home"][1] for p in homed) / len(homed)
    places = [p for p in search(query[:100], lat, lng, (lat, lng)) if p.get("lat") is not None][:max_places]
    if not places:
        return {"candidates": [], "pick": None, "why": f"Couldn't find any “{query}” near the middle of the group.", "center": [lat, lng]}

    # everyone's real trip to every place, all at once
    jobs = [(i, p) for i in range(len(places)) for p in homed]
    with ThreadPoolExecutor(max_workers=12) as pool:
        trips = list(pool.map(lambda job: route(tuple(job[1]["home"]), (places[job[0]]["lat"], places[job[0]]["lng"]), job[1].get("mode") or "driving"), jobs))
    for place in places:
        place["times"], place["sources"] = {}, set()
    for (i, person), (minutes, _, source) in zip(jobs, trips):
        places[i]["times"][person["id"]] = round(minutes)
        places[i]["sources"].add(source)
    for place in places:
        t = list(place["times"].values()) or [0]
        place.update(worst=max(t), average=round(sum(t) / len(t)), spread=max(t) - min(t), sources=sorted(place["sources"]))

    # without the AI: the shortest longest-trip, then the most even
    best = min(range(len(places)), key=lambda i: places[i]["worst"] + 0.5 * places[i]["spread"])
    pick, why, source = best, f"Longest trip is {places[best]['worst']} min, and trips differ by only {places[best]['spread']} min.", None
    try:
        names = {p["id"]: p["name"] for p in homed}
        table = "\n".join(
            f"{i}. {p['name']} ({p.get('type') or 'place'}; rating {p.get('rating') or '?'}; {'open now' if p.get('open') else 'closed now' if p.get('open') is False else 'hours unknown'}; "
            f"{p.get('price') or 'price unknown'}) trips: " + ", ".join(f"{names[u]} {m} min" for u, m in p["times"].items())
            for i, p in enumerate(places))
        reply, source = _ask(f"They asked for: {query}\nPlaces:\n{table}", FAIR_PROMPT)
        data = _json(reply)
        if isinstance(data.get("pick"), int) and 0 <= data["pick"] < len(places):
            pick, why = data["pick"], str(data.get("why") or why)[:300]
    except Exception as e:
        print(f"[muse] fair spot fell back to the simple rule: {e}")
    return {"candidates": places, "pick": pick, "why": why, "read_by": source, "center": [lat, lng],
            "missing_home": [p["name"] for p in people if p not in homed]}
