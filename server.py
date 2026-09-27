"""
The backend the web app talks to. Run with:  uvicorn server:app --reload
Then open http://127.0.0.1:8000/docs to try every endpoint in the browser.
"""
import base64
import math
import os
import random
from datetime import date, datetime, timedelta, timezone
import re
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from starlette.concurrency import run_in_threadpool
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from avatar_ai import TooMany, make_avatar, ready as avatars_ready
from calendar_feed import build_ics, hangouts_for_token
from muse_features import fair_spot, plan_from_text
from places import details, place_name, search, search_places, suggest
from predictor import HISTORY, learn_from, predict_departure
from schedule import clean_blocks, demo_busy, find_times, parse_schedule
import traffic
from travel import MODES, directions, route, travel_minutes
from weather import hours_around, weather_at, weather_now

app = FastAPI(title="omw! API")
traffic.start_background()  # the driving traffic model: retrains every hour on the last 2 weeks of drives (traffic.py)
import retrain
retrain.start_background()  # the lateness model: retrains daily on real check-ins next to the simulated data (retrain.py)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/static", StaticFiles(directory="web"), name="static")  # serves web/auth.js, web/firebase-config.js


@app.middleware("http")
async def always_fresh(request, call_next):
    """The app's own files: the browser checks for a new version every time (a quick 304 if nothing changed), so after
    a deploy nobody ends up with a new file talking to a stale old one, which leaves buttons that don't respond."""
    response = await call_next(request)
    if request.url.path.startswith("/static/") or request.url.path == "/":
        response.headers["Cache-Control"] = "no-cache"
    return response



class DepartureRequest(BaseModel):
    user_id: str
    start_time: str                   # e.g. "2026-09-10T19:00"
    travel_mode: str = "driving"      # driving, walking, cycling, transit
    origin: Optional[list[float]] = None   # [lat, lng] where they are now
    venue: Optional[list[float]] = None    # [lat, lng] of the hangout
    travel_minutes: Optional[float] = None  # skip Mapbox by giving this directly
    hangout_type: str = "food"
    raining: bool = False
    came_from_event: bool = False
    planned_days_ahead: int = 2
    group_size: int = 4


@app.get("/health")
def health():
    return {"ok": True}


# --- demo people -------------------------------------------------------------
NAMES = ["Maya", "Jake", "Priya", "Leo", "Sofia", "Omar", "Chloe", "Ethan", "Aisha", "Noah", "Zoe", "Ben",
         "Lina", "Marcus", "Ivy", "Sam", "Nina", "Theo", "Ava", "Kai", "Rosa", "Dev", "Emma", "Luca"]
LABELS = {
    "always_early": "The Early Bird", "punctual": "Right On Time", "chronically_late": "Fashionably Late",
    "morning_struggler": "Not a Morning Person", "rain_hater": "Hates the Rain", "overbooked": "Always Busy",
    "improving": "Getting Better", "unpredictable": "Wild Card",
}
PEOPLE = HISTORY.groupby("user_id")[["persona", "travel_mode", "group_id"]].first().reset_index()
PEOPLE["name"] = [NAMES[i % len(NAMES)] for i in range(len(PEOPLE))]
PEOPLE["label"] = PEOPLE.persona.map(LABELS)
HOME_KM = (2, 6)  # someone with no home set: a made-up one this far away, whatever way they travel


def demo_home(user_id, mode, venue):
    """A made-up home near the venue, the same every time for the same person."""
    rng = random.Random(user_id)
    km, angle = rng.uniform(*HOME_KM), rng.uniform(0, 2 * math.pi)
    lat = venue[0] + km * math.cos(angle) / 111
    lng = venue[1] + km * math.sin(angle) / (111 * math.cos(math.radians(venue[0])))
    return [round(lat, 5), round(lng, 5)]


@app.get("/")
def home_page():
    return FileResponse("web/index.html")


