"""
Loads the trained model and predicts one person's departure delay for an upcoming hangout.
Uses the same feature code as training, so the app and the model always agree.
"""
from datetime import datetime, timedelta

import joblib
import numpy as np
import pandas as pd

from features import build_features

MODEL = joblib.load("models/lateness.pkl")
HISTORY = pd.read_csv("data/hangouts.csv", parse_dates=["start_time", "alert_time", "left_at", "arrived_at"])


def _feature_row(user_id, start_time, travel_minutes, travel_mode, hangout_type, raining, came_from_event,
                 planned_days_ahead, group_size):
    """The model's input for one person and one upcoming hangout, built with the same code as training."""
    upcoming = {
        "user_id": user_id,
        "start_time": pd.Timestamp(start_time),
        "hour": start_time.hour,
        "day_of_week": start_time.weekday(),
        "hangout_type": hangout_type,
        "raining": raining,
        "planned_days_ahead": planned_days_ahead,
        "group_size": group_size,
        "travel_mode": travel_mode,
        "travel_minutes": travel_minutes,
        "came_from_event": came_from_event,
        "departure_delay_min": np.nan,  # unknown: this is what we're predicting
    }
    # Put the upcoming hangout after this person's history and compute features the same way as training
    history = HISTORY[HISTORY.start_time < upcoming["start_time"]]
    rows = pd.concat([history, pd.DataFrame([upcoming])], ignore_index=True)
    feats = build_features(rows)
    return feats[(feats.user_id == user_id) & feats.departure_delay_min.isna()].tail(1)[MODEL["features"]].copy()


def _model_input(X):
    for c in MODEL["categorical"]:
        X[c] = pd.Categorical(X[c], categories=MODEL["p50"].booster_.pandas_categorical[MODEL["categorical"].index(c)])
    for c in ["raining", "came_from_event", "is_morning"]:
        X[c] = X[c].astype(int)
    return X


def predict_departure(user_id, start_time, travel_minutes, travel_mode="driving",
                      hangout_type="food", raining=False, came_from_event=False,
                      planned_days_ahead=2, group_size=4):
    """Returns the predicted delay range and when this person should get their alert."""
    if isinstance(start_time, str):
        start_time = datetime.fromisoformat(start_time)
    row = _feature_row(user_id, start_time, travel_minutes, travel_mode, hangout_type, raining,
                       came_from_event, planned_days_ahead, group_size)
    n_prior = int(row.n_prior.iloc[0])
    X = _model_input(row)

    bias = MODEL["user_bias"].get(user_id, 0.0)
    p50 = float(MODEL["p50"].predict(X)[0]) + bias
    p90 = max(float(MODEL["p90"].predict(X)[0]) + bias, p50)

    # Alert early enough that they arrive on time even on a bad day (p90)
    alert_time = start_time - timedelta(minutes=travel_minutes + max(p90, 0))
    return {
        "user_id": user_id,
        "typical_delay_min": round(p50, 1),
        "bad_day_delay_min": round(p90, 1),
        "travel_minutes": round(travel_minutes, 1),
        "alert_time": alert_time.isoformat(timespec="minutes"),
        "maps_only_alert_time": (start_time - timedelta(minutes=travel_minutes)).isoformat(timespec="minutes"),
        "hangouts_in_history": n_prior,
    }


def predict_many(user_id, starts, travel_minutes=15, travel_mode="driving", hangout_type="food", group_size=4, raining=None):
    """Typical delay (minutes) for one person at many possible start times, e.g. to compare time slots.
    Their history is summarized once; only the time, day and rain forecast change, so this is fast."""
    row = _feature_row(user_id, starts[0], travel_minutes, travel_mode, hangout_type, False, False, 2, group_size)
    X = pd.concat([row] * len(starts), ignore_index=True)
    X["hour"] = [s.hour for s in starts]
    X["day_of_week"] = [s.weekday() for s in starts]
    X["is_morning"] = X.hour < 10
    X["raining"] = raining if raining is not None else False
    return MODEL["p50"].predict(_model_input(X)) + MODEL["user_bias"].get(user_id, 0.0)


if __name__ == "__main__":
    # Quick check: same hangout, three different people
    for persona in ["always_early", "chronically_late", "rain_hater"]:
        uid = HISTORY[HISTORY.persona == persona].user_id.iloc[0]
        r = predict_departure(uid, "2026-09-10T19:00", travel_minutes=15, raining=True)
        print(f"{persona:17} alert at {r['alert_time'][11:]}  "
              f"(Maps alone would say {r['maps_only_alert_time'][11:]}; "
              f"usually {r['typical_delay_min']} min late, up to {r['bad_day_delay_min']})")