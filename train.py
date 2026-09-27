"""
Steps 8-12: train the lateness model and prove it beats simple baselines.

Split by time (like real life: learn from the past, predict the future):
  first 60% of each person's hangouts -> train the model
  next 20%                            -> warm up the per-person correction
  last 20%                            -> test (never seen during training)
"""
import os

import joblib
import lightgbm as lgb
import numpy as np
import pandas as pd

K = 5  # same trust setting as features.py

FEATURES = [
    # the hangout
    "hour", "day_of_week", "hangout_type", "planned_days_ahead", "group_size", "is_morning",
    # the context
    "raining", "came_from_event", "travel_mode", "travel_minutes",
    # the person's history (from features.py)
    "n_prior", "shrunk_avg_delay", "recent_avg_delay", "prior_std_delay", "prior_late_rate",
    "shrunk_avg_when_raining", "shrunk_avg_when_came_from_event", "shrunk_avg_when_is_morning",
    "group_avg_delay",
]
CATEGORICAL = ["hangout_type", "travel_mode"]
TARGET = "departure_delay_min"


def prepare(df):
    X = df[FEATURES].copy()
    for c in CATEGORICAL:
        X[c] = X[c].astype("category")
    for c in ["raining", "came_from_event", "is_morning"]:
        X[c] = X[c].astype(int)
    return X


def split_by_time(df):
    # position of each row within that person's own timeline (0 = first, 1 = last)
    pos = df.groupby("user_id").cumcount() / df.groupby("user_id").user_id.transform("count")
    return np.where(pos < 0.6, "train", np.where(pos < 0.8, "warmup", "test"))


def train_quantile(X, y, alpha, weight=None):
    model = lgb.LGBMRegressor(
        objective="quantile", alpha=alpha,
        n_estimators=300, learning_rate=0.05, num_leaves=15, min_child_samples=20,
        verbose=-1, random_state=42,
    )
    return model.fit(X, y, sample_weight=weight)


def add_personal_correction(df):
    """Per-person bias: how much the model has been off for this person so far.
    Updates after every hangout, shrinks toward 0 for people with little history."""
    df["error"] = df[TARGET] - df["pred_p50"]
    after_train = df.split != "train"
    df["bias"] = 0.0
    for uid, u in df[after_train].groupby("user_id"):
        prior_sum = u.error.cumsum().shift(1).fillna(0)
        prior_cnt = np.arange(len(u))
        df.loc[u.index, "bias"] = prior_sum / (prior_cnt + K)
    df["final_p50"] = df.pred_p50 + df.bias
    df["final_p90"] = np.maximum(df.pred_p90 + df.bias, df.final_p50)
    return df


def on_time_rate(test, alert_shift, grace=5):
    """Simulate moving each person's alert earlier by `alert_shift` minutes.
    Returns (% of hangouts where EVERYONE arrives within `grace` min, avg minutes early)."""
    new_lateness = test.lateness_min - alert_shift
    everyone_ok = (new_lateness <= grace).groupby(test.hangout_id).all().mean()
    avg_early = (-new_lateness).clip(lower=0).mean()
    return everyone_ok * 100, avg_early


if __name__ == "__main__":
    df = pd.read_csv("data/features.csv", parse_dates=["start_time"])
    df["split"] = split_by_time(df)
    X, y = prepare(df), df[TARGET]
    train = df.split == "train"

    p50_model = train_quantile(X[train], y[train], 0.5)
    p90_model = train_quantile(X[train], y[train], 0.9)
    df["pred_p50"] = p50_model.predict(X)
    df["pred_p90"] = np.maximum(p90_model.predict(X), df.pred_p50)  # p90 can't be below p50
    df = add_personal_correction(df)

    test = df[df.split == "test"]
    print(f"Train rows: {train.sum()}, test rows: {len(test)}\n")

    # 1. Accuracy: average error in minutes (lower is better)
    results = {
        "Maps only (assume everyone leaves on time)": 0,
        "Personal average": test.shrunk_avg_delay,
        "Our model": test.pred_p50,
        "Our model + personal correction": test.final_p50,
    }
    print("Average error predicting departure delay (minutes, lower = better):")
    for name, pred in results.items():
        print(f"  {name:45} {np.mean(np.abs(test[TARGET] - pred)):5.2f}")

    # 2. Calibration: p90 should be above the real delay ~90% of the time
    coverage = (test[TARGET] <= test.final_p90).mean() * 100
    print(f"\nActual delay was at or below our p90 prediction {coverage:.0f}% of the time (target: ~90%)")

    # 3. Product metric: do hangouts actually start on time?
    print("\nSimulated hangouts where everyone arrives within 5 min of start:")
    for name, shift in [
        ("Maps-only alerts", 0),
        ("Alerts shifted by personal average", test.shrunk_avg_delay),
        ("Alerts from our model (p90)", test.final_p90),
    ]:
        pct, early = on_time_rate(test, shift)
        print(f"  {name:37} {pct:5.1f}%   (avg {early:.1f} min early)")

    # Save everything the app needs
    os.makedirs("models", exist_ok=True)
    last_bias = df.groupby("user_id").bias.last().to_dict()
    joblib.dump({"p50": p50_model, "p90": p90_model, "features": FEATURES,
                 "categorical": CATEGORICAL, "K": K, "user_bias": last_bias},
                "models/lateness.pkl")
    df.to_csv("data/predictions.csv", index=False)
    print("\nSaved models/lateness.pkl and data/predictions.csv")
