"""
Find places like Google Maps does, and name a clicked spot.
- suggest(): as you type, places and searches ("boba near me"), closest first, via Google Places.
- search(): a full search ("coffee", "pizza open now"): up to 12 places with rating, open now, price and distance.
- details(): where a suggested place is.
If Google isn't set up (no key, or the Places API isn't turned on), it falls back to Mapbox + OpenStreetMap.
"""
import math
from datetime import datetime, timezone

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


def place_info(name, lat, lng):
    """A place's card, like Google Maps': up to 10 photos (all Google gives), rating, reviews, price, open now, type, phone and website.
    Found by name near the spot (taps on the map and Apple's search don't carry Google's id). Photos are given as
    names for /places/photo, so the Google key never leaves the server."""
    if not GOOGLE_KEY or not name.strip():
        return {}
    fields = ",".join("places." + f for f in ["id", "displayName", "location", "rating", "userRatingCount", "priceLevel",
                                              "currentOpeningHours.openNow", "primaryTypeDisplayName", "photos",
                                              "nationalPhoneNumber", "websiteUri", "googleMapsUri"])
    data = _google("places:searchText", {"textQuery": name[:100], "pageSize": 1,
                                          "locationBias": {"circle": {"center": {"latitude": lat, "longitude": lng}, "radius": 300}}}, fields)
    found = data.get("places") or []
    if not found:
        return {}
    p = found[0]
    loc = p.get("location") or {}
    if _meters((lat, lng), (loc.get("latitude", lat), loc.get("longitude", lng))) > 600:  # not the place you tapped
        return {}
    return {"name": p.get("displayName", {}).get("text", name), "rating": p.get("rating"), "reviews": p.get("userRatingCount"),
            "price": PRICE.get(p.get("priceLevel"), ""), "open": p.get("currentOpeningHours", {}).get("openNow"),
            "type": p.get("primaryTypeDisplayName", {}).get("text", ""), "phone": p.get("nationalPhoneNumber", ""),
            "website": p.get("websiteUri", ""), "maps": p.get("googleMapsUri", ""),
            "photos": [ph["name"] for ph in (p.get("photos") or [])[:10] if ph.get("name")]}


def air_quality(lat, lng, when=None):
    """Google's air quality at a spot, now or at an hour in the next 4 days: {aqi, category, color, pollutant}, or {}.
    Needs the Air Quality API on the Google key."""
    if not GOOGLE_KEY:
        return {}
    base = "https://airquality.googleapis.com/v1"
    body = {"location": {"latitude": lat, "longitude": lng}, "universalAqi": True, "languageCode": "en"}
    soon = when is None or abs((when - datetime.now(timezone.utc)).total_seconds()) < 2 * 3600
    if soon:
        r = requests.post(f"{base}/currentConditions:lookup", params={"key": GOOGLE_KEY}, json=body, timeout=6)
        r.raise_for_status()
        indexes = r.json().get("indexes") or []
    else:
        hour = when.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
        r = requests.post(f"{base}/forecast:lookup", params={"key": GOOGLE_KEY},
                          json={**body, "dateTime": hour.isoformat().replace("+00:00", "Z")}, timeout=6)
        r.raise_for_status()
        hours = r.json().get("hourlyForecasts") or []
        indexes = (hours[0].get("indexes") if hours else None) or []
    if not indexes:
        return {}
    i = indexes[0]
    c = i.get("color") or {}
    return {"aqi": i.get("aqi"), "category": i.get("category", ""), "pollutant": i.get("dominantPollutant", ""),
            "color": "#%02X%02X%02X" % tuple(round(255 * c.get(k, 0)) for k in ("red", "green", "blue"))}


def area_buzz(lat, lng, radius=450):
    """How lively the area around a spot is (Google's Places Aggregate API): how many restaurants, cafés and bars
    are open for business within a 5-minute walk. {count, radius} or {}."""
    if not GOOGLE_KEY:
        return {}
    body = {"insights": ["INSIGHT_COUNT"],
            "filter": {"locationFilter": {"circle": {"latLng": {"latitude": lat, "longitude": lng}, "radius": radius}},
                       "typeFilter": {"includedTypes": ["restaurant", "cafe", "bar", "bakery", "coffee_shop"]},
                       "operatingStatus": ["OPERATING_STATUS_OPERATIONAL"]}}
    r = requests.post("https://areainsights.googleapis.com/v1:computeInsights", headers={"X-Goog-Api-Key": GOOGLE_KEY},
                      json=body, timeout=6)
    r.raise_for_status()
    return {"count": int(r.json().get("count", 0)), "radius": radius}


def street_view(lat, lng, width=640, height=400):
    """Google Street View of a spot (the picture when a place has no photos), or None when there's no imagery there.
    Needs the Street View Static API turned on for the Google key."""
    if not GOOGLE_KEY:
        return None
    where = {"location": f"{lat:.6f},{lng:.6f}", "radius": 60, "source": "outdoor", "key": GOOGLE_KEY}
    meta = requests.get("https://maps.googleapis.com/maps/api/streetview/metadata", params=where, timeout=6).json()
    if meta.get("status") != "OK":
        return None
    r = requests.get("https://maps.googleapis.com/maps/api/streetview",
                     params={**where, "size": f"{width}x{height}", "fov": 80, "pitch": 5, "return_error_code": "true"}, timeout=8)
    r.raise_for_status()
    return r.content, r.headers.get("content-type", "image/jpeg")


def place_photo(ref, width=800):
    """The picture itself (Google gives a short-lived link to it)."""
    r = requests.get(f"{GOOGLE}/{ref}/media", params={"maxWidthPx": width, "key": GOOGLE_KEY}, timeout=8)
    r.raise_for_status()
    return r.content, r.headers.get("content-type", "image/jpeg")
