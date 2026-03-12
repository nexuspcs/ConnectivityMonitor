"""CSV logging with daily rotation — ping log, drop log, breach log."""

import csv
import datetime
import os

from . import metrics


def get_log_paths(logs_dir, date_str=None):
    """Return paths for the 3 daily log files."""
    if date_str is None:
        date_str = datetime.date.today().isoformat()
    return {
        "ping": os.path.join(logs_dir, "ping_log_{}.csv".format(date_str)),
        "drop": os.path.join(logs_dir, "drops_{}.csv".format(date_str)),
        "breach": os.path.join(logs_dir, "breaches_{}.csv".format(date_str)),
    }


def check_date_roll(state, logs_dir):
    """Check if date has changed and update log paths."""
    today = datetime.date.today().isoformat()
    if today != state.current_date:
        state.current_date = today
    return get_log_paths(logs_dir, today)


# ================================================================
#  PING LOG — 18 columns matching PowerShell version
# ================================================================

PING_HEADERS = [
    "Timestamp", "Target", "Success", "LatencyMs", "GatewayMs",
    "DnsMs", "WifiSignalPct", "PacketLossPct", "AvgLatencyMs",
    "JitterMs", "P95Ms", "UptimePct", "Trend", "HealthScore",
    "HealthGrade", "BaselineMs", "PublicIP", "ISP",
]


def log_ping(state, logs_dir, ping_result, gw_result, dns_result, wifi_sig):
    """Log a single ping result to daily CSV."""
    paths = check_date_roll(state, logs_dir)
    filepath = paths["ping"]

    lat_val = ""
    if ping_result.get("lat") is not None:
        lat_val = ping_result["lat"]

    gw_val = ""
    if gw_result and gw_result.get("ok") and gw_result.get("lat") is not None:
        gw_val = gw_result["lat"]

    dns_val = ""
    if dns_result and dns_result.get("ok") and dns_result.get("ms") is not None:
        dns_val = dns_result["ms"]

    wifi_val = ""
    if wifi_sig is not None:
        wifi_val = wifi_sig

    trend = metrics.get_trend(state)
    health = metrics.get_health_score(state)

    bl_val = ""
    if state.baseline_latency is not None:
        bl_val = state.baseline_latency

    row = {
        "Timestamp": ping_result["time"].strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "Target": ping_result["target"],
        "Success": ping_result["ok"],
        "LatencyMs": lat_val,
        "GatewayMs": gw_val,
        "DnsMs": dns_val,
        "WifiSignalPct": wifi_val,
        "PacketLossPct": metrics.loss(state),
        "AvgLatencyMs": metrics.avg(state),
        "JitterMs": metrics.jitter(state),
        "P95Ms": metrics.percentile(state, 95),
        "UptimePct": metrics.uptime(state),
        "Trend": trend["label"],
        "HealthScore": health["score"],
        "HealthGrade": health["grade"],
        "BaselineMs": bl_val,
        "PublicIP": state.public_ip,
        "ISP": state.isp_name,
    }

    _write_csv_row(filepath, PING_HEADERS, row)


# ================================================================
#  DROP LOG — 5 columns
# ================================================================

DROP_HEADERS = ["Start", "End", "Duration", "Target", "Diagnosis"]


def log_drop(state, logs_dir, start, end, target, diagnosis):
    """Log a connectivity drop event."""
    paths = check_date_roll(state, logs_dir)
    filepath = paths["drop"]

    dur = round((end - start).total_seconds(), 2)
    row = {
        "Start": start.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "End": end.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "Duration": dur,
        "Target": target,
        "Diagnosis": diagnosis,
    }

    _write_csv_row(filepath, DROP_HEADERS, row)

    # Also store in state
    state.drops.append(row)


# ================================================================
#  BREACH LOG — 4 columns
# ================================================================

BREACH_HEADERS = ["Start", "End", "Duration", "AvgLatency"]


def log_breach(state, logs_dir, start, end, avg_lat):
    """Log a high-latency threshold breach event."""
    paths = check_date_roll(state, logs_dir)
    filepath = paths["breach"]

    dur = round((end - start).total_seconds(), 2)
    row = {
        "Start": start.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "End": end.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
        "Duration": dur,
        "AvgLatency": avg_lat,
    }

    _write_csv_row(filepath, BREACH_HEADERS, row)

    # Also store in state
    state.threshold_breaches.append(row)


# ================================================================
#  CSV HELPER
# ================================================================

def _write_csv_row(filepath, headers, row_dict):
    """Append a row to CSV file, creating with headers if new."""
    file_exists = os.path.exists(filepath)
    with open(filepath, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        if not file_exists:
            writer.writeheader()
        writer.writerow(row_dict)
