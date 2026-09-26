"""
Weather from Open-Meteo (free, no API key, up to 16 days ahead): right now, and the forecast for a hangout's hour.
Rain feeds straight into the lateness model: some people are much later when it rains.
"""
import time
from datetime import datetime, timedelta

import requests

URL = "https://api.open-meteo.com/v1/forecast"
RAIN_CHANCE = 50   # % chance at which we treat the hangout as rainy
RAIN_MM = 0.3      # or this much rain expected in that hour
_cache = {}        # (lat, lng) rounded -> (fetched_at, {"hours": {hour: (chance, mm, code, temp_c)}, "now": {...}})

ICONS = [((0,), "☀️", "Clear"), ((1, 2), "🌤️", "Mostly sunny"), ((3,), "☁️", "Cloudy"), ((45, 48), "🌫️", "Foggy"),
         (range(51, 68), "🌧️", "Rain"), (range(71, 78), "❄️", "Snow"), (range(80, 83), "🌦️", "Showers"),
         (range(85, 87), "❄️", "Snow showers"), (range(95, 100), "⛈️", "Storms")]


def _look(code):
    return next(((i, l) for codes, i, l in ICONS if code in codes), ("🌡️", "Weather"))


def _get(lat, lng):
    key = (round(lat, 2), round(lng, 2))
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < 1800:  # reuse for 30 minutes
        return hit[1]
    r = requests.get(URL, params={"latitude": key[0], "longitude": key[1], "timezone": "auto", "forecast_days": 16,
                                  "hourly": "precipitation_probability,precipitation,weather_code,temperature_2m",
                                  "current": "temperature_2m,apparent_temperature,weather_code,precipitation"}, timeout=8)
    r.raise_for_status()
    data = r.json()
    h = data["hourly"]
    # times come back in the place's local time, like "2026-09-28T19:00"
    hours = {t: (p, mm, c, temp) for t, p, mm, c, temp in
             zip(h["time"], h["precipitation_probability"], h["precipitation"], h["weather_code"], h["temperature_2m"])}
    c = data.get("current", {})
    now = {"temp_c": c.get("temperature_2m"), "feels_c": c.get("apparent_temperature"), "code": c.get("weather_code"),
           "raining": (c.get("precipitation") or 0) > 0}
    result = {"hours": hours, "now": now}
    _cache[key] = (time.time(), result)
    return result


def weather_at(lat, lng, when):
    """Forecast for the hour of `when` (local time at the place). Unknown (too far ahead, or offline) -> not raining."""
    if isinstance(when, str):
        when = datetime.fromisoformat(when)
    try:
        chance, mm, code, temp = _get(lat, lng)["hours"].get(when.strftime("%Y-%m-%dT%H:00"), (None,) * 4)
    except Exception:
        chance = mm = code = temp = None
    if chance is None and code is None:
        return {"known": False, "raining": False, "rain_chance": None, "icon": "🌡️", "label": "No forecast yet", "temp_c": None}
    icon, label = _look(code)
    return {"known": True, "raining": (chance or 0) >= RAIN_CHANCE or (mm or 0) >= RAIN_MM,
            "rain_chance": chance, "icon": icon, "label": label, "temp_c": temp}


def weather_now(lat, lng):
    """What it's like outside right now."""
    try:
        now = _get(lat, lng)["now"]
    except Exception:
        return None
    if now.get("temp_c") is None:
        return None
    icon, label = _look(now["code"])
    return {"icon": icon, "label": label, "temp_c": now["temp_c"], "feels_c": now["feels_c"], "raining": now["raining"]}


def hours_around(lat, lng, when, before=2, after=3):
    """A small hour-by-hour strip around the hangout, e.g. 5pm to 10pm for a 7pm hangout."""
    if isinstance(when, str):
        when = datetime.fromisoformat(when)
    start = when.replace(minute=0, second=0, microsecond=0)
    out = []
    for k in range(-before, after + 1):
        t = start + timedelta(hours=k)
        w = weather_at(lat, lng, t)
        if w["known"]:
            out.append({"time": t.strftime("%Y-%m-%dT%H:00"), "icon": w["icon"], "temp_c": w["temp_c"],
                        "rain_chance": w["rain_chance"], "hangout": k == 0})
    return out


if __name__ == "__main__":
    soon = datetime.now().replace(minute=0, second=0, microsecond=0) + timedelta(hours=3)
    print("now:", weather_now(33.7756, -84.3963))  # Georgia Tech
    print(soon, weather_at(33.7756, -84.3963, soon))