# ---------- installing omw! on a phone (Add to Home Screen) ----------
# both live at the top of the site, so the installed app covers every page
@app.get("/manifest.webmanifest")
def manifest():
    return FileResponse("web/manifest.webmanifest", media_type="application/manifest+json")


@app.get("/sw.js")
def service_worker():
    return FileResponse("web/sw.js", media_type="text/javascript", headers={"Cache-Control": "no-cache"})


# ---------- Firebase sign-in page, served from omw!'s own address ----------
# Safari blocks sign-in that runs on a different site (yourproject.firebaseapp.com) and shows
# "Unable to process request due to missing initial state". auth.js points Firebase at this site instead,
# and these routes pass /__/auth/... and /__/firebase/... through to Firebase. The project comes from web/firebase-config.js.
def _firebase_host():
    try:
        found = re.search(r'projectId:\s*"([a-z0-9-]+)"', open("web/firebase-config.js").read())
    except OSError:
        found = None
    return f"https://{found.group(1)}.firebaseapp.com" if found and not found.group(1).startswith("PASTE") else None


PASS_HEADERS = ("content-type", "cache-control", "location", "expires", "etag", "last-modified", "content-security-policy")


@app.api_route("/__/{path:path}", methods=["GET", "POST"], include_in_schema=False)
async def firebase_auth_page(path: str, request: Request):
    host = _firebase_host()
    if not host or not path.startswith(("auth/", "firebase/")):
        raise HTTPException(404)
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() in ("content-type", "accept", "accept-language", "user-agent")}
    import requests  # only needed here
    r = await run_in_threadpool(lambda: requests.request(request.method, f"{host}/__/{path}", params=request.query_params,
                                                         data=body or None, headers=headers, timeout=10, allow_redirects=False))
    return Response(r.content, status_code=r.status_code,
                    headers={k: v for k, v in r.headers.items() if k.lower() in PASS_HEADERS})


@app.get("/config")
def config():
    # public Mapbox token (starts with pk.) so the page can draw map tiles.
    # google_maps_key shows the Google map inside the directions panel. Everyone who opens the page can see it,
    # so use a second key limited to your websites (GOOGLE_MAPS_BROWSER_KEY); the server key is only the fallback.
    return {"mapbox_token": os.getenv("MAPBOX_TOKEN", ""),
            "google_maps_key": os.getenv("GOOGLE_MAPS_BROWSER_KEY") or os.getenv("GOOGLE_MAPS_API_KEY", "")}


@app.get("/places")
def places(q: str, lat: float, lng: float):
    # search real places by name, closest to where the map is looking
    return search_places(q, lat, lng)


# directions like Google Maps: turn by turn (or which bus to take), trip time and distance
class DirectionsRequest(BaseModel):
    origin: list[float]            # [lat, lng]: where you are now, or your home
    venue: list[float]
    mode: str = "driving"
    start_time: Optional[str] = None      # the hangout's start (local time), so transit picks buses that get you there on time
    utc_offset_min: Optional[int] = None


@app.post("/directions")
def get_directions(req: DirectionsRequest):
    if len(req.origin) != 2 or len(req.venue) != 2:
        raise HTTPException(400, "origin and venue should be [lat, lng].")
    arrive_by = None
    if req.start_time and req.utc_offset_min is not None:
        arrive_by = datetime.fromisoformat(req.start_time[:16]).replace(tzinfo=timezone(timedelta(minutes=req.utc_offset_min)))
    return directions(tuple(req.origin), tuple(req.venue), req.mode if req.mode in MODES else "driving", arrive_by)


# ---------- Muse ----------
class AIPlanRequest(BaseModel):
    text: str
    friends: list[dict] = []       # [{"id", "name"}]
    categories: list[dict] = []    # [{"id", "name"}]
    now: str                       # your local time, "YYYY-MM-DDTHH:MM"
    lat: float
    lng: float


