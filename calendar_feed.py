"""
Each person's private calendar feed (an .ics link they subscribe to once in Google or Apple Calendar).
Every locked-in hangout they're part of shows up there, with an alarm at their personal "leave now" time.

Needs a Firebase service account so the server can read hangouts:
  FIREBASE_SERVICE_ACCOUNT=path/to/key.json        (on your laptop)
  FIREBASE_SERVICE_ACCOUNT_JSON={...whole file...}  (on Render, pasted as an environment variable)
"""
import json
import os
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

_db = None


def firestore_client():
    global _db
    if _db is None:
        import firebase_admin
        from firebase_admin import credentials, firestore
        if os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON"):
            cred = credentials.Certificate(json.loads(os.environ["FIREBASE_SERVICE_ACCOUNT_JSON"]))
        elif os.getenv("FIREBASE_SERVICE_ACCOUNT"):
            cred = credentials.Certificate(os.environ["FIREBASE_SERVICE_ACCOUNT"])
        else:
            raise RuntimeError("Calendar feeds need FIREBASE_SERVICE_ACCOUNT in .env (see setup steps).")
        firebase_admin.initialize_app(cred)
        _db = firestore.client()
    return _db


def hangouts_for_token(token):
    """Find whose feed this is, then every hangout they're attending. Returns (uid, hangouts) or (None, [])."""
    db = firestore_client()
    owners = list(db.collection("private").where("calToken", "==", token).limit(1).stream())
    if not owners:
        return None, []
    uid = owners[0].id
    hangouts = [h.to_dict() | {"id": h.id} for h in db.collection("hangouts").where("attendees", "array_contains", uid).stream()]
    return uid, hangouts


# ---------- writing the .ics file ----------
def _esc(text):
    return str(text).replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def _fold(line):
    # calendar files want lines of at most 75 bytes; longer ones continue on the next line after a space
    raw, out = line.encode(), []
    while len(raw) > 75:
        cut = 75 if not out else 74
        while (raw[cut] & 0xC0) == 0x80:  # don't split a multi-byte character (like an emoji)
            cut -= 1
        out.append(raw[:cut].decode())
        raw = raw[cut:]
    out.append(raw.decode())
    return "\r\n ".join(out)


def _utc(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def build_ics(uid, hangouts, name="omw"):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Hangout//Hangout planner//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
        f"X-WR-CALNAME:{_esc(name)}", "X-WR-CALDESC:Hangouts you're part of",
        "REFRESH-INTERVAL;VALUE=DURATION:PT15M", "X-PUBLISHED-TTL:PT15M",  # ask calendar apps to check often
    ]
    for h in sorted(hangouts, key=lambda h: h["start"]):
        start = datetime.fromisoformat(h["start"].replace("Z", "+00:00"))
        local = ZoneInfo(h.get("tz") or "UTC")  # the planner's time zone, for showing times in the description
        end = start + timedelta(minutes=h.get("durationMin", 120))
        names = h.get("names") or dict(zip(h["attendees"], h.get("attendeeNames", [])))
        others = [names[u] for u in h["attendees"] if u != uid and u in names]
        alert = h.get("alerts", {}).get(uid)
        about = [f"Planned by {h.get('createdByName', 'a friend')} in omw."]
        if others:
            about.append(f"With {', '.join(others)}.")
        if alert:
            leave = datetime.fromisoformat(alert.replace("Z", "+00:00")).astimezone(local)
            about.append(f"Your leave-now alert: {leave:%-I:%M %p} (timed to your habits, not just the trip).")
        lines += [
            "BEGIN:VEVENT",
            f"UID:{h['id']}@hangout",
            f"DTSTAMP:{stamp}",
            f"DTSTART:{_utc(h['start'])}",
            f"DTEND:{end.astimezone(timezone.utc):%Y%m%dT%H%M%SZ}",
            f"SUMMARY:{_esc(h.get('title', 'Hangout'))}",
            f"LOCATION:{_esc(', '.join(x for x in [h.get('venueName'), h.get('address')] if x))}",
            f"GEO:{h['venue'][0]};{h['venue'][1]}" if h.get("venue") else None,
            f"DESCRIPTION:{_esc(' '.join(about))}",
        ]
        if alert:  # Apple Calendar rings at your personal leave time (Google ignores alarms in subscribed calendars)
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", f"DESCRIPTION:{_esc('Time to leave for ' + h.get('venueName', 'the hangout'))}",
                      f"TRIGGER;VALUE=DATE-TIME:{_utc(alert)}", "END:VALARM"]
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    return "\r\n".join(_fold(l) for l in lines if l) + "\r\n"


if __name__ == "__main__":
    # quick check with a made-up hangout
    demo = [{"id": "abc123", "title": "🍔 Food at Klaus Advanced Computing Building", "start": "2026-09-27T23:00:00.000Z",
             "venueName": "Klaus Advanced Computing Building", "address": "266 Ferst Dr NW, Atlanta, GA 30332",
             "venue": [33.7771, -84.3963], "attendees": ["me", "priya"], "attendeeNames": ["Amitt", "Priya"],
             "createdByName": "Priya", "alerts": {"me": "2026-09-27T22:20:00.000Z"}, "tz": "America/New_York"}]
    print(build_ics("me", demo))