"""
Step 5: synthetic hangout data.

Creates 24 fake users (8 personas x 3), puts them into 4 friend groups,
and simulates a year of hangouts. Each row = one person attending one hangout.

The target the model will learn is `departure_delay_min`:
how many minutes after the "leave now" alert the person actually left.
"""
import os
from datetime import datetime, timedelta

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

rng = np.random.default_rng(42)

N_GROUPS = 4
USERS_PER_PERSONA = 3
HANGOUTS_PER_GROUP = 250
START_DATE = datetime(2025, 9, 1)

# Each persona: base delay, noise size, and special habits.
PERSONAS = {
    "always_early":      {"base": -4, "noise": 1.5},
    "punctual":          {"base": 0,  "noise": 2},
    "chronically_late":  {"base": 10, "noise": 6},
    "morning_struggler": {"base": 1,  "noise": 3, "morning": 15},
    "rain_hater":        {"base": 1,  "noise": 3, "rain": 8},
    "overbooked":        {"base": 2,  "noise": 3, "busy": 12, "busy_prob": 0.6},
    "improving":         {"base": 14, "noise": 4, "improves_to": 2},
    "unpredictable":     {"base": 3,  "noise": 10},
}

HANGOUT_TYPES = ["food", "study", "party", "coffee", "sports"]
HOURS = np.arange(8, 23)
HOUR_WEIGHTS = np.array([2, 2, 3, 3, 5, 4, 3, 3, 4, 6, 8, 8, 7, 5, 3], dtype=float)
TRAVEL = {  # mode: (probability, min minutes, max minutes)
    "walking": (0.3, 5, 25),
    "driving": (0.5, 8, 40),
    "cycling": (0.2, 6, 25),
}


def make_users():
    names = [p for p in PERSONAS for _ in range(USERS_PER_PERSONA)]
    rng.shuffle(names)
    users = pd.DataFrame({"user_id": [f"u{i:02d}" for i in range(len(names))], "persona": names})
    users["group_id"] = [i % N_GROUPS for i in range(len(users))]
    users["travel_mode"] = rng.choice(list(TRAVEL), size=len(users), p=[v[0] for v in TRAVEL.values()])
    return users


def skewed_noise(scale):
    # log-normal noise shifted so the median is 0: mostly small, sometimes a big delay
    return rng.lognormal(mean=np.log(scale), sigma=0.6) - scale


def departure_delay(p, hangout, came_from_event, progress):
    """How many minutes after the alert this person leaves."""
    base = p["base"]
    if "improves_to" in p:  # gets better over the year
        base = p["base"] + (p["improves_to"] - p["base"]) * progress

    d = base
    # habits everyone shares a little
    d += 2 if hangout["raining"] else 0
    d += 3 if came_from_event else 0
    d += 2 if hangout["hour"] < 10 else 0
    d += 3 if hangout["type"] == "party" else 0
    d -= 1 if hangout["type"] == "study" else 0
    d += 0.3 * hangout["planned_days_ahead"]  # plans made long ago feel less urgent
    # persona-specific habits
    d += p.get("morning", 0) if hangout["hour"] < 10 else 0
    d += p.get("rain", 0) if hangout["raining"] else 0
    d += p.get("busy", 0) if came_from_event else 0

    d += skewed_noise(p["noise"])
    return max(d, -10)


def simulate():
    users = make_users()
    rows = []
    hangout_counter = 0

    for g in range(N_GROUPS):
        members = users[users.group_id == g]
        days = np.sort(rng.uniform(0, 365, HANGOUTS_PER_GROUP))

        for day in days:
            hour = int(rng.choice(HOURS, p=HOUR_WEIGHTS / HOUR_WEIGHTS.sum()))
            start = START_DATE + timedelta(days=int(day), hours=hour, minutes=int(rng.choice([0, 30])))
            hangout = {
                "hangout_id": f"h{hangout_counter:04d}",
                "start_time": start,
                "hour": hour,
                "day_of_week": start.weekday(),
                "type": rng.choice(HANGOUT_TYPES),
                "raining": rng.random() < 0.2,
                "planned_days_ahead": int(rng.integers(0, 8)),
            }
            hangout_counter += 1

            size = int(rng.integers(3, len(members) + 1))
            attendees = members.sample(size, random_state=int(rng.integers(1_000_000)))

            for _, u in attendees.iterrows():
                p = PERSONAS[u.persona]
                _, lo, hi = TRAVEL[u.travel_mode]
                travel_min = float(rng.uniform(lo, hi))
                came_from_event = rng.random() < p.get("busy_prob", 0.3)

                delay = departure_delay(p, hangout, came_from_event, progress=day / 365)
                actual_travel = travel_min * rng.uniform(0.9, 1.15) * (1.1 if hangout["raining"] else 1)

                # Maps-only alert: leave exactly when the trip needs you to
                alert_time = start - timedelta(minutes=travel_min)
                left_at = alert_time + timedelta(minutes=delay)
                arrived_at = left_at + timedelta(minutes=actual_travel)

                rows.append({
                    "user_id": u.user_id,
                    "persona": u.persona,
                    "group_id": g,
                    "hangout_id": hangout["hangout_id"],
                    "start_time": start,
                    "hour": hour,
                    "day_of_week": hangout["day_of_week"],
                    "hangout_type": hangout["type"],
                    "raining": hangout["raining"],
                    "planned_days_ahead": hangout["planned_days_ahead"],
                    "group_size": size,
                    "travel_mode": u.travel_mode,
                    "travel_minutes": round(travel_min, 1),
                    "came_from_event": came_from_event,
                    "alert_time": alert_time,
                    "left_at": left_at,
                    "arrived_at": arrived_at,
                    "departure_delay_min": round(delay, 1),
                    "lateness_min": round((arrived_at - start).total_seconds() / 60, 1),
                })

    return pd.DataFrame(rows).sort_values(["start_time", "user_id"]).reset_index(drop=True)


if __name__ == "__main__":
    os.makedirs("data", exist_ok=True)
    df = simulate()
    df.to_csv("data/hangouts.csv", index=False)

    print(f"Saved {len(df)} rows, {df.user_id.nunique()} users, {df.hangout_id.nunique()} hangouts\n")
    summary = df.groupby("persona").departure_delay_min.describe(percentiles=[0.5, 0.9])
    print(summary[["count", "50%", "90%"]].round(1).sort_values("50%"))

    order = summary.sort_values("50%").index
    plt.figure(figsize=(10, 5))
    plt.boxplot([df[df.persona == p].departure_delay_min for p in order], showfliers=False)
    plt.xticks(range(1, len(order) + 1), order, rotation=30, ha="right")
    plt.axhline(0, color="gray", linewidth=0.8)
    plt.ylabel("Minutes after alert before leaving")
    plt.title("Departure delay by persona")
    plt.tight_layout()
    plt.savefig("data/delay_by_persona.png", dpi=120)
    print("\nChart saved to data/delay_by_persona.png")