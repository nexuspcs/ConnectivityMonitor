"""Metrics engine — loss, avg, min, max, percentile, jitter, health, trend."""

import datetime
import math


def get_latency_values(state):
    """Extract non-None latency values from history."""
    return [h["latency"] for h in state.history if h.get("latency") is not None]


def loss(state):
    """Packet loss percentage."""
    total = len(state.history)
    if total == 0:
        return 0
    lost = sum(1 for h in state.history if h.get("latency") is None)
    return round((lost / total) * 100, 1)


def avg(state):
    """Average latency of successful pings."""
    vals = get_latency_values(state)
    if not vals:
        return 0
    return round(sum(vals) / len(vals), 1)


def min_lat(state):
    """Minimum latency."""
    vals = get_latency_values(state)
    if not vals:
        return 0
    return round(min(vals), 1)


def max_lat(state):
    """Maximum latency."""
    vals = get_latency_values(state)
    if not vals:
        return 0
    return round(max(vals), 1)


def percentile(state, pct):
    """Percentile latency (0-100)."""
    vals = sorted(get_latency_values(state))
    if not vals:
        return 0
    idx = int(math.floor(len(vals) * pct / 100))
    if idx >= len(vals):
        idx = len(vals) - 1
    return round(vals[idx], 1)


def jitter(state):
    """Average latency variation between consecutive pings."""
    vals = get_latency_values(state)
    if len(vals) < 2:
        return 0
    diffs = [abs(vals[i] - vals[i - 1]) for i in range(1, len(vals))]
    return round(sum(diffs) / len(diffs), 1)


def uptime(state):
    """Percentage of successful pings."""
    total = len(state.history)
    if total == 0:
        return 100.0
    ok = sum(1 for h in state.history if h.get("latency") is not None)
    return round((ok / total) * 100, 2)


def get_health_score(state):
    """Health score 0-100 with letter grade. Returns {score, grade, color}."""
    loss_pct = loss(state)
    avg_lat = avg(state)
    jitter_ms = jitter(state)
    score = 100

    score -= loss_pct * 3
    if avg_lat > 100:
        score -= 20
    elif avg_lat > 50:
        score -= 10
    elif avg_lat > 30:
        score -= 5
    if jitter_ms > 30:
        score -= 15
    elif jitter_ms > 15:
        score -= 8
    elif jitter_ms > 5:
        score -= 3

    score = max(0, min(100, round(score)))

    grade = "A+"
    color = "green"
    if score < 50:
        grade, color = "F", "red"
    elif score < 60:
        grade, color = "D", "red"
    elif score < 70:
        grade, color = "C", "yellow"
    elif score < 80:
        grade, color = "B", "yellow"
    elif score < 90:
        grade, color = "A", "green"

    return {"score": score, "grade": grade, "color": color}


def get_trend(state):
    """Detect latency trend from last 30 pings. Returns {arrow, label, color}."""
    recent = [
        h["latency"]
        for h in state.history[-30:]
        if h.get("latency") is not None
    ]
    if len(recent) < 10:
        return {"arrow": "->", "label": "Collecting", "color": "gray"}

    half = len(recent) // 2
    first_half = recent[:half]
    second_half = recent[half:]

    avg_first = sum(first_half) / len(first_half)
    avg_second = sum(second_half) / len(second_half)

    pct_change = 0
    if avg_first > 0:
        pct_change = ((avg_second - avg_first) / avg_first) * 100

    if pct_change > 20:
        return {"arrow": "^^", "label": "Degrading", "color": "red"}
    elif pct_change > 8:
        return {"arrow": "^ ", "label": "Rising", "color": "yellow"}
    elif pct_change < -20:
        return {"arrow": "vv", "label": "Improving", "color": "green"}
    elif pct_change < -8:
        return {"arrow": "v ", "label": "Falling", "color": "green"}
    else:
        return {"arrow": "->", "label": "Stable", "color": "cyan"}


def diagnose_issue(gw_ok, ext_ok):
    """Smart diagnostics — where is the problem? Returns {msg, color}."""
    if gw_ok and ext_ok:
        return {"msg": "All clear", "color": "green"}
    if not gw_ok and not ext_ok:
        return {"msg": "Local network down (gateway unreachable)", "color": "red"}
    if gw_ok and not ext_ok:
        return {"msg": "ISP / upstream issue (gateway OK, internet down)", "color": "yellow"}
    return {"msg": "Unusual state", "color": "orange"}


def get_network_weather(state):
    """Network weather icon based on health score."""
    health = get_health_score(state)
    s = health["score"]
    if s > 90:
        return {"label": "SUNNY", "color": "green"}
    elif s > 75:
        return {"label": "PARTLY CLOUDY", "color": "cyan"}
    elif s > 50:
        return {"label": "CLOUDY", "color": "gray"}
    elif s > 25:
        return {"label": "STORMY", "color": "orange"}
    else:
        return {"label": "HURRICANE", "color": "red"}


def update_history(state, lat, target):
    """Add a ping result to history and update per-target stats."""
    entry = {
        "time": datetime.datetime.now(),
        "latency": lat,
        "target": target,
    }
    state.history.append(entry)
    state.total_pings += 1
    if lat is not None:
        state.total_success += 1

    while len(state.history) > state.max_history:
        state.history.pop(0)

    # Per-target tracking
    if target not in state.per_target:
        state.per_target[target] = {"sent": 0, "ok": 0, "lats": []}
    state.per_target[target]["sent"] += 1
    if lat is not None:
        state.per_target[target]["ok"] += 1
        state.per_target[target]["lats"].append(lat)

    # Baseline learning (first 30 successful pings)
    if not state.baseline_locked and lat is not None:
        state.baseline_samples.append(lat)
        if len(state.baseline_samples) >= 30:
            state.baseline_latency = round(
                sum(state.baseline_samples) / len(state.baseline_samples), 1
            )
            state.baseline_locked = True


def update_gw_history(state, gw_lat):
    """Add a gateway ping result to gateway history."""
    entry = {"time": datetime.datetime.now(), "latency": gw_lat}
    state.gw_history.append(entry)
    while len(state.gw_history) > 200:
        state.gw_history.pop(0)


def update_hourly_data(state, lat):
    """Record latency data for hourly heatmap."""
    if lat is None:
        return
    hour = datetime.datetime.now().hour
    if hour not in state.hourly_data:
        state.hourly_data[hour] = []
    state.hourly_data[hour].append(lat)
