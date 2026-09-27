"""
Driving traffic model: how slow the roads will be at the moment someone actually has to leave.

omw! tells people when to LEAVE, but Google Maps only predicts traffic for a departure time (and "arrive by" doesn't say
when you'd have to go). So we learn traffic ourselves and work backwards from the arrival time:

  1. Data: data/traffic_data.csv, one row per real Google Maps drive time
       timestamp,origin,destination,traffic_minutes,static_minutes,traffic_ratio,distance_meters
     traffic_ratio = traffic_minutes / static_minutes (1.20 = the drive takes 20% longer than on empty roads).
     New rows come from every driving route the app looks up (live traffic, right now), plus the optional collector below.
     Only the last 2 weeks are kept (TRAFFIC_WINDOW_DAYS), so the model never runs on outdated traffic.
     New readings are also saved in Firestore (collection "traffic", server-only) when the server has the Firebase service
     account (same as the calendar feed), because Render wipes files on every deploy; they're merged back in at startup.
  2. Weather: each row's hour gets the weather it had (Open-Meteo, free): clear, rain, heavy rain or snow.
  3. Training: for every day of the week and 15-minute slot, the typical ratio, from nearby times (weighted: same weekday >
     weekday/weekend > other days, closer in time and more recent count more). Thin slots lean on a wider average, so one odd
     reading can't swing it. Rain, heavy rain and snow are learned as extra slowdowns (starting from road-safety studies
     until there's enough rainy data), and so are trip lengths (long highway drives slow down more than short hops).
  4. Working backwards: arrive by 7:00 with a 20-minute empty-road drive -> try leaving 6:40, look up the traffic at 6:40
     (say 1.25 -> 25 min), try leaving 6:35, and so on until the leave time settles.
For a drive starting within the next 15 minutes Google's live traffic wins (it knows about today's accidents);
from 15 to 90 minutes out we blend the two; further ahead it's all the model.
All of this is for DRIVING only: nobody can change how fast traffic moves, so past drives predict future ones.
(How late each PERSON tends to leave is a separate model: predictor.py.)

  python traffic.py train                  # prune, fetch weather, train, print what it learned
  python traffic.py predict 2026-10-02T18:30 15    # leave time for a 15 km drive arriving then
  python traffic.py collect                # look up every route in the data once (needs GOOGLE_MAPS_API_KEY)
"""
import csv
import json
import math
import os
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import numpy as np
import requests
from dotenv import load_dotenv

load_dotenv()
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data", "traffic_data.csv")
WEATHER_CACHE = os.path.join(HERE, "data", "traffic_weather.csv")
MODEL = os.path.join(HERE, "models", "traffic.json")
COLUMNS = ["timestamp", "origin", "destination", "traffic_minutes", "static_minutes", "traffic_ratio", "distance_meters"]

WINDOW_DAYS = float(os.getenv("TRAFFIC_WINDOW_DAYS", "14"))                 # only this recent data is used (and kept)
TZ = ZoneInfo(os.getenv("TRAFFIC_TZ", "America/New_York"))                  # the area's clock: rush hour is local
AREA = tuple(float(x) for x in os.getenv("TRAFFIC_AREA", "33.749,-84.388").split(","))  # weather for address-only rows
COLLECT_EVERY_MIN = float(os.getenv("TRAFFIC_COLLECT_EVERY_MIN", "0"))      # 0 = off (each round costs Google calls)
COLLECT_DAILY_MAX = int(os.getenv("TRAFFIC_COLLECT_DAILY_MAX", "400"))

SLOT_MIN = 15
SLOTS = 24 * 60 // SLOT_MIN
BANDS_KM = [5, 15, 30]                     # trip lengths: <5, 5-15, 15-30, 30+ km
WEATHER_PRIOR = {"clear": 1.0, "rain": 1.10, "heavy": 1.20, "snow": 1.35}  # FHWA road-weather studies, until our data says otherwise
K_FINE, K_COARSE, K_WEATHER, K_BAND = 8.0, 12.0, 40.0, 60.0  # "pseudo-rows": how much evidence it takes to move off the fallback
SIGMA_FINE, SIGMA_COARSE = 40.0, 180.0     # minutes: how far a reading's influence spreads to nearby times

_lock = threading.Lock()
_model = None
_recent = {}                               # (origin, dest) rounded -> when last logged, so repeat lookups don't flood the data


# ---------- the data ----------
def _local(ts):
    t = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    return (t if t.tzinfo else t.replace(tzinfo=TZ)).astimezone(TZ)


