"""
Find places like Google Maps does, and name a clicked spot.
- suggest(): as you type, places and searches ("boba near me"), closest first, via Google Places.
- search(): a full search ("coffee", "pizza open now"): up to 12 places with rating, open now, price and distance.
- details(): where a suggested place is.
If Google isn't set up (no key, or the Places API isn't turned on), it falls back to Mapbox + OpenStreetMap.
"""
import math

import requests

from travel import GOOGLE_KEY, TOKEN

GOOGLE = "https://places.googleapis.com/v1"
NEARBY_M = 20000  # prefer places within 20 km of where the map is looking

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


# ---------- Google Places (New) ----------
def _meters(a, b):
    lat1, lng1, lat2, lng2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return round(6371000 * 2 * math.asin(math.sqrt(h)))


def _google(path, body=None, fields="", session=None):
    headers = {"X-Goog-Api-Key": GOOGLE_KEY, "X-Goog-FieldMask": fields}
    if body is None:
        r = requests.get(f"{GOOGLE}/{path}", headers=headers, params={"sessionToken": session} if session else None, timeout=5)
    else:
        r = requests.post(f"{GOOGLE}/{path}", headers=headers, json=body, timeout=5)
    r.raise_for_status()
    return r.json()


def _bias(lat, lng):
    return {"circle": {"center": {"latitude": lat, "longitude": lng}, "radius": NEARBY_M}}


def _fallback(q, lat, lng, here):
    return [{"kind": "place", "id": None, "name": p["name"], "address": p["address"], "lat": p["lat"], "lng": p["lng"],
             "distance_m": _meters(here, (p["lat"], p["lng"]))} for p in search_places(q, lat, lng)]


def suggest(q, lat, lng, here=None, session=None):
    """As you type. here = where you are (for distances); lat/lng = where the map is looking."""
    here = here or (lat, lng)
    if GOOGLE_KEY:
        try:
            body = {"input": q, "locationBias": _bias(lat, lng), "includeQueryPredictions": True,
                    "origin": {"latitude": here[0], "longitude": here[1]}}
            if session:
                body["sessionToken"] = session
            out = []
            for s in _google("places:autocomplete", body).get("suggestions", [])[:8]:
                if "placePrediction" in s:
                    p = s["placePrediction"]
                    fmt = p.get("structuredFormat", {})
                    out.append({"kind": "place", "id": p["placeId"], "name": fmt.get("mainText", {}).get("text") or p["text"]["text"],
                                "address": fmt.get("secondaryText", {}).get("text", ""), "distance_m": p.get("distanceMeters"),
                                "types": p.get("types", [])[:3]})
                elif "queryPrediction" in s:
                    out.append({"kind": "query", "text": s["queryPrediction"]["text"]["text"]})
            return out
        except Exception as e:
            print(f"[places] Google autocomplete failed, using Mapbox/OpenStreetMap: {e}")
    return _fallback(q, lat, lng, here)


def details(place_id, session=None):
    p = _google(f"places/{place_id}", fields="id,displayName,formattedAddress,location", session=session)
    return {"id": p["id"], "name": p["displayName"]["text"], "address": p.get("formattedAddress", ""),
            "lat": p["location"]["latitude"], "lng": p["location"]["longitude"]}


PRICE = {"PRICE_LEVEL_INEXPENSIVE": "$", "PRICE_LEVEL_MODERATE": "$$", "PRICE_LEVEL_EXPENSIVE": "$$$", "PRICE_LEVEL_VERY_EXPENSIVE": "$$$$"}


def search(q, lat, lng, here=None):
    """A full search, like pressing Enter in Google Maps."""
    here = here or (lat, lng)
    if GOOGLE_KEY:
        try:
            fields = ",".join("places." + f for f in ["id", "displayName", "formattedAddress", "location", "rating", "userRatingCount",
                                                      "currentOpeningHours.openNow", "primaryTypeDisplayName", "priceLevel"])
            data = _google("places:searchText", {"textQuery": q, "locationBias": _bias(lat, lng), "pageSize": 12}, fields)
            out = []
            for p in data.get("places", []):
                loc = (p["location"]["latitude"], p["location"]["longitude"])
                out.append({"kind": "place", "id": p["id"], "name": p["displayName"]["text"], "address": p.get("formattedAddress", ""),
                            "lat": loc[0], "lng": loc[1], "distance_m": _meters(here, loc), "rating": p.get("rating"),
                            "reviews": p.get("userRatingCount"), "open": p.get("currentOpeningHours", {}).get("openNow"),
                            "type": p.get("primaryTypeDisplayName", {}).get("text", ""), "price": PRICE.get(p.get("priceLevel"), "")})
            return out
        except Exception as e:
            print(f"[places] Google search failed, using Mapbox/OpenStreetMap: {e}")
    return _fallback(q, lat, lng, here)