@app.post("/ai/plan")
def ai_plan(req: AIPlanRequest):
    """Muse turns "boba with Priya and Sam Friday after 5" into who, what, when and where."""
    if not req.text.strip():
        raise HTTPException(400, "Say what you want to do.")
    try:
        friends = [{"id": str(f.get("id", ""))[:128], "name": str(f.get("name", ""))[:60]} for f in req.friends[:200]]
        cats = [{"id": str(c.get("id", ""))[:40], "name": str(c.get("name", ""))[:40]} for c in req.categories[:50]]
        return plan_from_text(req.text[:500], friends, cats, req.now, req.lat, req.lng)
    except Exception as e:
        raise HTTPException(502, f"Muse couldn't read that: {e}")


class AvatarRequest(BaseModel):
    traits: dict = {}              # {"skin", "hair", "hairColor", "hat", "glasses", "face", "extras": [...]}: only what was picked
    extra: str = ""                # "anything else", in their own words
    selfie: Optional[str] = None   # optional photo to base it on, "data:image/jpeg;base64,..."
    base: Optional[str] = None     # an avatar they already have, to change (traits/extra are then the changes)


@app.get("/ai/avatar")
def ai_avatar_ready():
    return {"ready": avatars_ready()}


@app.post("/ai/avatar")
async def ai_avatar(req: AvatarRequest, request: Request):
    """Draws a 3D cartoon avatar from the editor's choices (and a selfie if given), in the style of the ready-made ones."""
    selfie = None
    if req.selfie:
        if not req.selfie.startswith("data:image/jpeg;base64,") or len(req.selfie) > 1_500_000:
            raise HTTPException(400, "That photo didn't work. Try another one.")
        selfie = req.selfie.split(",", 1)[1]
    base = None
    if req.base:
        m = re.match(r"^data:(image/(?:png|webp|jpeg));base64,([A-Za-z0-9+/=]+)$", req.base)
        if not m or len(req.base) > 2_000_000:
            raise HTTPException(400, "Couldn't read that avatar. Make a new one instead.")
        base = (base64.b64decode(m.group(2)), m.group(1))
    ip = request.headers.get("x-forwarded-for", request.client.host if request.client else "?").split(",")[0].strip()
    try:
        png = await run_in_threadpool(make_avatar, req.traits, req.extra, selfie, ip, base)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except TooMany as e:
        raise HTTPException(429, str(e))
    except Exception as e:
        raise HTTPException(502, str(e))
    return {"image": "data:image/png;base64," + png}


class FairSpotRequest(BaseModel):
    query: str                     # what kind of place: "coffee", "cheap tacos open late"
    people: list[dict]             # [{"id", "name", "home": [lat, lng] or null, "mode"}]
    lat: float
    lng: float


@app.post("/ai/fair-spot")
def ai_fair_spot(req: FairSpotRequest):
    """Places near the middle of the group, everyone's trip to each, and Muse's pick of the fairest."""
    if not req.query.strip():
        raise HTTPException(400, "Say what kind of place.")
    people = []
    for p in req.people[:12]:
        home = p.get("home")
        ok = isinstance(home, list) and len(home) == 2 and all(isinstance(x, (int, float)) for x in home)
        people.append({"id": str(p.get("id", ""))[:128], "name": str(p.get("name", "Friend"))[:60],
                       "home": home if ok else None, "mode": p.get("mode") if p.get("mode") in MODES else "driving"})
    if sum(1 for p in people if p["home"]) < 1:
        raise HTTPException(400, "Nobody picked has a home set yet, so there's no way to tell what's fair.")
    try:
        return fair_spot(req.query, people, req.lat, req.lng)
    except Exception as e:
        raise HTTPException(502, f"Couldn't pick a spot: {e}")


# Google-Maps-style search. lat/lng = where the map is looking; here_lat/here_lng = where you are (for distances)
@app.get("/places/suggest")
def places_suggest(q: str, lat: float, lng: float, here_lat: Optional[float] = None, here_lng: Optional[float] = None,
                   session: Optional[str] = None):
    here = (here_lat, here_lng) if here_lat is not None and here_lng is not None else None
    return suggest(q[:100], lat, lng, here, session)


