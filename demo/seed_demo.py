"""
Makes the demo account for Apple's App Review (and for showing omw! off): you sign in as Alex, who already has five friends,
a plan tomorrow, an invite waiting, group photos in the feed, a chat, and friends who are free or out right now.

Run it from the repo folder, with the same Firebase service account the server uses (FIREBASE_SERVICE_ACCOUNT_JSON in .env,
or FIREBASE_SERVICE_ACCOUNT=path/to/key.json):

    python demo/seed_demo.py                 # makes (or refreshes) the account and prints the login
    python demo/seed_demo.py --password ...  # pick the password yourself

Run it again right before you submit to App Review: it moves every time (the plan, the statuses) to be fresh again.
The pictures are drawn in omw!'s avatar style (demo/demo_assets.json), not photos of real people.
"""
import argparse
import json
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

EMAIL = "appreview@omw.demo"
TZ = "America/Los_Angeles"
ASSETS = json.load(open(os.path.join(os.path.dirname(__file__), "demo_assets.json")))
PEOPLE = {  # uid: (name, friend ID, home [lat, lng], how they get around)
    "demo_alex": ("Alex Rivera", "DEMO_ALEX", [37.7609, -122.4350], "transit"),
    "demo_priya": ("Priya Shah", "DEMO_PRIYA", [37.7793, -122.4192], "driving"),
    "demo_sam": ("Sam Okafor", "DEMO_SAM", [37.7599, -122.4148], "cycling"),
    "demo_leo": ("Leo Park", "DEMO_LEO", [37.7849, -122.4094], "walking"),
    "demo_mia": ("Mia Johnson", "DEMO_MIA", [37.7694, -122.4862], "transit"),
    "demo_jae": ("Jae Kim", "DEMO_JAE", [37.7955, -122.3937], "driving"),
}
ME = "demo_alex"
PLACES = {
    "hotpot": ("Sunset Hot Pot", "2200 Irving St, San Francisco", [37.7637, -122.4826]),
    "boba": ("Mission Boba", "3200 24th St, San Francisco", [37.7524, -122.4167]),
    "karaoke": ("Encore Karaoke", "1550 California St, San Francisco", [37.7905, -122.4207]),
    "hike": ("Twin Peaks", "501 Twin Peaks Blvd, San Francisco", [37.7544, -122.4477]),
    "tacos": ("La Taqueria", "2889 Mission St, San Francisco", [37.7509, -122.4181]),
}


