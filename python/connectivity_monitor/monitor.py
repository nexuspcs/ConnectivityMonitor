"""Main monitoring loop — ping cycle, drop detection, diagnostics."""

import datetime
import os
import sys
import time

from . import metrics
from .config import ensure_dirs
from .csv_logger import log_ping, log_drop, log_breach
from .html_report import generate_html_report, format_duration
from .network import (
    ping_test, dns_test, detect_gateway, get_local_ip,
    detect_public_ip, get_wifi_signal, start_traceroute,
)
from .state import MonitorState
from .web_server import start_web_server


def run_monitor(cfg):
    """Main entry point for the monitoring loop."""
    state = MonitorState()
    _, logs_dir, reports_dir = ensure_dirs()

    # Parse config
    targets_str = cfg.get("targets", "1.1.1.1,8.8.8.8,208.67.222.222")
    targets = [t.strip() for t in targets_str.split(",") if t.strip()]
    poll = cfg.get("poll", 2)
    threshold = cfg.get("threshold", 4)
    lat_warn = cfg.get("lat_warn", 100)
    enable_dns = cfg.get("enable_dns", True)
    dns_target = cfg.get("dns_target", "google.com")
    web_port = cfg.get("web_port", 8080)
    headless = cfg.get("headless", False)

    # Detect network info
    gateway = detect_gateway()
    local_ip = get_local_ip()

    if not headless:
        print()
        print(" Detecting public IP...")
    detect_public_ip(state)

    # Start web server
    try:
        server = start_web_server(web_port, state, reports_dir, logs_dir)
        if not headless:
            print(" Web dashboard: http://{}:{}".format(local_ip, web_port))
    except OSError as e:
        if not headless:
            print(" Warning: Could not start web server on port {}: {}".format(web_port, e))
        server = None

    if not headless:
        print(" Gateway: {}".format(gateway))
        print(" Local IP: {}".format(local_ip))
        print(" Public IP: {}".format(state.public_ip))
        print(" ISP: {}".format(state.isp_name))
        print(" Targets: {}".format(", ".join(targets)))
        print(" Poll: {}s | Threshold: {} | Lat warn: {}ms".format(poll, threshold, lat_warn))
        print()
        print(" Monitoring started. Press Ctrl+C to stop.")
        print(" " + "=" * 50)
        print()

    rr = 0  # Round-robin counter
    wifi_sig = None

    try:
        while not state.shutdown:
            target = targets[rr % len(targets)]
            rr += 1

            # Ping target
            p = ping_test(target)
            if p["ok"]:
                metrics.update_history(state, p["lat"], target)
            else:
                metrics.update_history(state, None, target)

            # Update hourly heatmap
            if p["ok"] and p.get("lat") is not None:
                metrics.update_hourly_data(state, p["lat"])

            # Ping gateway
            gw_result = {"ok": False, "lat": None}
            if gateway not in ("N/A", "None", ""):
                gw_result = ping_test(gateway)
                if gw_result["ok"]:
                    metrics.update_gw_history(state, gw_result["lat"])
                else:
                    metrics.update_gw_history(state, None)

            # DNS test
            dns_result = {"ok": True, "ms": None}
            if enable_dns:
                dns_result = dns_test(dns_target)

            # WiFi signal (every 5th iteration)
            if rr % 5 == 0:
                wifi_sig = get_wifi_signal()

            # Diagnose
            diag = metrics.diagnose_issue(gw_result["ok"], p["ok"])
            state.last_diagnosis = diag

            # Log every ping
            log_ping(state, logs_dir, p, gw_result, dns_result, wifi_sig)

            # Outage detection
            if not p["ok"]:
                state.fail_count += 1
                if state.fail_count >= threshold and not state.is_down:
                    state.is_down = True
                    state.down_start = datetime.datetime.now()
                    start_traceroute(target, state)
            else:
                if state.is_down:
                    end = datetime.datetime.now()
                    log_drop(state, logs_dir, state.down_start, end,
                             target, state.last_diagnosis["msg"])
                    state.is_down = False
                state.fail_count = 0

            # High latency threshold breach tracking
            if p["ok"] and p.get("lat") is not None and p["lat"] >= lat_warn:
                if not state.breach_active:
                    state.breach_active = True
                    state.breach_start = datetime.datetime.now()
            else:
                if state.breach_active:
                    breach_end = datetime.datetime.now()
                    log_breach(state, logs_dir, state.breach_start,
                               breach_end, metrics.avg(state))
                    state.breach_active = False

            # Re-detect public IP every 100 pings
            if state.total_pings % 100 == 0 and state.total_pings > 0:
                detect_public_ip(state)

            # Auto-generate HTML report every 500 pings
            if state.total_pings % 500 == 0 and state.total_pings > 0:
                auto_report = os.path.join(
                    reports_dir,
                    "report_{}.html".format(
                        datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
                    ),
                )
                generate_html_report(state, auto_report)

            # Re-detect gateway periodically (every 50 pings)
            if state.total_pings % 50 == 0 and state.total_pings > 0:
                new_gw = detect_gateway()
                if new_gw not in ("N/A", "None", ""):
                    gateway = new_gw

            # Console output (non-headless)
            if not headless:
                _print_status(state, p, gw_result, dns_result, target, gateway, wifi_sig)

            time.sleep(poll)

    except KeyboardInterrupt:
        pass

    # Shutdown
    _shutdown(state, logs_dir, reports_dir, headless)