@app.get("/places/search")
def places_search(q: str, lat: float, lng: float, here_lat: Optional[float] = None, here_lng: Optional[float] = None):
    here = (here_lat, here_lng) if here_lat is not None and here_lng is not None else None
    return search(q[:100], lat, lng, here)


@app.get("/places/details")
def places_details(id: str, session: Optional[str] = None):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,300}", id):
        raise HTTPException(400, "Bad place id")
    try:
        return details(id, session)
    except Exception as e:
        raise HTTPException(502, f"Couldn't find that place: {e}")


@app.get("/place-name")
def name_of_place(lat: float, lng: float):
    # what's at this spot? used when someone clicks the map
    return place_name(lat, lng)


# one hangout as a calendar file, for the Apple Calendar button on each plan. iPhone Safari opens this straight
# into "Add to Calendar" (a file made inside the page just gets saved to Files). Everything it needs is in the link.
@app.get("/event.ics")
def one_event(id: str, title: str, start: str, dur: int = 120, place: str = "", address: str = "", alert: Optional[str] = None,
              by: str = "", tz: str = "UTC"):
    try:
        datetime.fromisoformat(start.replace("Z", "+00:00"))
        if alert:
            datetime.fromisoformat(alert.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, "Bad date.")
    h = {"id": re.sub(r"[^A-Za-z0-9_-]", "", id)[:64] or "hangout", "title": title[:200], "start": start, "durationMin": max(15, min(dur, 1440)),
         "venueName": place[:200], "address": address[:300], "createdByName": by[:100] or "a friend", "attendees": ["me"],
         "alerts": {"me": alert} if alert else {}, "tz": tz if re.fullmatch(r"[A-Za-z_]+(/[A-Za-z0-9_+-]+)*", tz) else "UTC"}
    try:
        ics = build_ics("me", [h])
    except Exception:  # an unknown time zone name
        ics = build_ics("me", [{**h, "tz": "UTC"}])
    # just the event: no calendar name or refresh settings, so it's added to a calendar you pick, not set up as a new one
    ics = "\r\n".join(l for l in ics.split("\r\n") if not l.startswith(("X-WR-", "REFRESH-INTERVAL", "X-PUBLISHED-TTL")))
    return Response(ics, media_type="text/calendar; charset=utf-8", headers={"Content-Disposition": 'inline; filename="hangout.ics"'})


@app.get("/calendar/{token}.ics")
def calendar(token: str):
    # someone's private calendar feed; Google/Apple Calendar fetch this link on their own schedule
    if not token.isalnum() or len(token) < 20:
        raise HTTPException(404, "No such calendar.")
    try:
        uid, hangouts = hangouts_for_token(token)
    except Exception as e:  # usually FIREBASE_SERVICE_ACCOUNT_JSON missing or pasted wrong on Render
        print(f"[calendar] feed failed: {type(e).__name__}: {e}")
        raise HTTPException(503, f"Calendar feed isn't set up on the server: {type(e).__name__}: {e}")
    if uid is None:
        raise HTTPException(404, "No such calendar.")
    return Response(build_ics(uid, hangouts), media_type="text/calendar; charset=utf-8",
                    headers={"Cache-Control": "no-cache"})


@app.get("/weather")
def weather(lat: float, lng: float, time: str):
    # right now at the spot, plus the forecast for the hangout's hour (and the hours around it), e.g. time=2026-09-28T19:00
    try:
        when = datetime.fromisoformat(time)
        return {**weather_at(lat, lng, when), "now": weather_now(lat, lng), "hours": hours_around(lat, lng, when)}
    except ValueError:
        raise HTTPException(400, "time should look like '2026-09-28T19:00'.")


@app.get("/users")
def users():
    return PEOPLE.to_dict("records")


LATE_AFTER_MIN = 5  # arriving more than this many minutes after the start counts as late


