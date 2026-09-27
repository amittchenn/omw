"""
Travel time and the route line for each person.
Google Maps (Routes API, then the older Directions API) first, then Mapbox, then a rough straight-line estimate so the app never breaks.
Ways to get there: driving, walking, cycling, transit (transit needs Google; Mapbox has no bus/train routes).
Driving times for a hangout later on come from our own traffic model (traffic.py): Maps gives the drive on empty roads,
the model says how slow traffic will be when they have to leave. Every live Google drive time is saved to train it.
"""
import html
import math
import os
import re
from datetime import datetime, timedelta, timezone

import requests
from dotenv import load_dotenv

import traffic

load_dotenv()
GOOGLE_KEY = os.getenv("GOOGLE_MAPS_API_KEY")
TOKEN = os.getenv("MAPBOX_TOKEN")  # still used for the map itself and place search

MODES = ["driving", "walking", "cycling", "transit"]
GOOGLE_MODE = {"driving": "DRIVE", "walking": "WALK", "cycling": "BICYCLE", "transit": "TRANSIT"}
MAPBOX_MODE = {"driving": "driving-traffic", "walking": "walking", "cycling": "cycling"}
FALLBACK_KMH = {"driving": 30, "walking": 5, "cycling": 15, "transit": 18}


def _distance_km(a, b):
    # straight-line distance between two (lat, lng) points
    lat1, lng1, lat2, lng2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(h))


