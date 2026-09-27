"""
Retrain the lateness model on real omw! check-ins, next to the simulated friend groups it started with.

Every check-in in the app is a real example of what the model predicts: you were told to leave at the alert,
and from your arrival and the trip time we know when you actually left. Those become training rows here:
  - real rows count REAL_WEIGHT times as much as simulated ones (they're what matters),
  - it's tested on data it never saw, and the new model is only kept if it isn't worse than the one in use,
  - real people's check-ins also become their history, so the model sees their habits the way it sees everyone's.

Runs from the server at startup and then once a day (start_background), or by hand:  python retrain.py
Check-ins are read from Firestore (FIREBASE_SERVICE_ACCOUNT_JSON) and kept in data/real_checkins.csv.
"""
import os
import threading
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import joblib
import numpy as np
import pandas as pd

import train
from features import build_features

SIM = "data/hangouts.csv"
REAL = "data/real_checkins.csv"
MODEL_PATH = "models/lateness.pkl"
REAL_WEIGHT = 5          # one real check-in counts as much as 5 simulated ones
MIN_REAL = 5             # don't bother retraining until there are this many real check-ins
MIN_REAL_TEST = 10       # below this many real test rows, the "on real people" score is too noisy to judge by
DATES = ["start_time", "alert_time", "left_at", "arrived_at"]


def _naive_local(iso, tz):
    t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=timezone.utc)
    return t.astimezone(ZoneInfo(tz or "America/New_York")).replace(tzinfo=None)


def rows_from_hangouts(hangouts, raining_at=lambda h, start: False):
    """Firestore hangout docs ({id, start, arrivals, alerts, travel, modes, ...}) -> one training row per real check-in."""
    rows = []
    for h in hangouts:
        tz = h.get("tz") or "America/New_York"
        try:
            start = _naive_local(h["start"], tz)
        except Exception:
            continue
        created = h.get("createdAt")
        created = created.astimezone(ZoneInfo(tz)).replace(tzinfo=None) if hasattr(created, "astimezone") else None
        for uid, arrived in (h.get("arrivals") or {}).items():
            alert, travel = (h.get("alerts") or {}).get(uid), (h.get("travel") or {}).get(uid)
            if not alert or not isinstance(travel, (int, float)):
                continue  # no leave-now time for them (e.g. added late): nothing to learn from
            try:
                arrived_at, alert_at = _naive_local(arrived, tz), _naive_local(alert, tz)
            except Exception:
                continue
            delay = (arrived_at - alert_at).total_seconds() / 60 - travel  # minutes after the alert they actually left
            late = (arrived_at - start).total_seconds() / 60
            if not -30 <= delay <= 60 or late > 30:
                continue  # checked in long after arriving, or a GPS glitch: not a real habit (the app skips these too)
            rows.append({
                "user_id": uid, "persona": "real", "group_id": "real", "hangout_id": h["id"],
                "start_time": start, "hour": start.hour, "day_of_week": start.weekday(),
                "hangout_type": h.get("type") or "food", "raining": bool(raining_at(h, start)),
                "planned_days_ahead": max(0, (start - created).days) if created else 1,
                "group_size": len(h.get("attendees") or [uid]),
                "travel_mode": (h.get("modes") or {}).get(uid) or "driving", "travel_minutes": float(travel),
                "came_from_event": False,
                "alert_time": alert_at, "left_at": alert_at + pd.Timedelta(minutes=delay), "arrived_at": arrived_at,
                "departure_delay_min": round(delay, 1),
                "lateness_min": round((arrived_at - start).total_seconds() / 60, 1),
            })
    return rows


def fetch_real(db=None):
    """Pull every check-in from Firestore into data/real_checkins.csv. Returns the rows (the saved file if Firestore isn't set up)."""
    if db is None:
        try:
            from calendar_feed import firestore_client
            db = firestore_client()
        except Exception:
            db = None
    if db is None:
        return pd.read_csv(REAL, parse_dates=DATES) if os.path.exists(REAL) else pd.DataFrame()
    try:
        import traffic
        weather = traffic.past_weather()  # {"2026-09-26T18:00": "rain", ...} for the last 2 weeks
    except Exception:
        weather = {}
    raining = lambda h, start: weather.get(start.strftime("%Y-%m-%dT%H:00"), "clear") != "clear"
    docs = [{"id": d.id, **d.to_dict()} for d in db.collection("hangouts").stream()]
    df = pd.DataFrame(rows_from_hangouts(docs, raining))
    if len(df):
        os.makedirs("data", exist_ok=True)
        df.to_csv(REAL, index=False)
    return df


