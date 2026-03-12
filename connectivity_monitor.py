#!/usr/bin/env python3
"""
Connectivity Monitor - Cross-Platform Edition
Lightweight connectivity and DNS monitoring for Linux, macOS, and Raspberry Pi.

Features:
  - Ping monitoring with round-robin targets
  - DNS resolution testing with latency measurement
  - Gateway detection and ping monitoring
  - Built-in HTTP/JSON API so other devices can query status
  - CSV logging with daily rotation
  - JSON configuration
  - Headless-friendly output for Raspberry Pi / SSH sessions
  - Graceful shutdown with session summary

Usage:
  python3 connectivity_monitor.py                 # interactive setup
  python3 connectivity_monitor.py --config cm.json # use saved config
  python3 connectivity_monitor.py --headless       # no interactive prompts
  python3 connectivity_monitor.py --api-port 8080  # HTTP API on port 8080

Requires: Python 3.6+  (standard library only, no pip packages)
"""

import argparse
import csv
import datetime
import http.server
import io
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import threading
import time

# ============================================================================
#  VERSION
# ============================================================================
VERSION = "1.0.0"

# ============================================================================
#  DEFAULTS
# ============================================================================
DEFAULT_TARGETS = ["1.1.1.1", "8.8.8.8", "208.67.222.222"]
DEFAULT_POLL = 2
DEFAULT_THRESHOLD = 4
DEFAULT_LAT_WARN = 100
DEFAULT_DNS_TARGET = "google.com"
DEFAULT_API_PORT = 8080

# ============================================================================
#  CROSS-PLATFORM HELPERS
# ============================================================================
IS_MAC = platform.system() == "Darwin"
IS_LINUX = platform.system() == "Linux"
IS_WINDOWS = platform.system() == "Windows"


def _home_dir():
    return os.path.expanduser("~")


def _base_dir():
    return os.path.join(_home_dir(), "ConnectivityMonitor")


def _ensure_dirs():
    base = _base_dir()
    for sub in ("logs", "reports"):
        path = os.path.join(base, sub)
        os.makedirs(path, exist_ok=True)
    return base


# ============================================================================
#  NETWORK UTILITIES
# ============================================================================

def ping(target, timeout=2):
    """Send a single ICMP echo and return (ok, latency_ms, target, timestamp)."""
    ts = datetime.datetime.now()
    try:
        if IS_WINDOWS:
            cmd = ["ping", "-n", "1", "-w", str(timeout * 1000), target]
        elif IS_MAC:
            cmd = ["ping", "-c", "1", "-W", str(timeout * 1000), target]
        else:
            cmd = ["ping", "-c", "1", "-W", str(timeout), target]

        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout + 5
        )
        if result.returncode == 0:
            # Extract latency from output
            lat = _parse_ping_latency(result.stdout)
            return {"ok": True, "lat": lat, "target": target, "time": ts}
        return {"ok": False, "lat": None, "target": target, "time": ts}
    except Exception:
        return {"ok": False, "lat": None, "target": target, "time": ts}


def _parse_ping_latency(output):
    """Extract round-trip latency in ms from ping output."""
    import re
    # Linux/macOS: "time=12.3 ms" or "time=12 ms"
    m = re.search(r"time[=<]\s*([\d.]+)\s*ms", output, re.IGNORECASE)
    if m:
        return float(m.group(1))
    return None


def dns_test(hostname):
    """Resolve hostname and measure time in ms."""
    try:
        start = time.monotonic()
        socket.getaddrinfo(hostname, None)
        elapsed = (time.monotonic() - start) * 1000
        return {"ok": True, "ms": round(elapsed, 1)}
    except Exception:
        return {"ok": False, "ms": None}