@app.get("/leaderboard/demo")
def demo_leaderboard(group_id: int):
    """Who's always late in a demo group, from their real (simulated) history: the same data the model learned from."""
    rows = HISTORY[HISTORY.group_id == group_id].sort_values("start_time")
    if rows.empty:
        raise HTTPException(404, f"No demo group {group_id}.")
    board = []
    for uid, h in rows.groupby("user_id"):
        person = PEOPLE[PEOPLE.user_id == uid].iloc[0]
        late = h.lateness_min
        recent, before = late.tail(10).mean(), late.iloc[-20:-10].mean()
        board.append({"user_id": uid, "name": person["name"], "label": person.label, "hangouts": len(h),
                      "on_time": int((late <= LATE_AFTER_MIN).sum()), "avg_late_min": round(float(late.mean()), 1),
                      "trend_min": round(float(recent - before), 1)})  # negative = getting better lately
    return sorted(board, key=lambda b: (-b["on_time"] / b["hangouts"], b["avg_late_min"]))


@app.post("/predict-departure")
def predict(req: DepartureRequest):
    # friendly errors instead of a crash
    if req.user_id not in set(HISTORY.user_id):
        raise HTTPException(400, f"Unknown user_id '{req.user_id}'. Try one from GET /users, like 'u05'.")
    try:
        datetime.fromisoformat(req.start_time)
    except ValueError:
        raise HTTPException(400, "start_time should look like '2026-09-10T19:00'.")
    if req.travel_minutes is None and not (req.origin and req.venue and len(req.origin) == 2 and len(req.venue) == 2):
        raise HTTPException(400, "Give either travel_minutes, or origin and venue as [lat, lng].")

    if req.travel_mode not in MODES:
        raise HTTPException(400, f"travel_mode should be one of {', '.join(MODES)}.")
    minutes, source = req.travel_minutes, "given"
    if minutes is None:
        minutes, source = travel_minutes(tuple(req.origin), tuple(req.venue), req.travel_mode)

    result = predict_departure(
        req.user_id, req.start_time, minutes, req.travel_mode, req.hangout_type,
        req.raining, req.came_from_event, req.planned_days_ahead, req.group_size,
    )
    result["travel_source"] = source
    return result


class Guest(BaseModel):
    # a real signed-in friend (not one of the demo people)
    user_id: str
    name: str
    travel_mode: str = "driving"
    home: Optional[list[float]] = None  # [lat, lng]; None if they haven't set one yet
    busy: list[dict] = []               # weekly busy blocks, e.g. {"day": "Mon", "start": "10:00", "end": "11:30"}
    habits: list[float] = []            # minutes after their alert they actually left, from their check-ins in omw


class PlanRequest(BaseModel):
    user_ids: list[str]
    start_time: str
    venue: list[float]
    hangout_type: str = "food"
    raining: Optional[bool] = None  # None = look up the forecast at the venue
    guests: list[Guest] = []
    modes: dict[str, str] = {}      # someone's way of getting there for THIS plan, e.g. {"u05": "transit"}
    utc_offset_min: Optional[int] = None  # the planner's time zone, so transit can find buses that arrive in time
    group_size: Optional[int] = None  # re-planning one person: how many are in the whole group