def iso(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def first(uid):
    return PEOPLE[uid][0].split()[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--email", default=EMAIL)
    ap.add_argument("--password", default=None, help="default: a new random one, printed at the end")
    args = ap.parse_args()
    password = args.password or "omw-" + secrets.token_urlsafe(9)

    from calendar_feed import firestore_client
    from firebase_admin import auth
    db = firestore_client()
    now = datetime.now(timezone.utc)
    day = lambda n, hour, minute=0: (now.astimezone() + timedelta(days=n)).replace(hour=hour, minute=minute, second=0, microsecond=0)
    names = {u: p[0] for u, p in PEOPLE.items()}

    # ---- sign-in accounts: Alex logs in with email + password; the friends never log in ----
    for uid, (name, *_rest) in PEOPLE.items():
        fields = {"display_name": name}
        if uid == ME:
            fields |= {"email": args.email, "password": password, "email_verified": True}
        try:
            auth.update_user(uid, **fields)
        except auth.UserNotFoundError:
            auth.create_user(uid=uid, **fields)

    # ---- profiles, friend IDs, statuses ----
    look = {"demo_alex": "alex", "demo_priya": "priya", "demo_sam": "sam", "demo_leo": "leo", "demo_mia": "mia", "demo_jae": "jae"}
    later = iso(now + timedelta(days=3))
    status = {"demo_priya": {"now": {"kind": "out", "until": later}}, "demo_leo": {"now": {"kind": "omw", "until": later}},
              "demo_sam": {"freeUntil": later}, "demo_mia": {"freeUntil": later}}
    habits = {"demo_alex": [-3, 1, -1, 4], "demo_priya": [0, -2, 2], "demo_sam": [6, 2, 9, 3], "demo_leo": [15, 12, 22],
              "demo_mia": [-1, 0, 3], "demo_jae": [5, -4, 1]}
    for uid, (name, code, home, mode) in PEOPLE.items():
        db.collection("users").document(uid).set({
            "name": name, "code": code, "photo": ASSETS["people"][look[uid]], "travelMode": mode, "shareLive": True,
            "home": {"lat": home[0], "lng": home[1]}, "homeName": "Home", "freeUntil": None, "now": None,
            "habits": [{"id": f"demo_past_{i}", "late": late} for i, late in enumerate(habits[uid])], **status.get(uid, {})})
        db.collection("codes").document(code).set({"uid": uid, "name": name})
    for uid in PEOPLE:
        if uid != ME:
            db.collection("users").document(ME).collection("friends").document(uid).set({"since": iso(now - timedelta(days=40))})
            db.collection("users").document(uid).collection("friends").document(ME).set({"since": iso(now - timedelta(days=40))})

    # ---- plans ----
    def hangout(hid, place, kind, start, people, creator, invited=(), arrivals=None, alerts=None):
        name, address, venue = PLACES[place]
        attendees = list(people)
        everyone = list(dict.fromkeys(attendees + list(invited)))
        travel = {u: 15 + i * 4 for i, u in enumerate(everyone)}
        doc = {"title": f"{kind} at {name}", "start": iso(start), "durationMin": 120, "venueName": name, "address": address,
               "venue": venue, "type": kind.lower(), "createdBy": creator, "createdByName": names[creator], "tz": TZ,
               "attendees": attendees, "invited": everyone, "names": {u: names[u] for u in everyone},
               "modes": {u: PEOPLE[u][3] for u in everyone}, "rsvp": {u: "going" for u in attendees},
               "travel": travel, "alerts": alerts or {u: iso(start - timedelta(minutes=travel[u] + 3)) for u in attendees},
               "arrivals": arrivals or {}, "createdAt": iso(now - timedelta(days=2))}
        ref = db.collection("hangouts").document(hid)
        for sub in ("messages", "where"):
            for d in ref.collection(sub).stream():
                d.reference.delete()
        ref.set(doc)
        return doc

    up = hangout("demo_up", "hotpot", "Food", day(1, 19, 30), [ME, "demo_priya", "demo_sam"], ME, invited=["demo_jae"])
    hangout("demo_invite", "tacos", "Food", day(3, 12, 30), ["demo_leo", "demo_mia"], "demo_leo", invited=[ME])
    for i, (who, text) in enumerate([("demo_priya", "can't wait, I'm starving"), ("demo_sam", "biking over, save me a seat"),
                                     (ME, "booked a table for 4")]):
        db.collection("hangouts").document("demo_up").collection("messages").add(
            {"from": who, "name": names[who], "text": text, "at": iso(now - timedelta(hours=5 - i))})

    # ---- past hangouts: group photos, and the feed ----
    past = [  # id, place, kind, days ago, who, minutes each arrived after the start, photo, ratings
        ("demo_karaoke", "karaoke", "Party", 3, [ME, "demo_priya", "demo_sam", "demo_mia"], [-2, 0, 4, 1], "karaoke", {ME: 9, "demo_priya": 9, "demo_mia": 5.5}),
        ("demo_hike", "hike", "Sports", 6, [ME, "demo_leo", "demo_mia"], [-4, 15, 0], "hike", {ME: 9, "demo_mia": 9}),
        ("demo_hotpot", "hotpot", "Food", 1, ["demo_priya", "demo_sam", "demo_jae"], [0, 2, 3], "hotpot", {"demo_priya": 9, "demo_sam": 9, "demo_jae": 5.5}),
        ("demo_boba", "boba", "Coffee", 2, ["demo_leo", "demo_jae"], [6, 1], "boba", {}),
    ]
    viewers = list(PEOPLE)
    for hid, place, kind, ago, who, late, photo, ratings in past:
        start = day(-ago, 18)
        arrivals = {u: iso(start + timedelta(minutes=m)) for u, m in zip(who, late)}
        h = hangout(hid, place, kind, start, who, who[0], arrivals=arrivals)
        all_here = max(start + timedelta(minutes=m) for m in late)
        posted = all_here + timedelta(minutes=4)
        memory = {"members": who, "names": {u: names[u] for u in who}, "by": who[0], "byName": names[who[0]],
                  "photo": ASSETS["photos"][photo], "at": iso(posted), "allHereAt": iso(all_here), "title": h["title"],
                  "venueName": h["venueName"], "address": h["address"], "start": h["start"]}
        db.collection("memories").document(hid).set(memory)
        db.collection("feed").document(hid).set({
            **{k: memory[k] for k in ("by", "byName", "members", "names", "photo", "at", "start", "title", "venueName", "address")},
            "venue": h["venue"], "late": {u: max(0, m) for u, m in zip(who, late)}, "viewers": viewers,
            "likes": [u for u in viewers if u not in who][:3], "ratings": ratings})

    # ---- a chat ----
    dm = db.collection("chats").document(f"dm_{'_'.join(sorted([ME, 'demo_priya']))}")
    for d in dm.collection("messages").stream():
        d.reference.delete()
    lines = [("demo_priya", "are you coming tomorrow?"), (ME, "yes! leaving right when omw says"), ("demo_priya", "lol same, see you there")]
    for i, (who, text) in enumerate(lines):
        dm.collection("messages").add({"from": who, "name": names[who], "text": text, "at": iso(now - timedelta(minutes=50 - i * 10))})
    last = {"from": lines[-1][0], "name": names[lines[-1][0]], "text": lines[-1][1], "at": iso(now - timedelta(minutes=30))}
    dm.set({"members": sorted([ME, "demo_priya"]), "group": False, "createdBy": ME, "createdAt": iso(now - timedelta(days=10)),
            "names": {ME: names[ME], "demo_priya": names["demo_priya"]}, "photos": {}, "last": last, "read": {ME: iso(now - timedelta(hours=1))}})

    print("\nDemo account ready. For App Store Connect -> App Review Information -> Sign-in required:")
    print(f"  User name: {args.email}")
    print(f"  Password:  {password}")
    print("Sign in with 'Use email'. Alex has 5 friends, a plan tomorrow at 7:30 PM, an invite, a chat and a feed of group photos.")


if __name__ == "__main__":
    main()
