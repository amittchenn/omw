"""
The weather forecast for a place and time, from Open-Meteo (free, no API key, up to 16 days ahead).
Rain feeds straight into the lateness model: some people are much later when it rains.
"""
import time
from datetime import datetime

import requests

URL = "https://api.open-meteo.com/v1/forecast"
RAIN_CHANCE = 50   # % chance at which we treat the hangout as rainy
RAIN_MM = 0.3      # or this much rain expected in that hour
_cache = {}        # (lat, lng) rounded -> (fetched_at, {hour: (chance, mm, code)})

ICONS = [((0,), "☀️", "Clear"), ((1, 2), "🌤️", "Mostly sunny"), ((3,), "☁️", "Cloudy"), ((45, 48), "🌫️", "Foggy"),
         (range(51, 68), "🌧️", "Rain"), (range(71, 78), "❄️", "Snow"), (range(80, 83), "🌦️", "Showers"),
         (range(85, 87), "❄️", "Snow showers"), (range(95, 100), "⛈️", "Storms")]


def _hourly(lat, lng):
    key = (round(lat, 2), round(lng, 2))
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < 1800:  # reuse for 30 minutes
        return hit[1]
    r = requests.get(URL, params={"latitude": key[0], "longitude": key[1], "timezone": "auto", "forecast_days": 16,
                                  "hourly": "precipitation_probability,precipitation,weather_code"}, timeout=8)
    r.raise_for_status()
    h = r.json()["hourly"]
    # times come back in the place's local time, like "2026-09-28T19:00"
    hours = {t: (p, mm, c) for t, p, mm, c in zip(h["time"], h["precipitation_probability"], h["precipitation"], h["weather_code"])}
    _cache[key] = (time.time(), hours)
    return hours


def weather_at(lat, lng, when):
    """Forecast for the hour of `when` (local time at the place). Unknown (too far ahead, or offline) -> not raining."""
    if isinstance(when, str):
        when = datetime.fromisoformat(when)
    try:
        chance, mm, code = _hourly(lat, lng).get(when.strftime("%Y-%m-%dT%H:00"), (None, None, None))
    except Exception:
        chance = mm = code = None
    if chance is None and code is None:
        return {"known": False, "raining": False, "rain_chance": None, "icon": "🌡️", "label": "No forecast yet"}
    icon, label = next(((i, l) for codes, i, l in ICONS if code in codes), ("🌡️", "Weather"))
    return {"known": True, "raining": (chance or 0) >= RAIN_CHANCE or (mm or 0) >= RAIN_MM,
            "rain_chance": chance, "icon": icon, "label": label}


if __name__ == "__main__":
    from datetime import timedelta
    soon = datetime.now().replace(minute=0, second=0, microsecond=0) + timedelta(hours=3)
    print(soon, weather_at(33.7756, -84.3963, soon))  # Georgia Tech