def _old_predictions(model, X):
    X = X.copy()
    for c in model["categorical"]:
        X[c] = pd.Categorical(X[c].astype(str), categories=model["p50"].booster_.pandas_categorical[model["categorical"].index(c)])
    return model["p50"].predict(X)


def retrain(real=None, save=True, log=print):
    """Train on simulated + real check-ins. Keeps the new model only if it isn't worse. Returns a small report."""
    real = fetch_real() if real is None else real
    if len(real) < MIN_REAL:
        log(f"[lateness] {len(real)} real check-ins so far; retraining once there are {MIN_REAL}")
        return {"real_rows": len(real), "kept": False, "reason": "not enough check-ins yet"}
    sim = pd.read_csv(SIM, parse_dates=DATES)
    df = build_features(pd.concat([sim, real], ignore_index=True))
    df["split"] = train.split_by_time(df)
    df["is_real"] = df.persona == "real"
    X, y = train.prepare(df), df[train.TARGET]
    fit = df.split == "train"
    w = np.where(df.is_real, REAL_WEIGHT, 1.0)
    p50 = train.train_quantile(X[fit], y[fit], 0.5, w[fit])
    p90 = train.train_quantile(X[fit], y[fit], 0.9, w[fit])
    df["pred_p50"] = p50.predict(X)
    df["pred_p90"] = np.maximum(p90.predict(X), df.pred_p50)
    df = train.add_personal_correction(df)

    old = joblib.load(MODEL_PATH) if os.path.exists(MODEL_PATH) else None
    test = df.split == "test"
    mae = lambda pred, rows: float(np.mean(np.abs(y[rows] - pred[rows]))) if rows.any() else None
    old_pred = pd.Series(_old_predictions(old, X), index=df.index) if old else None
    report = {
        "real_rows": int(df.is_real.sum()), "real_people": int(df[df.is_real].user_id.nunique()),
        "real_test_rows": int((test & df.is_real).sum()),
        "sim_error_new": mae(df.pred_p50, test & ~df.is_real), "sim_error_old": mae(old_pred, test & ~df.is_real) if old else None,
        "real_error_new": mae(df.pred_p50, test & df.is_real), "real_error_old": mae(old_pred, test & df.is_real) if old else None,
        "real_error_maps": mae(pd.Series(0.0, index=df.index), test & df.is_real),
    }
    # keep it only if it's no worse on the simulated test set, and (once there's enough real test data) no worse on real people
    worse_sim = old and report["sim_error_new"] > report["sim_error_old"] + 0.1
    worse_real = old and report["real_test_rows"] >= MIN_REAL_TEST and report["real_error_new"] > report["real_error_old"]
    report["kept"] = not (worse_sim or worse_real)
    report["reason"] = "worse on simulated test data" if worse_sim else "worse on real people" if worse_real else "no worse than before"
    fmt = lambda v: "—" if v is None else f"{v:.2f}"
    log(f"[lateness] {report['real_rows']} real check-ins from {report['real_people']} people · test error, sim: "
        f"{fmt(report['sim_error_old'])} → {fmt(report['sim_error_new'])} min · real ({report['real_test_rows']} rows): Maps only "
        f"{fmt(report['real_error_maps'])}, old {fmt(report['real_error_old'])}, new {fmt(report['real_error_new'])} min · "
        f"{'kept' if report['kept'] else 'not kept'} ({report['reason']})")
    if report["kept"] and save:
        joblib.dump({"p50": p50, "p90": p90, "features": train.FEATURES, "categorical": train.CATEGORICAL, "K": train.K,
                     "user_bias": df.groupby("user_id").bias.last().to_dict(), "real_rows": report["real_rows"],
                     "trained_at": datetime.now(timezone.utc).isoformat(timespec="minutes")}, MODEL_PATH)
        import predictor  # the app picks up the new model (and real people's history) straight away
        predictor.MODEL = joblib.load(MODEL_PATH)
        predictor.HISTORY = pd.concat([sim, real], ignore_index=True)
    return report


def start_background(every_hours=24):
    def loop():
        time.sleep(30)  # let the server finish starting first
        while True:
            try:
                retrain()
            except Exception as e:
                print(f"[lateness] retrain failed: {e}")
            time.sleep(every_hours * 3600)
    threading.Thread(target=loop, daemon=True).start()


if __name__ == "__main__":
    retrain()
