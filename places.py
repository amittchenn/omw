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
    """What's at a tapped spot, like Google Maps: the place there (a cafe, a park, a building) if there is one within
    ~60 m (and its exact spot), otherwise the street address. Google first, then OpenStreetMap, then Mapbox."""
    if GOOGLE_KEY:
        try:  # a named place right there?
            data = _google("places:searchNearby", {
                "locationRestriction": {"circle": {"center": {"latitude": lat, "longitude": lng}, "radius": 60.0}},
                "maxResultCount": 5, "rankPreference": "DISTANCE"},
                "places.displayName,places.formattedAddress,places.location,places.types")
            for p in data.get("places", []):
                where = (p["location"]["latitude"], p["location"]["longitude"])
                if _meters((lat, lng), where) <= 60 and p.get("displayName", {}).get("text"):
                    return {"name": p["displayName"]["text"], "address": p.get("formattedAddress", ""), "lat": where[0], "lng": where[1],
                            "kind": "place"}
        except Exception as e:
            print(f"[places] Google nearby failed: {e}")
        try:  # no place: the street address
            r = requests.get("https://maps.googleapis.com/maps/api/geocode/json", timeout=5,
                             params={"latlng": f"{lat},{lng}", "key": GOOGLE_KEY})
            r.raise_for_status()
            res = [x for x in r.json().get("results", []) if "plus_code" not in x.get("types", [])]
            if res:
                full = res[0]["formatted_address"]
                return {"name": full.split(",")[0], "address": full, "kind": "address"}
        except Exception as e:
            print(f"[places] Google geocoding failed: {e}")
    try:
        r = requests.get(f"{OSM}/reverse", headers=OSM_HEADERS, timeout=5, params={
            "lat": lat, "lon": lng, "format": "jsonv2", "zoom": 18, "addressdetails": 1})
        r.raise_for_status()
        p = r.json()
        a = p.get("address", {})
        street = " ".join(x for x in (a.get("house_number"), a.get("road")) if x)
        return {"name": p.get("name") or street or p["display_name"].split(",")[0], "address": p["display_name"],
                "kind": "place" if p.get("name") else "address"}
    except Exception:
        pass
    if TOKEN:
        try:
            r = requests.get("https://api.mapbox.com/search/geocode/v6/reverse", timeout=5,
                             params={"longitude": lng, "latitude": lat, "access_token": TOKEN, "limit": 1})
            r.raise_for_status()
            f = r.json()["features"][0]["properties"]
            return {"name": f.get("name") or f.get("full_address", "").split(",")[0], "address": f.get("full_address", ""), "kind": "address"}
        except Exception:
            pass
    return {"name": f"{lat:.5f}, {lng:.5f}", "address": "", "kind": "coords"}


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