def _print_status(state, p, gw, dns, target, gateway, wifi_sig):
    """Print one-line status to console."""
    health = metrics.get_health_score(state)
    trend = metrics.get_trend(state)
    elapsed = datetime.datetime.now() - state.session_start

    status = "OK" if p["ok"] else "FAIL"
    lat_str = "{}ms".format(p["lat"]) if p.get("lat") is not None else "---"
    gw_str = "{}ms".format(gw["lat"]) if gw.get("ok") and gw.get("lat") is not None else "---"

    line = (
        " [{time}] {status:4s} | {target:15s} | Lat: {lat:>7s} | "
        "GW: {gw:>7s} | Loss: {loss:>5s}% | "
        "Avg: {avg:>6s}ms | Health: {score}/100 ({grade}) | "
        "Trend: {trend} | Pings: {pings}"
    ).format(
        time=datetime.datetime.now().strftime("%H:%M:%S"),
        status=status,
        target=target,
        lat=lat_str,
        gw=gw_str,
        loss=str(metrics.loss(state)),
        avg=str(metrics.avg(state)),
        score=health["score"],
        grade=health["grade"],
        trend=trend["label"],
        pings=state.total_pings,
    )
    print(line)


def _shutdown(state, logs_dir, reports_dir, headless):
    """Clean shutdown — log final state and generate report."""
    if not headless:
        print()
        print(" Shutting down...")

    # Log any active outage
    if state.is_down:
        end = datetime.datetime.now()
        log_drop(state, logs_dir, state.down_start, end, "N/A",
                 "Session ended during outage")

    # Log any active breach
    if state.breach_active:
        breach_end = datetime.datetime.now()
        log_breach(state, logs_dir, state.breach_start, breach_end,
                   metrics.avg(state))

    # Generate final HTML report
    final_report = os.path.join(
        reports_dir,
        "report_{}.html".format(
            datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
        ),
    )
    generate_html_report(state, final_report)

    if not headless:
        elapsed = datetime.datetime.now() - state.session_start
        health = metrics.get_health_score(state)

        print()
        print(" " + "=" * 50)
        print(" SESSION SUMMARY")
        print(" " + "=" * 50)
        print(" Duration     : {}".format(format_duration(elapsed)))
        print(" Total Pings  : {}".format(state.total_pings))
        print(" Successful   : {}".format(state.total_success))
        print(" Packet Loss  : {}%".format(metrics.loss(state)))
        print(" Avg Latency  : {}ms".format(metrics.avg(state)))
        print(" Min Latency  : {}ms".format(metrics.min_lat(state)))
        print(" Max Latency  : {}ms".format(metrics.max_lat(state)))
        print(" P95 Latency  : {}ms".format(metrics.percentile(state, 95)))
        print(" Jitter       : {}ms".format(metrics.jitter(state)))
        print(" Health Score : {}/100 ({})".format(health["score"], health["grade"]))
        print(" Uptime       : {}%".format(metrics.uptime(state)))
        print(" Drops        : {}".format(len(state.drops)))
        print()
        print(" Files saved to:")
        print("   HTML report : {}".format(final_report))
        print("   Logs dir    : {}".format(logs_dir))
        print()
        print(" Monitor stopped.")
