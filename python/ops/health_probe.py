#!/usr/bin/env python3
"""Health probe for Connectivity Monitor API with optional recovery actions."""

import argparse
import datetime
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request


def _now():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _read_state(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"consecutive_failures": 0, "last_status": "unknown"}


def _write_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def _fetch_status(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "ConnectivityMonitor/4.0 health-probe"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError("Non-200 status: {}".format(response.status))
        payload = json.loads(response.read().decode("utf-8"))
        return payload


def _evaluate(payload, min_health, max_loss):
    health = payload.get("health_score")
    loss = payload.get("loss")
    is_down = payload.get("is_down")

    problems = []
    if is_down:
        problems.append("monitor reports outage")
    if isinstance(health, (int, float)) and health < min_health:
        problems.append("health_score {} < {}".format(health, min_health))
    if isinstance(loss, (int, float)) and loss > max_loss:
        problems.append("loss {} > {}".format(loss, max_loss))
    return problems


def _maybe_reboot(enabled, command, reason):
    if not enabled:
        return
    print("[{}] WARNING: {}".format(_now(), reason))
    print("[{}] WARNING: Executing reboot command: {}".format(_now(), " ".join(command)))
    try:
        subprocess.run(command, check=True)
    except Exception as exc:
        print("[{}] ERROR: Reboot command failed: {}".format(_now(), exc), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Connectivity Monitor health probe")
    parser.add_argument("--url", default="http://127.0.0.1:8080/api/status")
    parser.add_argument("--timeout", type=int, default=5)
    parser.add_argument("--min-health", type=float, default=60.0)
    parser.add_argument("--max-loss", type=float, default=10.0)
    parser.add_argument(
        "--state-file",
        default=os.path.expanduser("~/ConnectivityMonitor/health_probe_state.json"),
    )
    parser.add_argument("--reboot-after-failures", type=int, default=0)
    parser.add_argument("--allow-reboot", action="store_true")
    parser.add_argument(
        "--reboot-cmd",
        default="/usr/bin/systemctl reboot",
        help="Command used when reboot is enabled (string split on spaces)",
    )
    args = parser.parse_args()

    state = _read_state(args.state_file)
    failures = int(state.get("consecutive_failures", 0))

    try:
        payload = _fetch_status(args.url, args.timeout)
        issues = _evaluate(payload, args.min_health, args.max_loss)
        if issues:
            failures += 1
            state["last_status"] = "degraded"
            state["last_error"] = "; ".join(issues)
            print("[{}] WARNING: {}".format(_now(), state["last_error"]))
        else:
            failures = 0
            state["last_status"] = "healthy"
            state["last_error"] = ""
            print(
                "[{}] OK: health_score={}, loss={}, total_pings={}".format(
                    _now(), payload.get("health_score"), payload.get("loss"), payload.get("total_pings")
                )
            )
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, RuntimeError) as exc:
        failures += 1
        state["last_status"] = "unreachable"
        state["last_error"] = str(exc)
        print("[{}] ERROR: {}".format(_now(), exc), file=sys.stderr)

    state["consecutive_failures"] = failures
    state["last_checked"] = _now()
    _write_state(args.state_file, state)

    if args.reboot_after_failures > 0 and failures >= args.reboot_after_failures:
        _maybe_reboot(
            args.allow_reboot,
            args.reboot_cmd.split(),
            "Consecutive failures ({}) reached reboot threshold ({})".format(
                failures, args.reboot_after_failures
            ),
        )
        sys.exit(2)

    if failures > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
