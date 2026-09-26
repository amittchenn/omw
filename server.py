"""
The backend the web app talks to. Run with:  uvicorn server:app --reload
Then open http://127.0.0.1:8000/docs to try every endpoint in the browser.
"""
import math
import os
import random
from datetime import date, datetime, timedelta, timezone
import re
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from calendar_feed import build_ics, hangouts_for_token
from places import details, place_name, search, search_places, suggest
from predictor import HISTORY, learn_from, predict_departure
from schedule import clean_blocks, demo_busy, find_times, parse_schedule
from travel import MODES, route, travel_minutes
from weather import hours_around, weather_at, weather_now

app = FastAPI(title="Hangout API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/static", StaticFiles(directory="web"), name="static")  # serves web/auth.js, web/firebase-config.js



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
HOME_KM = {"walking": (0.8, 2.5), "cycling": (1.5, 5), "driving": (3, 10), "transit": (2, 8)}


def demo_home(user_id, mode, venue):
    """A made-up home near the venue, the same every time for the same person."""
    rng = random.Random(user_id)
    km, angle = rng.uniform(*HOME_KM[mode]), rng.uniform(0, 2 * math.pi)
    lat = venue[0] + km * math.cos(angle) / 111
    lng = venue[1] + km * math.sin(angle) / (111 * math.cos(math.radians(venue[0])))
    return [round(lat, 5), round(lng, 5)]


@app.get("/")
def home_page():
    return FileResponse("web/index.html")


@app.get("/config")
def config():
    # public Mapbox token (starts with pk.) so the page can draw map tiles
    return {"mapbox_token": os.getenv("MAPBOX_TOKEN", "")}


@app.get("/places")
def places(q: str, lat: float, lng: float):
    # search real places by name, closest to where the map is looking
    return search_places(q, lat, lng)


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
            home = g.home if g.home and len(g.home) == 2 else demo_home(uid, usual, req.venue)
            label = "New here" if g.home else "New here · no home set"
        elif uid in set(PEOPLE.user_id):
            person = PEOPLE[PEOPLE.user_id == uid].iloc[0]
            name, usual, label = person["name"], person.travel_mode, person.label
            home = demo_home(uid, usual, req.venue)
        else:
            raise HTTPException(400, f"Unknown person '{uid}'.")
        mode = req.modes.get(uid) if req.modes.get(uid) in MODES else usual  # picked for this plan, or how they usually go
        minutes, path, source = route(tuple(home), tuple(req.venue), mode, arrive_by)
        r = predict_departure(uid, req.start_time, minutes, mode, req.hangout_type,
                              raining, group_size=req.group_size or len(req.user_ids))
        if uid in guests:
            # a real person: no guessing until they've checked in once, then their own habits take over
            habits = guests[uid].habits[-30:]
            p50, p90 = learn_from(habits, r["typical_delay_min"], r["bad_day_delay_min"])
            start = datetime.fromisoformat(req.start_time)
            r.update(typical_delay_min=round(p50, 1), bad_day_delay_min=round(p90, 1), hangouts_in_history=len(habits),
                     learning=not habits,
                     alert_time=(start - timedelta(minutes=minutes + max(p90, 0))).isoformat(timespec="minutes"))
            label = "Learning · Maps time for now" if not habits else f"Learned from {len(habits)} check-in{'s' * (len(habits) > 1)}"
        results.append({**r, "name": name, "label": label, "home": home, "route": path,
                        "travel_mode": mode, "travel_source": source})
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
