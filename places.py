"""
Find places by name ("Klaus Advanced Computing Building") and name a clicked spot.
Uses Mapbox search first, then OpenStreetMap (good for campus buildings) to fill gaps.
"""
import requests

from travel import TOKEN

MAPBOX = "https://api.mapbox.com/search/searchbox/v1"
OSM = "https://nominatim.openstreetmap.org"
OSM_HEADERS = {"User-Agent": "hangout-planner-hackathon"}  # OpenStreetMap asks apps to identify themselves


def _mapbox_search(q, lat, lng):
    r = requests.get(f"{MAPBOX}/forward", timeout=5, params={
        "q": q, "proximity": f"{lng},{lat}", "limit": 5, "access_token": TOKEN})
    r.raise_for_status()
    out = []
    for f in r.json()["features"]:
        p = f["properties"]
        out.append({"name": p["name"], "address": p.get("full_address") or p.get("place_formatted", ""),
                    "lat": p["coordinates"]["latitude"], "lng": p["coordinates"]["longitude"]})
    return out


def _osm_search(q, lat, lng):
    box = f"{lng - 0.3},{lat + 0.3},{lng + 0.3},{lat - 0.3}"  # prefer results near the map, but don't require it
    r = requests.get(f"{OSM}/search", headers=OSM_HEADERS, timeout=5, params={
        "q": q, "format": "jsonv2", "limit": 5, "viewbox": box})
    r.raise_for_status()
    return [{"name": p.get("name") or p["display_name"].split(",")[0],
             "address": p["display_name"], "lat": float(p["lat"]), "lng": float(p["lon"])} for p in r.json()]


def search_places(q, lat, lng, limit=6):
    results, seen = [], set()
    for source in (_mapbox_search, _osm_search):
        try:
            for p in source(q, lat, lng):
                key = p["name"].lower()
                if key not in seen:
                    seen.add(key)
                    results.append(p)
        except Exception:
            pass  # one source failing shouldn't break search
    return results[:limit]


def place_name(lat, lng):
    try:
        r = requests.get(f"{OSM}/reverse", headers=OSM_HEADERS, timeout=5, params={
            "lat": lat, "lon": lng, "format": "jsonv2", "zoom": 18})
        r.raise_for_status()
        p = r.json()
        return {"name": p.get("name") or p["display_name"].split(",")[0], "address": p["display_name"]}
    except Exception:
        return {"name": "Dropped pin", "address": f"{lat:.4f}, {lng:.4f}"}