@app.post("/plan")
def plan(req: PlanRequest):
    """Everyone's alert time for one hangout, earliest first."""
    guests = {g.user_id: g for g in req.guests}
    raining = req.raining
    if raining is None:
        raining = weather_at(*req.venue, datetime.fromisoformat(req.start_time))["raining"]
    arrive_by = None
    if req.utc_offset_min is not None:
        arrive_by = datetime.fromisoformat(req.start_time).replace(tzinfo=timezone(timedelta(minutes=req.utc_offset_min)))
    results = []
    for uid in req.user_ids:
        if uid in guests:
            # real friends have no lateness history yet, so the model starts them at the group average
            g = guests[uid]
            name, usual = g.name, g.travel_mode if g.travel_mode in MODES else "driving"
            if not (g.home and len(g.home) == 2):
                raise HTTPException(400, f"{name} has no location yet.")
            home, label = g.home, "New here"
        elif uid in set(PEOPLE.user_id):
            person = PEOPLE[PEOPLE.user_id == uid].iloc[0]
            name, usual, label = person["name"], person.travel_mode, person.label
            home = demo_home(uid, usual, req.venue)
        else:
            raise HTTPException(400, f"Unknown person '{uid}'.")
        mode = req.modes.get(uid) if req.modes.get(uid) in MODES else usual  # picked for this plan, or how they usually go
        drive = {}  # driving: the traffic model's details (traffic at the leave time, weather, empty-road time)
        minutes, path, source = route(tuple(home), tuple(req.venue), mode, arrive_by or datetime.fromisoformat(req.start_time), drive)
        r = predict_departure(uid, req.start_time, minutes, mode, req.hangout_type,
                              raining, group_size=req.group_size or len(req.user_ids))
        if uid in guests:
            # a real person: no guessing until they've checked in once, then their own habits take over
            habits = [d for d in guests[uid].habits if -30 <= d <= 60][-30:]  # (check-ins saved before the app filtered them)
            p50, p90 = learn_from(habits, r["typical_delay_min"], r["bad_day_delay_min"])
            start = datetime.fromisoformat(req.start_time)
            r.update(typical_delay_min=round(p50, 1), bad_day_delay_min=round(p90, 1), hangouts_in_history=len(habits),
                     learning=not habits,
                     alert_time=(start - timedelta(minutes=minutes + max(p90, 0))).isoformat(timespec="minutes"))
            label = "Learning · Maps time for now" if not habits else f"Learned from {len(habits)} check-in{'s' * (len(habits) > 1)}"
        results.append({**r, "name": name, "label": label, "home": home, "route": path,
                        "travel_mode": mode, "travel_source": source, "traffic": drive or None})
    return sorted(results, key=lambda r: r["alert_time"])


class ScheduleText(BaseModel):
    text: str


@app.post("/parse-schedule")
def read_schedule(req: ScheduleText):
    """The AI turns a schedule written in plain English into busy blocks."""
    if not req.text.strip():
        return {"blocks": [], "read_by": None}
    try:
        blocks, source = parse_schedule(req.text)
        return {"blocks": blocks, "read_by": source}
    except Exception as e:
        raise HTTPException(502, f"Couldn't read that schedule: {e}")


class FindTimesRequest(BaseModel):
    user_ids: list[str]
    guests: list[Guest] = []
    from_date: str                # first day to consider, "YYYY-MM-DD"
    days: int = 7
    duration_min: int = 120
    earliest: str = "09:00"
    latest: str = "23:00"
    hangout_type: str = "food"
    now: Optional[str] = None             # the person's local time now; suggestions start an hour after it
    venue: Optional[list[float]] = None   # [lat, lng] for the forecast (the chosen spot, or where the map is)


@app.post("/find-times")
def suggest_times(req: FindTimesRequest):
    """The best times this week when everyone's free, ranked by how likely the group is to be on time."""
    guests = {g.user_id: g for g in req.guests}
    people = []
    for uid in req.user_ids:
        if uid in guests:
            g = guests[uid]
            people.append({"user_id": uid, "name": g.name, "travel_mode": g.travel_mode, "busy": clean_blocks(g.busy),
                           "habits": g.habits[-30:]})
        elif uid in set(PEOPLE.user_id):
            person = PEOPLE[PEOPLE.user_id == uid].iloc[0]
            people.append({"user_id": uid, "name": person["name"], "travel_mode": person.travel_mode, "busy": demo_busy(uid)})
        else:
            raise HTTPException(400, f"Unknown person '{uid}'.")
    if not people:
        raise HTTPException(400, "Pick at least one person.")
    not_before = datetime.fromisoformat(req.now) + timedelta(hours=1) if req.now else None
    forecast = (lambda t: weather_at(*req.venue, t)) if req.venue and len(req.venue) == 2 else None
    return find_times(people, date.fromisoformat(req.from_date), min(req.days, 14), req.duration_min,
                      req.earliest, req.latest, req.hangout_type, not_before=not_before, weather=forecast)
