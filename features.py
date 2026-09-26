"""
Step 7: history features.

For every row, describe how this person behaved BEFORE this hangout.
Only earlier hangouts are used, so the model never sees the future.
"""
import numpy as np
import pandas as pd

K = 5  # how many hangouts before we trust someone's personal history


def add_group_average(df):
    # average delay of everyone, using only hangouts that started earlier
    per_time = df.groupby("start_time").departure_delay_min.agg(["sum", "count"])
    prior = per_time.cumsum().shift(1).fillna(0)
    mean = (prior["sum"] / prior["count"]).fillna(0)  # 0 before any history exists
    df["group_avg_delay"] = df.start_time.map(mean)
    return df


def add_user_history(u):
    delay = u.departure_delay_min
    n = np.arange(len(u))  # number of earlier hangouts for this person
    prior_sum = delay.cumsum().shift(1).fillna(0)

    u["n_prior"] = n
    u["prior_avg_delay"] = (prior_sum / np.maximum(n, 1)).where(n > 0, np.nan)
    u["prior_std_delay"] = delay.expanding().std().shift(1)
    # recent hangouts count more (people change)
    u["recent_avg_delay"] = delay.ewm(halflife=5).mean().shift(1)

    # blend: new users start at the group average, then shift toward their own
    own = u["prior_avg_delay"].fillna(0)
    u["shrunk_avg_delay"] = (n * own + K * u["group_avg_delay"]) / (n + K)

    # personal habits in specific situations, also blended toward their overall average
    for flag in ["raining", "came_from_event", "is_morning"]:
        hit = u[flag].astype(int)
        cnt = hit.cumsum().shift(1).fillna(0)
        tot = (delay * hit).cumsum().shift(1).fillna(0)
        u[f"shrunk_avg_when_{flag}"] = (tot + K * u["shrunk_avg_delay"]) / (cnt + K)

    # how often they've been really late (10+ min) before
    u["prior_late_rate"] = (delay > 10).astype(int).cumsum().shift(1) / np.maximum(n, 1)
    return u


def build_features(df):
    df = df.sort_values(["start_time", "user_id"]).reset_index(drop=True)
    df["is_morning"] = df.hour < 10
    df = add_group_average(df)
    df = pd.concat([add_user_history(u.copy()) for _, u in df.groupby("user_id")])
    return df.sort_values(["start_time", "user_id"]).reset_index(drop=True)


if __name__ == "__main__":
    df = pd.read_csv("data/hangouts.csv", parse_dates=["start_time", "alert_time", "left_at", "arrived_at"])
    df = build_features(df)
    df.to_csv("data/features.csv", index=False)
    print(f"Saved data/features.csv with {len(df)} rows and {df.shape[1]} columns\n")

    # Check 1: a brand-new user starts at the group average, then learns their own habits
    uid = df[df.persona == "chronically_late"].user_id.iloc[0]
    cols = ["n_prior", "departure_delay_min", "prior_avg_delay", "shrunk_avg_delay"]
    print(f"Chronically late user {uid}, first 4 and last 2 hangouts:")
    u = df[df.user_id == uid][cols].round(1)
    print(pd.concat([u.head(4), u.tail(2)]).to_string(index=False), "\n")

    # Check 2: the rain feature separates rain haters from everyone else
    last = df.groupby("user_id").tail(1)
    print("Learned delay when raining, minus usual delay (end of year):")
    effect = (last.shrunk_avg_when_raining - last.shrunk_avg_delay).groupby(last.persona).mean()
    print(effect.round(1).sort_values(ascending=False).to_string(), "\n")

    # Check 3: history should actually predict the next delay
    later = df[df.n_prior >= 10]
    corr = later[["departure_delay_min", "shrunk_avg_delay", "recent_avg_delay"]].corr().iloc[0, 1:]
    print("Correlation with the actual delay (1.0 = perfect):")
    print(corr.round(2).to_string())