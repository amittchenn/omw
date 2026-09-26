"""
Finding a time everyone's free.

1. parse_schedule: the AI (Muse, or OpenAI as backup) turns "class MWF 10-11:30, work Tue/Thu 3-7pm"
   into busy blocks like {"day": "Mon", "start": "10:00", "end": "11:30", "label": "Class"}.
2. find_times: checks everyone's busy blocks over the next week, then ranks the free slots with the
   lateness model, so the top picks are the times this group is most likely to show up on time.
"""
import json
import random
import re
from datetime import datetime, timedelta

from predictor import predict_many

DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")

PARSE_PROMPT = """You turn someone's weekly schedule, written casually, into the times they are BUSY.
Reply with JSON only, no other text, in exactly this shape:
{"blocks": [{"day": "Mon", "start": "10:00", "end": "11:30", "label": "Class"}]}
Rules:
- day is one of Mon Tue Wed Thu Fri Sat Sun. "MWF" means Mon, Wed, Fri; "TTh" or "Tue/Thu" means Tue and Thu;
  "weekdays" means Mon to Fri; "weekends" means Sat and Sun. Make one block per day.
- start and end are 24-hour HH:MM. "3-7pm" means 15:00 to 19:00.
- If something runs past midnight, end it at 23:59.
- label is 1-3 words describing what it is.
- Only include times they are busy. If nothing is a busy time, reply {"blocks": []}."""


def _minutes(hhmm):
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def clean_blocks(blocks):
    """Keep only well-formed busy blocks (the AI's output or anything a browser sends)."""
    good = []
    for b in blocks or []:
        day, start, end = b.get("day"), str(b.get("start", "")), str(b.get("end", ""))
        if day in DAYS and TIME.match(start) and TIME.match(end) and _minutes(start) < _minutes(end):
            good.append({"day": day, "start": start, "end": end, "label": str(b.get("label", "Busy"))[:30]})
    return good


def parse_schedule(text):
    """Returns (busy blocks, which AI read it)."""
    from llm import ask  # only needed here, so the rest of the app runs without an AI key
    reply, source = ask(text[:2000], system=PARSE_PROMPT, with_source=True)
    found = re.search(r"\{.*\}", reply, re.S)
    if not found:
        raise ValueError("The AI didn't return a schedule. Try rewording it.")
    return clean_blocks(json.loads(found.group()).get("blocks")), source


def demo_busy(user_id):
    """Made-up weekly schedules for the demo people: a few classes, a job, an evening thing."""
    rng = random.Random("busy" + user_id)
    blocks = []
    for day in DAYS[:5]:
        for _ in range(rng.randint(1, 3)):
            start = rng.choice(range(8, 17))
            blocks.append({"day": day, "start": f"{start:02d}:00", "end": f"{start + rng.choice([1, 2]):02d}:30", "label": "Class"})
    for day in rng.sample(DAYS, 2):
        start = rng.choice([15, 16, 17, 18])
        blocks.append({"day": day, "start": f"{start:02d}:00", "end": f"{start + 4:02d}:00", "label": "Work"})
    evening = rng.choice(DAYS)
    blocks.append({"day": evening, "start": "19:00", "end": "21:00", "label": rng.choice(["Practice", "Club", "Family dinner"])})
    return blocks


def _busy_at(blocks, start, end):
    """Is any block on this weekday overlapping the slot from start to end?"""
    day, a, b = DAYS[start.weekday()], start.hour * 60 + start.minute, end.hour * 60 + end.minute
    return next((blk for blk in blocks if blk["day"] == day and _minutes(blk["start"]) < b and a < _minutes(blk["end"])), None)


GOOD_ENOUGH_MIN = 1.5  # a day counts as "good" if the group is at most this much later than on the best day


def find_times(people, first_day, days=7, duration_min=120, earliest="09:00", latest="23:00", hangout_type="food", top=3,
               not_before=None, weather=None):
    """people: [{"user_id", "name", "travel_mode", "busy": [...]}]. Returns the soonest good slots.
    not_before: skip anything earlier (e.g. an hour from now). weather: optional function time -> forecast dict."""
    candidates = []
    for d in range(days):
        date = first_day + timedelta(days=d)
        t = datetime(date.year, date.month, date.day) + timedelta(minutes=_minutes(earliest))
        last = datetime(date.year, date.month, date.day) + timedelta(minutes=_minutes(latest) - duration_min)
        while t <= last:
            if not_before is None or t >= not_before:
                candidates.append(t)
            t += timedelta(minutes=30)

    free, blocked_by = [], {}
    for t in candidates:
        clash = [p["name"] for p in people if _busy_at(p["busy"], t, t + timedelta(minutes=duration_min))]
        if clash:
            for name in clash:
                blocked_by[name] = blocked_by.get(name, 0) + 1
        else:
            free.append(t)
    if not free:
        busiest = max(blocked_by, key=blocked_by.get) if blocked_by else None
        return {"slots": [], "checked": len(candidates),
                "message": "No time works for everyone this week." + (f" {busiest}'s schedule is the tightest." if busiest else "")}

    # the forecast for each free time: rain makes some people much later, and the model knows who
    forecast = [weather(t) if weather else {"known": False, "raining": False} for t in free]
    raining = [f["raining"] for f in forecast]

    # how late is each person likely to be at each free time? (the lateness model, one batch per person)
    delays = {p["user_id"]: predict_many(p["user_id"], free, travel_mode=p.get("travel_mode", "driving"),
                                         hangout_type=hangout_type, group_size=len(people), raining=raining) for p in people}
    scored = []
    for i, t in enumerate(free):
        per_person = {p["name"]: float(delays[p["user_id"]][i]) for p in people}
        avg = sum(per_person.values()) / len(per_person)
        worst_name = max(per_person, key=per_person.get)
        scored.append({"start": t.isoformat(timespec="minutes"), "avg_delay_min": round(avg, 1),
                       "worst": worst_name, "worst_delay_min": round(per_person[worst_name], 1),
                       "weather": forecast[i]})

    # each day's best time (least lateness), then the soonest days that are nearly as good as the best day
    by_day = {}
    for s in sorted(scored, key=lambda s: (s["avg_delay_min"], s["worst_delay_min"], s["start"])):
        by_day.setdefault(s["start"][:10], s)
    best = min(s["avg_delay_min"] for s in by_day.values())
    soon_first = sorted(by_day.values(), key=lambda s: s["start"])
    picks = [s for s in soon_first if s["avg_delay_min"] <= best + GOOD_ENOUGH_MIN][:top]
    for s in sorted(soon_first, key=lambda s: s["avg_delay_min"]):  # not enough good days: fill with the next best
        if len(picks) >= top:
            break
        if s not in picks:
            picks.append(s)
    picks.sort(key=lambda s: s["start"])
    worst_overall = max(scored, key=lambda s: s["avg_delay_min"])
    return {"slots": picks, "checked": len(candidates), "free": len(free),
            "worst_free": worst_overall}  # the free time this group would most likely be late to, for contrast

if __name__ == "__main__":
    # quick check with demo people, including the one who struggles with mornings
    from datetime import date
    group = [{"user_id": u, "name": u, "travel_mode": "driving", "busy": demo_busy(u)} for u in ["u01", "u05", "u09", "u13"]]
    result = find_times(group, date.today(), not_before=datetime.now() + timedelta(hours=1))
    print(f"checked {result['checked']} slots, {result['free']} work for everyone")
    for s in result["slots"]:
        print(" ", s)
    print("worst free slot:", result["worst_free"])