def decode_polyline(encoded):
    """Google's compressed route line -> [[lat, lng], ...]"""
    points, i, lat, lng = [], 0, 0, 0
    while i < len(encoded):
        for axis in (0, 1):
            shift = result = 0
            while True:
                b = ord(encoded[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += delta
            else:
                lng += delta
        points.append([lat / 1e5, lng / 1e5])
    return points


STEP_FIELDS = ",".join("routes.legs.steps." + x for x in [
    "navigationInstruction", "distanceMeters", "staticDuration", "travelMode", "transitDetails"])


def _google(origin, dest, mode, arrive_by, steps=False):
    body = {
        "origin": {"location": {"latLng": {"latitude": origin[0], "longitude": origin[1]}}},
        "destination": {"location": {"latLng": {"latitude": dest[0], "longitude": dest[1]}}},
        "travelMode": GOOGLE_MODE[mode],
        "polylineQuality": "OVERVIEW",
    }
    if mode == "driving":
        body["routingPreference"] = "TRAFFIC_AWARE"  # traffic right now; traffic.py works out the traffic at the leave time
    if mode == "transit" and arrive_by and arrive_by > datetime.now(timezone.utc):
        body["arrivalTime"] = arrive_by.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")  # buses that get you there on time
    r = requests.post("https://routes.googleapis.com/directions/v2:computeRoutes", json=body, timeout=8,
                      headers={"X-Goog-Api-Key": GOOGLE_KEY,
                               "X-Goog-FieldMask": "routes.duration,routes.staticDuration,routes.distanceMeters,routes.polyline.encodedPolyline"
                                                   + ("," + STEP_FIELDS if steps else "")})
    r.raise_for_status()
    routes = r.json().get("routes")
    if not routes:
        raise ValueError(f"Google found no {mode} route")
    best = routes[0]
    minutes, path = int(best["duration"].rstrip("s")) / 60, decode_polyline(best["polyline"]["encodedPolyline"])
    if mode == "driving":
        static = int(best.get("staticDuration", best["duration"]).rstrip("s")) / 60
        traffic.log_drive(origin, dest, minutes, static, best.get("distanceMeters"))
        _meta.update(live=minutes, static=static, meters=best.get("distanceMeters"))
    if not steps:
        return minutes, path
    return minutes, path, best.get("distanceMeters"), [_google_step(s) for leg in best.get("legs", []) for s in leg.get("steps", [])]


def _google_step(s):
    step = {"text": s.get("navigationInstruction", {}).get("instructions", ""), "maneuver": s.get("navigationInstruction", {}).get("maneuver", ""),
            "distance_m": s.get("distanceMeters"), "minutes": int(s.get("staticDuration", "0s").rstrip("s")) / 60}
    t = s.get("transitDetails")
    if t:
        line, stops, times = t.get("transitLine", {}), t.get("stopDetails", {}), t.get("localizedValues", {})
        step["transit"] = {"line": line.get("nameShort") or line.get("name", ""), "vehicle": line.get("vehicle", {}).get("name", {}).get("text", "Transit"),
                           "color": line.get("color", ""), "text_color": line.get("textColor", ""), "headsign": t.get("headsign", ""),
                           "from": stops.get("departureStop", {}).get("name", ""), "to": stops.get("arrivalStop", {}).get("name", ""),
                           "departs": times.get("departureTime", {}).get("time", {}).get("text", ""),
                           "arrives": times.get("arrivalTime", {}).get("time", {}).get("text", ""), "stops": t.get("stopCount")}
        step["text"] = step["text"] or f"{step['transit']['vehicle']} {step['transit']['line']} toward {step['transit']['headsign']}"
    return step


LEGACY_MODE = {"driving": "driving", "walking": "walking", "cycling": "bicycling", "transit": "transit"}


def _google_legacy(origin, dest, mode, arrive_by, steps=False):
    """Google's older Directions API: used when the Routes API isn't turned on for the key."""
    params = {"origin": f"{origin[0]},{origin[1]}", "destination": f"{dest[0]},{dest[1]}", "mode": LEGACY_MODE[mode], "key": GOOGLE_KEY}
    if mode == "driving":
        params["departure_time"] = "now"  # traffic-aware time
    if mode == "transit" and arrive_by and arrive_by > datetime.now(timezone.utc):
        params["arrival_time"] = int(arrive_by.timestamp())
    r = requests.get("https://maps.googleapis.com/maps/api/directions/json", params=params, timeout=8)
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "OK" or not data.get("routes"):
        raise ValueError(f"Directions API: {data.get('status')} {data.get('error_message', '')}".strip())
    best = data["routes"][0]
    leg = best["legs"][0]
    minutes = (leg.get("duration_in_traffic") or leg["duration"])["value"] / 60
    path = decode_polyline(best["overview_polyline"]["points"])
    if mode == "driving" and leg.get("duration_in_traffic"):
        static = leg["duration"]["value"] / 60
        traffic.log_drive(origin, dest, minutes, static, leg["distance"]["value"])
        _meta.update(live=minutes, static=static, meters=leg["distance"]["value"])
    if not steps:
        return minutes, path
    return minutes, path, leg["distance"]["value"], [_legacy_step(s) for s in leg["steps"]]


def _legacy_step(s):
    text = re.sub(r"<[^>]+>", " ", s.get("html_instructions", ""))
    step = {"text": re.sub(r"\s+", " ", html.unescape(text)).strip(), "maneuver": s.get("maneuver", ""),
            "distance_m": s["distance"]["value"], "minutes": s["duration"]["value"] / 60}
    t = s.get("transit_details")
    if t:
        line = t.get("line", {})
        step["transit"] = {"line": line.get("short_name") or line.get("name", ""), "vehicle": line.get("vehicle", {}).get("name", "Transit"),
                           "color": line.get("color", ""), "text_color": line.get("text_color", ""), "headsign": t.get("headsign", ""),
                           "from": t.get("departure_stop", {}).get("name", ""), "to": t.get("arrival_stop", {}).get("name", ""),
                           "departs": t.get("departure_time", {}).get("text", ""), "arrives": t.get("arrival_time", {}).get("text", ""),
                           "stops": t.get("num_stops")}
    return step


def _mapbox(origin, dest, mode, steps=False):
    coords = f"{origin[1]},{origin[0]};{dest[1]},{dest[0]}"  # Mapbox wants lng,lat
    r = requests.get(f"https://api.mapbox.com/directions/v5/mapbox/{MAPBOX_MODE[mode]}/{coords}",
                     params={"access_token": TOKEN, "geometries": "geojson", "steps": "true" if steps else "false"}, timeout=5)
    r.raise_for_status()
    best = r.json()["routes"][0]
    minutes, path = best["duration"] / 60, [[lat, lng] for lng, lat in best["geometry"]["coordinates"]]
    if mode == "driving":  # Mapbox's "typical" time isn't empty roads, but it's the closest it has
        _meta.update(live=minutes, static=best.get("duration_typical", best["duration"] / 1.1) / 60 if best.get("duration_typical") else minutes / 1.1,
                     meters=best.get("distance"))
    if not steps:
        return minutes, path
    return minutes, path, best.get("distance"), [
        {"text": s["maneuver"].get("instruction", ""), "maneuver": f"{s['maneuver'].get('type', '')} {s['maneuver'].get('modifier', '')}".strip(),
         "distance_m": s.get("distance"), "minutes": s.get("duration", 0) / 60} for leg in best["legs"] for s in leg["steps"]]


_meta = {}  # what the last driving lookup found: live (traffic now), static (empty roads), meters


def _with_traffic(minutes, origin, dest, arrive_by, info, source):
    """Driving: swap the time for the traffic model's, worked back from the arrival time (see traffic.py)."""
    live, static, meters = _meta.get("live"), _meta.get("static"), _meta.get("meters")
    if not static:  # no Maps (a straight-line guess): empty roads at ~45 km/h
        static, live = _distance_km(origin, dest) * 1.3 / 45 * 60, None
    km = (meters or _distance_km(origin, dest) * 1300) / 1000
    try:
        from weather import weather_at
        wx = lambda t: (lambda w: traffic.condition(w.get("code"), w.get("mm"), w.get("raining")) if w.get("known") else None)(
            weather_at(dest[0], dest[1], t))
        est = traffic.leave_time(static, arrive_by or datetime.now(timezone.utc), km, weather=wx if arrive_by else None, live_min=live)
    except Exception as e:
        print(f"[travel] traffic model failed: {e}")
        return minutes
    if info is not None:
        info.update(est, source=source)
    return est["minutes"]


def route(origin, dest, mode="driving", arrive_by=None, info=None):
    """origin and dest are (lat, lng). arrive_by: when they need to be there (timezone-aware, or naive = local time there).
    Returns (minutes, path as [[lat, lng], ...], source). For driving, `info` (a dict) gets the traffic model's details."""
    mode = mode if mode in MODES else "driving"
    if mode == "driving":
        _meta.clear()
        minutes, path, source = _route(origin, dest, mode, arrive_by)
        return _with_traffic(minutes, origin, dest, arrive_by, info, source), path, source
    return _route(origin, dest, mode, arrive_by)


def _aware(t):
    return t if t is None or t.tzinfo else t.replace(tzinfo=traffic.TZ)


def _route(origin, dest, mode, arrive_by):
    arrive_by = _aware(arrive_by)
    if GOOGLE_KEY:
        try:
            return (*_google(origin, dest, mode, arrive_by), "google")
        except Exception as e:
            print(f"[travel] Google {mode} failed: {e}")
        try:
            return (*_google_legacy(origin, dest, mode, arrive_by), "google")
        except Exception as e:
            print(f"[travel] Google Directions API {mode} failed: {e}")
    if TOKEN and mode in MAPBOX_MODE:
        try:
            return (*_mapbox(origin, dest, mode), "mapbox")
        except Exception as e:
            print(f"[travel] Mapbox {mode} failed: {e}")
    km = _distance_km(origin, dest) * 1.3  # roads aren't straight lines
    return km / FALLBACK_KMH[mode] * 60, [list(origin), list(dest)], "estimate"


def directions(origin, dest, mode="driving", arrive_by=None):
    """Turn-by-turn directions, like Google Maps: {minutes, distance_m, path, steps, source}."""
    mode = mode if mode in MODES else "driving"
    _meta.clear()
    d = _directions(origin, dest, mode, _aware(arrive_by))
    if mode == "driving":
        info = {}
        d["minutes"] = _with_traffic(d["minutes"], origin, dest, _aware(arrive_by), info, d["source"])
        d["traffic"] = info or None
    return d


def _directions(origin, dest, mode, arrive_by):
    if GOOGLE_KEY:
        try:
            minutes, path, meters, steps = _google(origin, dest, mode, arrive_by, steps=True)
            return {"minutes": minutes, "distance_m": meters, "path": path, "steps": steps, "source": "google"}
        except Exception as e:
            print(f"[travel] Google {mode} directions failed: {e}")
        try:
            minutes, path, meters, steps = _google_legacy(origin, dest, mode, arrive_by, steps=True)
            return {"minutes": minutes, "distance_m": meters, "path": path, "steps": steps, "source": "google"}
        except Exception as e:
            print(f"[travel] Google Directions API {mode} directions failed: {e}")
    if TOKEN and mode in MAPBOX_MODE:
        try:
            minutes, path, meters, steps = _mapbox(origin, dest, mode, steps=True)
            return {"minutes": minutes, "distance_m": meters, "path": path, "steps": steps, "source": "mapbox"}
        except Exception as e:
            print(f"[travel] Mapbox {mode} directions failed: {e}")
    minutes, path, source = _route(origin, dest, mode, arrive_by)
    return {"minutes": minutes, "distance_m": round(_distance_km(origin, dest) * 1300), "path": path, "steps": [], "source": source}


def travel_minutes(origin, dest, mode="driving", arrive_by=None, info=None):
    """origin and dest are (lat, lng). Returns (minutes, source)."""
    minutes, _, source = route(origin, dest, mode, arrive_by, info)
    return minutes, source


if __name__ == "__main__":
    # quick check: Georgia Tech to Piedmont Park every way
    for m in MODES:
        minutes, path, source = route((33.7756, -84.3963), (33.7851, -84.3738), m)
        print(f"{m:8} {minutes:5.1f} min  ({source}, {len(path)} points)")