def detect_gateway():
    """Return the default gateway IP address."""
    try:
        if IS_MAC:
            out = subprocess.run(
                ["netstat", "-rn"],
                capture_output=True, text=True, timeout=5
            )
            for line in out.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "default":
                    gw = parts[1]
                    # Validate it looks like an IP
                    if _is_ipv4(gw):
                        return gw
        elif IS_LINUX:
            out = subprocess.run(
                ["ip", "route", "show", "default"],
                capture_output=True, text=True, timeout=5
            )
            parts = out.stdout.strip().split()
            if "via" in parts:
                idx = parts.index("via") + 1
                if idx < len(parts):
                    return parts[idx]
        elif IS_WINDOWS:
            out = subprocess.run(
                ["powershell", "-Command",
                 "(Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway}).IPv4DefaultGateway.NextHop"],
                capture_output=True, text=True, timeout=10
            )
            gw = out.stdout.strip().splitlines()
            if gw:
                return gw[0].strip()
    except Exception:
        pass
    return None


def _is_ipv4(s):
    try:
        parts = s.split(".")
        return len(parts) == 4 and all(0 <= int(p) <= 255 for p in parts)
    except Exception:
        return False


def detect_local_ip():
    """Best-effort detection of the primary local IP."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "N/A"


def detect_interface():
    """Return the name of the default network interface."""
    try:
        if IS_LINUX:
            out = subprocess.run(
                ["ip", "route", "show", "default"],
                capture_output=True, text=True, timeout=5
            )
            parts = out.stdout.strip().split()
            if "dev" in parts:
                idx = parts.index("dev") + 1
                if idx < len(parts):
                    return parts[idx]
        elif IS_MAC:
            out = subprocess.run(
                ["route", "-n", "get", "default"],
                capture_output=True, text=True, timeout=5
            )
            for line in out.stdout.splitlines():
                if "interface:" in line:
                    return line.split(":")[1].strip()
    except Exception:
        pass
    return "unknown"


# ============================================================================
#  STATE
# ============================================================================

class MonitorState:
    """Holds all runtime state for the monitoring session."""

    def __init__(self):
        self.session_start = datetime.datetime.now()
        self.total_pings = 0
        self.total_success = 0
        self.fail_count = 0
        self.is_down = False
        self.down_start = None
        self.drops = []          # list of outage dicts
        self.history = []        # recent ping results (capped)
        self.max_history = 500
        self.per_target = {}     # target -> {count, success, total_lat}
        self.latencies = []      # recent latencies for stats
        self.max_latencies = 500
        self.gateway_latencies = []
        self.dns_times = []
        self.breaches = []       # high-latency events
        self.in_breach = False
        self.breach_start = None
        self.breach_lats = []
        self.shutdown = False

        # Detected info
        self.gateway = None
        self.local_ip = "N/A"
        self.interface = "unknown"

    # -- Statistics ----------------------------------------------------------

    def record_ping(self, result):
        self.total_pings += 1
        target = result["target"]

        if target not in self.per_target:
            self.per_target[target] = {"count": 0, "success": 0, "total_lat": 0.0}

        self.per_target[target]["count"] += 1

        if result["ok"]:
            self.total_success += 1
            self.per_target[target]["success"] += 1
            if result["lat"] is not None:
                self.per_target[target]["total_lat"] += result["lat"]
                self.latencies.append(result["lat"])
                if len(self.latencies) > self.max_latencies:
                    self.latencies.pop(0)

        self.history.append(result)
        if len(self.history) > self.max_history:
            self.history.pop(0)

    def record_gateway(self, result):
        if result and result["ok"] and result["lat"] is not None:
            self.gateway_latencies.append(result["lat"])
            if len(self.gateway_latencies) > self.max_latencies:
                self.gateway_latencies.pop(0)

    def record_dns(self, result):
        if result["ok"] and result["ms"] is not None:
            self.dns_times.append(result["ms"])
            if len(self.dns_times) > self.max_latencies:
                self.dns_times.pop(0)

    @property
    def uptime_pct(self):
        if self.total_pings == 0:
            return 100.0
        return round(self.total_success / self.total_pings * 100, 2)

    @property
    def loss_pct(self):
        return round(100.0 - self.uptime_pct, 2)

    @property
    def avg_latency(self):
        if not self.latencies:
            return None
        return round(sum(self.latencies) / len(self.latencies), 1)

    @property
    def min_latency(self):
        return round(min(self.latencies), 1) if self.latencies else None

    @property
    def max_latency(self):
        return round(max(self.latencies), 1) if self.latencies else None

    @property
    def jitter(self):
        if len(self.latencies) < 2:
            return None
        diffs = [abs(self.latencies[i] - self.latencies[i - 1])
                 for i in range(1, len(self.latencies))]
        return round(sum(diffs) / len(diffs), 1)

    def percentile(self, pct):
        if not self.latencies:
            return None
        s = sorted(self.latencies)
        idx = int(len(s) * pct / 100)
        idx = min(idx, len(s) - 1)
        return round(s[idx], 1)

    @property
    def health_score(self):
        score = 100
        if self.loss_pct > 0:
            score -= min(self.loss_pct * 5, 40)
        avg = self.avg_latency
        if avg is not None:
            if avg > 200:
                score -= 30
            elif avg > 100:
                score -= 15
            elif avg > 50:
                score -= 5
        j = self.jitter
        if j is not None:
            if j > 50:
                score -= 15
            elif j > 20:
                score -= 5
        return max(0, min(100, round(score)))

    @property
    def health_grade(self):
        s = self.health_score
        if s >= 90:
            return "A"
        if s >= 75:
            return "B"
        if s >= 60:
            return "C"
        if s >= 40:
            return "D"
        return "F"

    def session_duration(self):
        return datetime.datetime.now() - self.session_start

    def _recent_dns_stats(self):
        if not self.dns_times:
            return {"avg_ms": None, "last_ms": None}
        recent = self.dns_times[-20:]
        return {
            "avg_ms": round(sum(recent) / len(recent), 1),
            "last_ms": self.dns_times[-1],
        }

    def status_dict(self):
        """Return a JSON-serialisable status snapshot."""
        dur = self.session_duration()
        return {
            "version": VERSION,
            "platform": platform.system(),
            "hostname": socket.gethostname(),
            "timestamp": datetime.datetime.now().isoformat(),
            "session_start": self.session_start.isoformat(),
            "session_duration_s": int(dur.total_seconds()),
            "interface": self.interface,
            "local_ip": self.local_ip,
            "gateway": self.gateway,
            "total_pings": self.total_pings,
            "total_success": self.total_success,
            "uptime_pct": self.uptime_pct,
            "loss_pct": self.loss_pct,
            "avg_latency_ms": self.avg_latency,
            "min_latency_ms": self.min_latency,
            "max_latency_ms": self.max_latency,
            "jitter_ms": self.jitter,
            "p95_ms": self.percentile(95),
            "health_score": self.health_score,
            "health_grade": self.health_grade,
            "is_down": self.is_down,
            "outages": len(self.drops),
            "high_latency_events": len(self.breaches),
            "per_target": {
                t: {
                    "pings": d["count"],
                    "success": d["success"],
                    "loss_pct": round((1 - d["success"] / d["count"]) * 100, 2) if d["count"] else 0,
                    "avg_ms": round(d["total_lat"] / d["success"], 1) if d["success"] else None,
                }
                for t, d in self.per_target.items()
            },
            "recent_dns": self._recent_dns_stats(),
        }


# ============================================================================
#  CSV LOGGING
# ============================================================================

class CsvLogger:
    """Handles daily-rotating CSV log files."""

    def __init__(self, base_dir):
        self.logs_dir = os.path.join(base_dir, "logs")
        self._current_date = None
        self._ping_file = None
        self._drop_file = None

    def _rotate(self):
        today = datetime.date.today().isoformat()
        if today != self._current_date:
            self._current_date = today
            self._ping_file = os.path.join(self.logs_dir, f"ping_log_{today}.csv")
            self._drop_file = os.path.join(self.logs_dir, f"drops_{today}.csv")

    def log_ping(self, result, gw_result, dns_result, state):
        self._rotate()
        file_exists = os.path.isfile(self._ping_file)
        row = {
            "Timestamp": result["time"].strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
            "Target": result["target"],
            "Success": result["ok"],
            "LatencyMs": result["lat"] if result["lat"] is not None else "",
            "GatewayMs": gw_result["lat"] if gw_result and gw_result["ok"] and gw_result["lat"] is not None else "",
            "DnsMs": dns_result["ms"] if dns_result["ok"] and dns_result["ms"] is not None else "",
            "PacketLossPct": state.loss_pct,
            "AvgLatencyMs": state.avg_latency if state.avg_latency is not None else "",
            "JitterMs": state.jitter if state.jitter is not None else "",
            "P95Ms": state.percentile(95) if state.percentile(95) is not None else "",
            "UptimePct": state.uptime_pct,
            "HealthScore": state.health_score,
            "HealthGrade": state.health_grade,
        }
        with open(self._ping_file, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(row.keys()))
            if not file_exists:
                writer.writeheader()
            writer.writerow(row)

    def log_drop(self, drop):
        self._rotate()
        file_exists = os.path.isfile(self._drop_file)
        row = {
            "Start": drop["start"],
            "End": drop["end"],
            "DurationSec": drop["duration_s"],
            "Target": drop.get("target", ""),
        }
        with open(self._drop_file, "a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(row.keys()))
            if not file_exists:
                writer.writeheader()
            writer.writerow(row)


# ============================================================================
#  HTTP API SERVER
# ============================================================================

class ApiHandler(http.server.BaseHTTPRequestHandler):
    """Minimal HTTP handler that serves monitoring status as JSON."""

    state = None  # set by the server thread

    def do_GET(self):
        if self.path == "/" or self.path == "/status":
            self._json_response(self.state.status_dict())
        elif self.path == "/health":
            data = {
                "status": "down" if self.state.is_down else "up",
                "health_score": self.state.health_score,
                "health_grade": self.state.health_grade,
                "uptime_pct": self.state.uptime_pct,
            }
            self._json_response(data)
        elif self.path == "/dns":
            result = dns_test(DEFAULT_DNS_TARGET)
            result["target"] = DEFAULT_DNS_TARGET
            self._json_response(result)
        elif self.path == "/ping":
            target = DEFAULT_TARGETS[0] if DEFAULT_TARGETS else "1.1.1.1"
            result = ping(target)
            result["time"] = result["time"].isoformat()
            self._json_response(result)
        elif self.path == "/drops":
            self._json_response({"outages": self.state.drops})
        else:
            self.send_error(404, "Not Found. Try /status, /health, /dns, /ping, or /drops")

    def _json_response(self, data):
        body = json.dumps(data, indent=2, default=str).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        """Suppress default stderr logging."""
        pass


def start_api_server(port, state, bind="0.0.0.0"):
    """Start the HTTP API server in a daemon thread."""
    ApiHandler.state = state
    server = http.server.HTTPServer((bind, port), ApiHandler)
    server.timeout = 1
    thread = threading.Thread(target=_serve_forever, args=(server,), daemon=True)
    thread.start()
    return server


def _serve_forever(server):
    """Serve until the main thread signals shutdown."""
    while True:
        try:
            server.handle_request()
        except Exception:
            break


# ============================================================================
#  CONFIGURATION
# ============================================================================

def load_config(path):
    """Load JSON config from file."""
    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)
    return None


def save_config(path, cfg):
    """Persist config to JSON file."""
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def interactive_setup(config_path):
    """Prompt user for configuration settings."""
    existing = load_config(config_path)
    if existing:
        print(f"\n  Saved config found: {config_path}")
        print(f"    Targets   : {existing.get('targets', DEFAULT_TARGETS)}")
        print(f"    Poll (s)  : {existing.get('poll', DEFAULT_POLL)}")
        print(f"    DNS target: {existing.get('dns_target', DEFAULT_DNS_TARGET)}")
        print(f"    API port  : {existing.get('api_port', DEFAULT_API_PORT)}")
        reuse = input("  Use saved config? [Y/n] ").strip().lower()
        if reuse != "n":
            return existing

    cfg = {}
    print("\n  === Connectivity Monitor Setup ===\n")

    targets_str = input(
        f"  Ping targets (comma-separated) [{','.join(DEFAULT_TARGETS)}]: "
    ).strip()
    cfg["targets"] = [t.strip() for t in targets_str.split(",") if t.strip()] if targets_str else DEFAULT_TARGETS

    poll_str = input(f"  Poll interval seconds [{DEFAULT_POLL}]: ").strip()
    cfg["poll"] = int(poll_str) if poll_str.isdigit() else DEFAULT_POLL

    thresh_str = input(f"  Failure threshold (pings) [{DEFAULT_THRESHOLD}]: ").strip()
    cfg["threshold"] = int(thresh_str) if thresh_str.isdigit() else DEFAULT_THRESHOLD

    lat_str = input(f"  Latency warning (ms) [{DEFAULT_LAT_WARN}]: ").strip()
    cfg["lat_warn"] = int(lat_str) if lat_str.isdigit() else DEFAULT_LAT_WARN

    dns_en = input(f"  Enable DNS checks? [Y/n]: ").strip().lower()
    cfg["enable_dns"] = dns_en != "n"

    dns_tgt = input(f"  DNS test hostname [{DEFAULT_DNS_TARGET}]: ").strip()
    cfg["dns_target"] = dns_tgt if dns_tgt else DEFAULT_DNS_TARGET

    port_str = input(f"  HTTP API port (0=disabled) [{DEFAULT_API_PORT}]: ").strip()
    cfg["api_port"] = int(port_str) if port_str.isdigit() else DEFAULT_API_PORT

    save_config(config_path, cfg)
    print(f"  Config saved to {config_path}\n")
    return cfg


def headless_config(args):
    """Build config from CLI args without interactive prompts."""
    cfg = {}
    if args.config and os.path.isfile(args.config):
        cfg = load_config(args.config) or {}
    # CLI args override file values
    if args.targets:
        cfg["targets"] = [t.strip() for t in args.targets.split(",")]
    cfg.setdefault("targets", DEFAULT_TARGETS)
    cfg.setdefault("poll", DEFAULT_POLL)
    cfg.setdefault("threshold", DEFAULT_THRESHOLD)
    cfg.setdefault("lat_warn", DEFAULT_LAT_WARN)
    cfg.setdefault("enable_dns", True)
    cfg.setdefault("dns_target", DEFAULT_DNS_TARGET)
    if args.api_port is not None:
        cfg["api_port"] = args.api_port
    cfg.setdefault("api_port", DEFAULT_API_PORT)
    if getattr(args, "api_bind", None) is not None:
        cfg["api_bind"] = args.api_bind
    cfg.setdefault("api_bind", "0.0.0.0")
    return cfg


# ============================================================================
#  DISPLAY
# ============================================================================

def print_banner():
    print()
    print("  =====================================================")
    print("   CONNECTIVITY MONITOR v{} - Cross-Platform".format(VERSION))
    print("   {} | Python {}".format(platform.system(), platform.python_version()))
    print("  =====================================================")
    print()


def print_status_line(result, gw_result, dns_result, state, cfg):
    """Print a single-line status update."""
    ts = result["time"].strftime("%H:%M:%S")

    if result["ok"]:
        lat_str = f"{result['lat']:.1f}ms" if result["lat"] is not None else "OK"
        warn = " !! HIGH" if result["lat"] is not None and result["lat"] >= cfg["lat_warn"] else ""
        status = f"  {ts}  OK  {result['target']:>15s}  {lat_str}{warn}"
    else:
        status = f"  {ts}  FAIL  {result['target']:>15s}  --"

    gw_str = ""
    if gw_result:
        if gw_result["ok"]:
            gw_str = f"  GW:{gw_result['lat']:.0f}ms" if gw_result["lat"] else "  GW:OK"
        else:
            gw_str = "  GW:FAIL"

    dns_str = ""
    if cfg.get("enable_dns") and dns_result:
        if dns_result["ok"]:
            dns_str = f"  DNS:{dns_result['ms']:.0f}ms"
        else:
            dns_str = "  DNS:FAIL"

    loss_str = f"  Loss:{state.loss_pct:.1f}%"
    health_str = f"  [{state.health_grade}:{state.health_score}]"

    print(f"{status}{gw_str}{dns_str}{loss_str}{health_str}")


def print_summary(state, cfg, base_dir):
    """Print end-of-session summary."""
    dur = state.session_duration()
    hours = int(dur.total_seconds() // 3600)
    mins = int((dur.total_seconds() % 3600) // 60)
    secs = int(dur.total_seconds() % 60)

    print()
    print("  =====================================================")
    print("   SESSION SUMMARY")
    print("  =====================================================")
    print(f"   Duration       : {hours}h {mins}m {secs}s")
    print(f"   Total pings    : {state.total_pings}")
    print(f"   Successful     : {state.total_success}")
    print(f"   Packet loss    : {state.loss_pct}%")
    print(f"   Uptime         : {state.uptime_pct}%")
    if state.avg_latency is not None:
        print(f"   Avg latency    : {state.avg_latency} ms")
    if state.min_latency is not None:
        print(f"   Min latency    : {state.min_latency} ms")
    if state.max_latency is not None:
        print(f"   Max latency    : {state.max_latency} ms")
    if state.jitter is not None:
        print(f"   Jitter         : {state.jitter} ms")
    p95 = state.percentile(95)
    if p95 is not None:
        print(f"   P95 latency    : {p95} ms")
    print(f"   Health         : {state.health_grade} ({state.health_score}/100)")
    print(f"   Outages        : {len(state.drops)}")
    if state.drops:
        for i, d in enumerate(state.drops, 1):
            print(f"     #{i}  {d['start']} -> {d['end']}  ({d['duration_s']}s)")
    print(f"   Logs dir       : {os.path.join(base_dir, 'logs')}")
    print()

    # Per-target breakdown
    if state.per_target:
        print("   Per-target breakdown:")
        for t, d in state.per_target.items():
            loss = round((1 - d["success"] / d["count"]) * 100, 1) if d["count"] else 0
            avg = round(d["total_lat"] / d["success"], 1) if d["success"] else None
            avg_str = f"{avg}ms" if avg is not None else "--"
            print(f"     {t:>15s}  pings:{d['count']}  loss:{loss}%  avg:{avg_str}")
        print()


# ============================================================================
#  MAIN MONITORING LOOP
# ============================================================================

def run_monitor(cfg, base_dir, headless=False):
    """Core monitoring loop."""
    state = MonitorState()
    logger = CsvLogger(base_dir)

    targets = cfg["targets"]
    poll = cfg["poll"]
    threshold = cfg["threshold"]
    lat_warn = cfg["lat_warn"]
    enable_dns = cfg.get("enable_dns", True)
    dns_target = cfg.get("dns_target", DEFAULT_DNS_TARGET)
    api_port = cfg.get("api_port", 0)
    api_bind = cfg.get("api_bind", "0.0.0.0")

    # Detect network info
    state.gateway = detect_gateway()
    state.local_ip = detect_local_ip()
    state.interface = detect_interface()

    print(f"  Interface : {state.interface}")
    print(f"  Local IP  : {state.local_ip}")
    print(f"  Gateway   : {state.gateway or 'N/A'}")
    print(f"  Targets   : {', '.join(targets)}")
    print(f"  Poll      : {poll}s | Threshold: {threshold} | Latency warn: {lat_warn}ms")
    if enable_dns:
        print(f"  DNS check : {dns_target}")

    # Start API server
    api_server = None
    if api_port and api_port > 0:
        try:
            api_server = start_api_server(api_port, state, bind=api_bind)
            print(f"  HTTP API  : http://{state.local_ip}:{api_port}/status")
        except OSError as e:
            print(f"  HTTP API  : Failed to start on port {api_port}: {e}")

    print()
    print("  Monitoring started. Press Ctrl+C to stop.")
    print("  " + "-" * 70)

    # Signal handler
    def handle_signal(sig, frame):
        state.shutdown = True

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    rr = 0  # round-robin index
    try:
        while not state.shutdown:
            target = targets[rr % len(targets)]
            rr += 1

            # Ping target
            p = ping(target)
            state.record_ping(p)

            # Ping gateway
            gw_result = None
            if state.gateway:
                gw_result = ping(state.gateway, timeout=2)
                state.record_gateway(gw_result)

            # DNS test
            dns_result = {"ok": True, "ms": None}
            if enable_dns:
                dns_result = dns_test(dns_target)
                state.record_dns(dns_result)

            # Log to CSV
            logger.log_ping(p, gw_result, dns_result, state)

            # Outage detection
            if not p["ok"]:
                state.fail_count += 1
                if state.fail_count >= threshold and not state.is_down:
                    state.is_down = True
                    state.down_start = datetime.datetime.now()
                    print(f"\n  *** OUTAGE DETECTED at {state.down_start.strftime('%H:%M:%S')} ***\n")
            else:
                if state.is_down:
                    # Outage ended
                    end_time = datetime.datetime.now()
                    duration = (end_time - state.down_start).total_seconds()
                    drop = {
                        "start": state.down_start.strftime("%Y-%m-%d %H:%M:%S"),
                        "end": end_time.strftime("%Y-%m-%d %H:%M:%S"),
                        "duration_s": round(duration, 1),
                        "target": target,
                    }
                    state.drops.append(drop)
                    logger.log_drop(drop)
                    print(f"\n  *** OUTAGE ENDED - duration {duration:.1f}s ***\n")
                    state.is_down = False
                    state.down_start = None
                state.fail_count = 0

            # High latency breach detection
            if p["ok"] and p["lat"] is not None and p["lat"] >= lat_warn:
                if not state.in_breach:
                    state.in_breach = True
                    state.breach_start = datetime.datetime.now()
                    state.breach_lats = [p["lat"]]
                else:
                    state.breach_lats.append(p["lat"])
            else:
                if state.in_breach:
                    end_time = datetime.datetime.now()
                    dur_s = (end_time - state.breach_start).total_seconds()
                    avg_lat = sum(state.breach_lats) / len(state.breach_lats)
                    state.breaches.append({
                        "start": state.breach_start.strftime("%Y-%m-%d %H:%M:%S"),
                        "end": end_time.strftime("%Y-%m-%d %H:%M:%S"),
                        "duration_s": round(dur_s, 1),
                        "avg_latency_ms": round(avg_lat, 1),
                    })
                    state.in_breach = False

            # Re-detect gateway periodically (every 50 pings)
            if state.total_pings % 50 == 0:
                state.gateway = detect_gateway()
                state.local_ip = detect_local_ip()

            # Display
            print_status_line(p, gw_result, dns_result, state, cfg)

            # Sleep
            time.sleep(poll)

    except Exception as e:
        print(f"\n  Error: {e}")
    finally:
        # Close any ongoing outage
        if state.is_down and state.down_start:
            end_time = datetime.datetime.now()
            duration = (end_time - state.down_start).total_seconds()
            drop = {
                "start": state.down_start.strftime("%Y-%m-%d %H:%M:%S"),
                "end": end_time.strftime("%Y-%m-%d %H:%M:%S"),
                "duration_s": round(duration, 1),
                "target": "session-end",
            }
            state.drops.append(drop)
            logger.log_drop(drop)

        print_summary(state, cfg, base_dir)

        if api_server:
            api_server.server_close()


# ============================================================================
#  CLI ENTRY POINT
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Connectivity Monitor - Cross-Platform (Linux / macOS / Raspberry Pi)"
    )
    parser.add_argument(
        "--config", "-c",
        help="Path to JSON config file",
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Run without interactive prompts (use defaults or --config)",
    )
    parser.add_argument(
        "--targets", "-t",
        help="Comma-separated ping targets (e.g. 1.1.1.1,8.8.8.8)",
    )
    parser.add_argument(
        "--api-port", "-p",
        type=int,
        default=None,
        help=f"HTTP API port (default: {DEFAULT_API_PORT}, 0 to disable)",
    )
    parser.add_argument(
        "--api-bind",
        default=None,
        help="HTTP API bind address (default: 0.0.0.0 — all interfaces; use 127.0.0.1 for local only)",
    )
    parser.add_argument(
        "--version", "-v",
        action="version",
        version=f"Connectivity Monitor v{VERSION}",
    )
    args = parser.parse_args()

    print_banner()

    base_dir = _ensure_dirs()
    config_path = args.config or os.path.join(base_dir, "monitor_config.json")

    if args.headless:
        cfg = headless_config(args)
    else:
        cfg = interactive_setup(config_path)

    run_monitor(cfg, base_dir, headless=args.headless)


if __name__ == "__main__":
    main()
