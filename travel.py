"""
Travel time and the route line for each person.
Google Maps (Routes API) first, then Mapbox, then a rough straight-line estimate so the app never breaks.
Ways to get there: driving, walking, cycling, transit (transit needs Google; Mapbox has no bus/train routes).
"""
import math
import os
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv

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


def _google(origin, dest, mode, arrive_by):
    body = {
        "origin": {"location": {"latLng": {"latitude": origin[0], "longitude": origin[1]}}},
        "destination": {"location": {"latLng": {"latitude": dest[0], "longitude": dest[1]}}},
        "travelMode": GOOGLE_MODE[mode],
        "polylineQuality": "OVERVIEW",
    }
    if mode == "driving":
        body["routingPreference"] = "TRAFFIC_AWARE"
    if mode == "transit" and arrive_by and arrive_by > datetime.now(timezone.utc):
        body["arrivalTime"] = arrive_by.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")  # buses that get you there on time
    r = requests.post("https://routes.googleapis.com/directions/v2:computeRoutes", json=body, timeout=8,
                      headers={"X-Goog-Api-Key": GOOGLE_KEY,
                               "X-Goog-FieldMask": "routes.duration,routes.polyline.encodedPolyline"})
    r.raise_for_status()
    routes = r.json().get("routes")
    if not routes:
        raise ValueError(f"Google found no {mode} route")
    best = routes[0]
    return int(best["duration"].rstrip("s")) / 60, decode_polyline(best["polyline"]["encodedPolyline"])


def _mapbox(origin, dest, mode):
    coords = f"{origin[1]},{origin[0]};{dest[1]},{dest[0]}"  # Mapbox wants lng,lat
    r = requests.get(f"https://api.mapbox.com/directions/v5/mapbox/{MAPBOX_MODE[mode]}/{coords}",
                     params={"access_token": TOKEN, "geometries": "geojson"}, timeout=5)
    r.raise_for_status()
    best = r.json()["routes"][0]
    return best["duration"] / 60, [[lat, lng] for lng, lat in best["geometry"]["coordinates"]]


def route(origin, dest, mode="driving", arrive_by=None):
    """origin and dest are (lat, lng). arrive_by: when they need to be there (timezone-aware), used for transit.
    Returns (minutes, path as [[lat, lng], ...], source)."""
    mode = mode if mode in MODES else "driving"
    if GOOGLE_KEY:
        try:
            return (*_google(origin, dest, mode, arrive_by), "google")
        except Exception as e:
            print(f"[travel] Google {mode} failed: {e}")
    if TOKEN and mode in MAPBOX_MODE:
        try:
            return (*_mapbox(origin, dest, mode), "mapbox")
        except Exception as e:
            print(f"[travel] Mapbox {mode} failed: {e}")
    km = _distance_km(origin, dest) * 1.3  # roads aren't straight lines
    return km / FALLBACK_KMH[mode] * 60, [list(origin), list(dest)], "estimate"


def travel_minutes(origin, dest, mode="driving", arrive_by=None):
    """origin and dest are (lat, lng). Returns (minutes, source)."""
    minutes, _, source = route(origin, dest, mode, arrive_by)
    return minutes, source


if __name__ == "__main__":
    # quick check: Georgia Tech to Piedmont Park every way
    for m in MODES:
        minutes, path, source = route((33.7756, -84.3963), (33.7851, -84.3738), m)
        print(f"{m:8} {minutes:5.1f} min  ({source}, {len(path)} points)")