def load_rows(prune=True):
    """Rows from the last WINDOW_DAYS, oldest first. Older rows are deleted from the file (the data stays fresh)."""
    if not os.path.exists(DATA):
        return []
    with _lock:
        with open(DATA, newline="") as f:
            raw = list(csv.DictReader(f))
        cutoff = datetime.now(TZ) - timedelta(days=WINDOW_DAYS)
        rows, keep = [], []
        for r in raw:
            try:
                t = _local(r["timestamp"])
                ratio = float(r.get("traffic_ratio") or 0) or float(r["traffic_minutes"]) / float(r["static_minutes"])
                meters = float(r.get("distance_meters") or 0)
            except (KeyError, ValueError, ZeroDivisionError):
                continue
            if t < cutoff:
                continue
            keep.append(r)
            if 0.3 < ratio < 5:  # skip broken readings
                rows.append({"t": t, "ratio": ratio, "km": meters / 1000, "origin": r["origin"], "destination": r["destination"]})
        if prune and len(keep) < len(raw):
            _write(keep)
    rows.sort(key=lambda r: r["t"])
    return rows


def _write(rows):
    tmp = DATA + ".tmp"
    with open(tmp, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    os.replace(tmp, DATA)


def log_drive(origin, dest, traffic_min, static_min, meters, when=None):
    """Save one live Google reading (origin/dest as "address" or (lat, lng)). Returns True if it was saved."""
    if not (traffic_min and static_min and static_min > 0):
        return False
    o = origin if isinstance(origin, str) else f"{origin[0]:.4f},{origin[1]:.4f}"
    d = dest if isinstance(dest, str) else f"{dest[0]:.4f},{dest[1]:.4f}"
    now = time.time()
    if now - _recent.get((o, d), 0) < 600:  # the same drive was just looked up
        return False
    _recent[(o, d)] = now
    row = {"timestamp": (when or datetime.now(TZ)).isoformat(), "origin": o, "destination": d,
           "traffic_minutes": round(traffic_min, 2), "static_minutes": round(static_min, 2),
           "traffic_ratio": round(traffic_min / static_min, 3), "distance_meters": int(meters or 0)}
    threading.Thread(target=_save_remote, args=(row,), daemon=True).start()
    with _lock:
        new = not os.path.exists(DATA)
        os.makedirs(os.path.dirname(DATA), exist_ok=True)
        with open(DATA, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=COLUMNS)
            if new:
                w.writeheader()
            w.writerow(row)
    return True


# ---------- Firestore copy (survives deploys) ----------
def _fs():
    try:
        from calendar_feed import firestore_client
        return firestore_client()
    except Exception:
        return None


def _save_remote(row):
    db = _fs()
    if db:
        try:
            db.collection("traffic").add({**row, "at": datetime.fromisoformat(row["timestamp"])})
        except Exception as e:
            print(f"[traffic] couldn't save to Firestore: {e}")


def sync():
    """Merge readings saved in Firestore into the CSV, and delete ones older than the window there too."""
    db = _fs()
    if not db:
        return 0
    from google.cloud.firestore_v1.base_query import FieldFilter  # (the keyword form; positional filters print a warning)
    cutoff = datetime.now(TZ) - timedelta(days=WINDOW_DAYS)
    try:
        have = set()
        if os.path.exists(DATA):
            with open(DATA, newline="") as f:
                have = {(r["timestamp"], r["origin"], r["destination"]) for r in csv.DictReader(f)}
        new = [d.to_dict() for d in db.collection("traffic").where(filter=FieldFilter("at", ">=", cutoff)).stream()]
        new = [r for r in new if (r.get("timestamp"), r.get("origin"), r.get("destination")) not in have]
        if new:
            with _lock:
                fresh = not os.path.exists(DATA)
                with open(DATA, "a", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
                    if fresh:
                        w.writeheader()
                    w.writerows(new)
        old = list(db.collection("traffic").where(filter=FieldFilter("at", "<", cutoff)).limit(400).stream())
        if old:
            batch = db.batch()
            for d in old:
                batch.delete(d.reference)
            batch.commit()
        return len(new)
    except Exception as e:
        print(f"[traffic] Firestore sync failed: {e}")
        return 0


# ---------- weather: what it was like when each reading was taken ----------
def condition(code=None, mm=None, raining=None):
    """Open-Meteo weather code / mm of rain in the hour -> clear | rain | heavy | snow."""
    code = int(code) if code is not None else None
    if code is not None and (71 <= code <= 77 or code in (56, 57, 66, 67, 85, 86)):
        return "snow"
    if (code is not None and code >= 95) or (mm or 0) >= 2.5 or (code is not None and code in (65, 82)):
        return "heavy"
    if raining or (mm or 0) >= 0.2 or (code is not None and (51 <= code <= 67 or 80 <= code <= 82)):
        return "rain"
    return "clear" if code is not None or mm is not None else None


def past_weather(fetch=True):
    """{"2026-09-26T13:00": "rain", ...} in local time, for the data's window. Cached in data/traffic_weather.csv."""
    hours = {}
    if os.path.exists(WEATHER_CACHE):
        with open(WEATHER_CACHE, newline="") as f:
            hours = {r["hour"]: r["condition"] for r in csv.DictReader(f)}
    newest = max(hours) if hours else ""
    stale = newest < (datetime.now(TZ) - timedelta(hours=2)).strftime("%Y-%m-%dT%H:00")
    if fetch and stale:
        try:
            r = requests.get("https://api.open-meteo.com/v1/forecast", timeout=8, params={
                "latitude": AREA[0], "longitude": AREA[1], "timezone": str(TZ), "hourly": "precipitation,weather_code",
                "past_days": int(math.ceil(WINDOW_DAYS)), "forecast_days": 1})
            r.raise_for_status()
            h = r.json()["hourly"]
            now = datetime.now(TZ).strftime("%Y-%m-%dT%H:00")
            for t, mm, code in zip(h["time"], h["precipitation"], h["weather_code"]):
                if t <= now and (mm is not None or code is not None):
                    hours[t] = condition(code, mm)
        except Exception as e:
            print(f"[traffic] couldn't get past weather: {e}")
    cutoff = (datetime.now(TZ) - timedelta(days=WINDOW_DAYS + 1)).strftime("%Y-%m-%dT%H:00")
    hours = {k: v for k, v in hours.items() if k >= cutoff and v}
    try:
        os.makedirs(os.path.dirname(WEATHER_CACHE), exist_ok=True)
        with open(WEATHER_CACHE, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["hour", "condition"])
            w.writerows(sorted(hours.items()))
    except OSError:
        pass
    return hours


# ---------- training ----------
def _band(km):
    return sum(km >= b for b in BANDS_KM)


def _kernel_table(mins, dows, y, w_row, sigma, k, prior):
    """[7][SLOTS] weighted average of y around each weekday+slot, shrunk toward `prior` ([7][SLOTS]) by k pseudo-rows."""
    table, n_eff = np.zeros((7, SLOTS)), np.zeros((7, SLOTS))
    centers = np.arange(SLOTS) * SLOT_MIN + SLOT_MIN / 2
    diff = np.abs(centers[:, None] - mins[None, :])
    diff = np.minimum(diff, 1440 - diff)                        # 11:50pm is next to 12:10am
    near = np.exp(-0.5 * (diff / sigma) ** 2)                   # [SLOTS, rows]
    weekend = dows >= 5
    for d in range(7):
        same_type = weekend == (d >= 5)
        day_w = np.where(dows == d, 1.0, np.where(same_type, 0.3, 0.05))
        w = near * (day_w * w_row)[None, :]
        s = w.sum(1)
        table[d] = (w @ y + k * prior[d]) / (s + k)
        n_eff[d] = s
    return table, n_eff


def train(fetch_weather=True, save=True):
    rows = load_rows()
    weather = past_weather(fetch_weather) if rows else {}
    now = datetime.now(TZ)
    m = {"trained_at": now.isoformat(timespec="seconds"), "rows": len(rows), "window_days": WINDOW_DAYS,
         "since": rows[0]["t"].isoformat(timespec="minutes") if rows else None, "slot_min": SLOT_MIN,
         "table": [[0.0] * SLOTS for _ in range(7)], "n_eff": [[0.0] * SLOTS for _ in range(7)],
         "weather": {c: math.log(v) for c, v in WEATHER_PRIOR.items()}, "weather_rows": {}, "bands": [0.0] * (len(BANDS_KM) + 1),
         "band_rows": [0] * (len(BANDS_KM) + 1), "spread": 0.12}
    if rows:
        y = np.log([r["ratio"] for r in rows])
        mins = np.array([r["t"].hour * 60 + r["t"].minute for r in rows], float)
        dows = np.array([r["t"].weekday() for r in rows])
        age = np.array([(now - r["t"]).total_seconds() / 86400 for r in rows])
        w_row = 0.5 ** (age / 7)                                # a week-old reading counts half
        band = np.array([_band(r["km"]) for r in rows])
        cond = np.array([weather.get(r["t"].strftime("%Y-%m-%dT%H:00")) or "" for r in rows])
        overall = float(np.average(y, weights=w_row))
        band_eff, wx_eff = np.zeros(len(BANDS_KM) + 1), dict(m["weather"])
        for _ in range(3):                                       # fit time, trip length and weather in turn
            adj = y - band_eff[band] - np.array([wx_eff.get(c, 0.0) if c else 0.0 for c in cond])
            flat = np.full((7, SLOTS), overall)
            coarse, _ = _kernel_table(mins, dows, adj, w_row, SIGMA_COARSE, K_COARSE, flat)
            fine, n_eff = _kernel_table(mins, dows, adj, w_row, SIGMA_FINE, K_FINE, coarse)
            slot = (mins // SLOT_MIN).astype(int)
            base = fine[dows, slot]
            resid = y - base
            wx_resid = resid - band_eff[band]
            clear = cond == "clear"
            ref = float(np.mean(wx_resid[clear])) if clear.sum() >= 30 else 0.0   # clear weather is the baseline
            for c, prior in WEATHER_PRIOR.items():
                if c == "clear":
                    continue
                pick = cond == c
                wx_eff[c] = float((np.sum(wx_resid[pick] - ref) + K_WEATHER * math.log(prior)) / (pick.sum() + K_WEATHER))
            b_resid = resid - np.array([wx_eff.get(c, 0.0) if c and c != "clear" else 0.0 for c in cond])
            for j in range(len(band_eff)):
                pick = band == j
                band_eff[j] = float(np.sum(b_resid[pick]) / (pick.sum() + K_BAND))
            band_eff -= np.average(band_eff, weights=np.bincount(band, minlength=len(band_eff)) + 1e-9)  # keep the time table the average trip
        m.update(table=np.round(fine, 4).tolist(), n_eff=np.round(n_eff, 1).tolist(), weather=wx_eff, bands=np.round(band_eff, 4).tolist(),
                 band_rows=np.bincount(band, minlength=len(band_eff)).tolist(),
                 weather_rows={c: int((cond == c).sum()) for c in WEATHER_PRIOR},
                 spread=round(float(np.sqrt(np.average((y - base - band_eff[band]) ** 2, weights=w_row))), 4))
    if save:
        os.makedirs(os.path.dirname(MODEL), exist_ok=True)
        with open(MODEL + ".tmp", "w") as f:
            json.dump(m, f)
        os.replace(MODEL + ".tmp", MODEL)
    global _model
    _model = m
    return m


def model():
    global _model
    if _model is None:
        try:
            with open(MODEL) as f:
                _model = json.load(f)
        except (OSError, ValueError):
            _model = train(fetch_weather=False)
    return _model


# ---------- predicting ----------
def _wall(t):
    """A time as the area's wall clock (naive). Aware times are converted; naive ones are taken as local already."""
    return t.astimezone(TZ).replace(tzinfo=None) if t.tzinfo else t


def ratio_at(when, km=10, cond="clear"):
    """How much slower than empty roads a drive starting at `when` is: (ratio, low, high)."""
    m, t = model(), _wall(when)
    pos = (t.hour * 60 + t.minute + t.second / 60 - SLOT_MIN / 2) / SLOT_MIN  # between two slot centers: blend them
    i = math.floor(pos)
    f = pos - i
    d0, s0 = (t.weekday() - (1 if i < 0 else 0)) % 7, i % SLOTS
    d1, s1 = (t.weekday() + (1 if i + 1 >= SLOTS else 0)) % 7, (i + 1) % SLOTS
    log_r = (1 - f) * m["table"][d0][s0] + f * m["table"][d1][s1]
    log_r += m["bands"][_band(km)] + (m["weather"].get(cond, 0.0) if cond and cond != "clear" else 0.0)
    r, s = math.exp(log_r), m.get("spread", 0.12)
    return max(0.5, r), max(0.5, r * math.exp(-0.84 * s)), r * math.exp(0.84 * s)  # the middle 60% of drives


def leave_time(static_min, arrive, km=10, weather=None, live_min=None, now=None):
    """Work backwards from the arrival time: the drive time and when to leave so you get there on time.
    static_min: the drive on empty roads. weather(t) -> clear|rain|heavy|snow for the hour you'd leave (optional).
    live_min: Google's traffic for leaving right now, trusted for a departure in the next 15 minutes, blended until 90."""
    arrive = _wall(arrive)
    now = _wall(now or datetime.now(TZ))
    leave, cond, r = arrive - timedelta(minutes=static_min), "clear", 1.0
    for _ in range(6):
        cond = (weather(leave) if weather else None) or "clear"
        r, lo, hi = ratio_at(leave, km, cond)
        new = arrive - timedelta(minutes=static_min * r)
        done = abs((new - leave).total_seconds()) < 30
        leave = new
        if done:
            break
    minutes, basis = static_min * r, "model"
    if live_min:
        ahead = (leave - now).total_seconds() / 60
        w = 1.0 if ahead <= 15 else 0.0 if ahead >= 90 else (90 - ahead) / 75
        if w > 0:
            minutes = w * live_min + (1 - w) * minutes
            basis = "live" if w == 1 else "blend"
            leave = arrive - timedelta(minutes=minutes)
    return {"minutes": round(minutes, 1), "leave": leave.isoformat(timespec="minutes"), "ratio": round(minutes / static_min, 3),
            "range_min": [round(static_min * lo, 1), round(static_min * hi, 1)], "weather": cond, "basis": basis,
            "static_min": round(static_min, 1)}


# ---------- collector: keep the data fresh on its own (optional, uses Google calls) ----------
def routes_to_watch():
    seen, out = set(), []
    for r in load_rows(prune=False):
        key = (r["origin"], r["destination"])
        if key not in seen and "," in r["origin"] and not r["origin"].replace(",", "").replace(".", "").replace("-", "").isdigit():
            seen.add(key)
            out.append(key)  # named places (from the original data), not one-off app lookups
    return out


def _google_now(origin, dest, key):
    place = lambda p: {"address": p} if isinstance(p, str) else {"location": {"latLng": {"latitude": p[0], "longitude": p[1]}}}
    r = requests.post("https://routes.googleapis.com/directions/v2:computeRoutes", timeout=8,
                      headers={"X-Goog-Api-Key": key, "X-Goog-FieldMask": "routes.duration,routes.staticDuration,routes.distanceMeters"},
                      json={"origin": place(origin), "destination": place(dest), "travelMode": "DRIVE", "routingPreference": "TRAFFIC_AWARE"})
    r.raise_for_status()
    best = r.json()["routes"][0]
    return int(best["duration"].rstrip("s")) / 60, int(best["staticDuration"].rstrip("s")) / 60, best.get("distanceMeters", 0)


_calls = []


def collect():
    key = os.getenv("GOOGLE_MAPS_API_KEY")
    if not key:
        print("[traffic] collect needs GOOGLE_MAPS_API_KEY")
        return 0
    saved = 0
    for o, d in routes_to_watch():
        while _calls and time.time() - _calls[0] > 86400:
            _calls.pop(0)
        if len(_calls) >= COLLECT_DAILY_MAX:
            print("[traffic] collector hit its daily limit")
            break
        _calls.append(time.time())
        try:
            traffic, static, meters = _google_now(o, d, key)
            _recent.pop((o, d), None)
            saved += log_drive(o, d, traffic, static, meters)
        except Exception as e:
            print(f"[traffic] {o} -> {d}: {e}")
    return saved


def start_background():
    """Retrain every hour (new readings from the app, drop ones older than 2 weeks); collect too if it's turned on."""
    def loop():
        while True:
            try:
                sync()
                if COLLECT_EVERY_MIN > 0:
                    print(f"[traffic] collected {collect()} readings")
                m = train()
                print(f"[traffic] trained on {m['rows']} drives from the last {m['window_days']:g} days")
            except Exception as e:
                print(f"[traffic] background: {e}")
            time.sleep(60 * (COLLECT_EVERY_MIN if COLLECT_EVERY_MIN > 0 else 60))
    threading.Thread(target=loop, daemon=True).start()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "train"
    if cmd == "collect":
        print(f"saved {collect()} readings")
    if cmd in ("train", "collect"):
        m = train()
        print(f"{m['rows']} drives since {m['since']} ({m['window_days']:g}-day window)")
        print("slowdown by weather:", {c: f"{math.exp(v):.2f}x ({m['weather_rows'].get(c, 0)} drives)" for c, v in m["weather"].items()})
        print("trip length:", {f"{a}-{b} km": f"{math.exp(v):.2f}x" for a, b, v in zip([0] + BANDS_KM, BANDS_KM + ["+"], m["bands"])})
        days = "Mon Tue Wed Thu Fri Sat Sun".split()
        for d in range(7):
            print(days[d], " ".join(f"{h:>2}h {math.exp(m['table'][d][h * 4 + 2]):.2f}" for h in range(6, 24, 2)))
    if cmd == "predict":
        arrive, km = datetime.fromisoformat(sys.argv[2]), float(sys.argv[3]) if len(sys.argv) > 3 else 15
        static = km * 1.3 / 45 * 60
        print(json.dumps(leave_time(static, arrive, km), indent=1))
