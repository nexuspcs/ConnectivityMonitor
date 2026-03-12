"""Network utilities — ping, DNS test, gateway detection, public IP."""

import datetime
import os
import platform
import re
import socket
import subprocess
import threading
import time


def ping_test(target, timeout=2):
    """ICMP ping via system command. Returns {ok, lat, target, time}."""
    ts = datetime.datetime.now()
    try:
        system = platform.system().lower()
        if system == "windows":
            cmd = ["ping", "-n", "1", "-w", str(timeout * 1000), target]
        else:
            cmd = ["ping", "-c", "1", "-W", str(timeout), target]

        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout + 2
        )

        if result.returncode == 0:
            # Extract latency from output
            out = result.stdout
            # Linux/macOS: "time=12.3 ms" or "time=12.3ms"
            m = re.search(r"time[=<]\s*([\d.]+)\s*ms", out, re.IGNORECASE)
            if m:
                lat = round(float(m.group(1)), 1)
                return {"ok": True, "lat": lat, "target": target, "time": ts}
            # Windows: "time=12ms" or "time<1ms"
            m = re.search(r"time[=<]([\d.]+)\s*ms", out, re.IGNORECASE)
            if m:
                lat = round(float(m.group(1)), 1)
                return {"ok": True, "lat": lat, "target": target, "time": ts}
            # Got response but couldn't parse latency — still ok
            return {"ok": True, "lat": 0, "target": target, "time": ts}
        return {"ok": False, "lat": None, "target": target, "time": ts}
    except Exception:
        return {"ok": False, "lat": None, "target": target, "time": ts}


def dns_test(hostname):
    """DNS resolution test. Returns {ok, ms}."""
    try:
        start = time.monotonic()
        socket.getaddrinfo(hostname, None)
        elapsed = (time.monotonic() - start) * 1000
        return {"ok": True, "ms": round(elapsed, 1)}
    except Exception:
        return {"ok": False, "ms": None}


def detect_gateway():
    """Detect default gateway IP. Returns IP string or 'N/A'."""
    system = platform.system().lower()
    try:
        if system == "linux":
            out = subprocess.run(
                ["ip", "route", "show", "default"],
                capture_output=True, text=True, timeout=5
            )
            m = re.search(r"default via (\S+)", out.stdout)
            if m:
                return m.group(1)
        elif system == "darwin":
            out = subprocess.run(
                ["netstat", "-rn"], capture_output=True, text=True, timeout=5
            )
            for line in out.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "default":
                    return parts[1]
        elif system == "windows":
            out = subprocess.run(
                ["ipconfig"], capture_output=True, text=True, timeout=5
            )
            m = re.search(r"Default Gateway.*?:\s*([\d.]+)", out.stdout)
            if m:
                return m.group(1)
    except Exception:
        pass
    return "N/A"


def get_local_ip():
    """Get local IP address of the machine."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "N/A"


def detect_public_ip(state):
    """Detect public IP and ISP via ip-api.com. Updates state in-place."""
    try:
        import urllib.request
        import json as json_mod
        req = urllib.request.Request(
            "http://ip-api.com/json",
            headers={"User-Agent": "ConnectivityMonitor/4.0"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json_mod.loads(resp.read().decode())
            state.public_ip = data.get("query", "N/A")
            state.isp_name = data.get("isp", "N/A")
    except Exception:
        state.public_ip = "N/A"
        state.isp_name = "N/A"


def get_interface_name():
    """Get active network interface name."""
    system = platform.system().lower()
    try:
        if system == "linux":
            out = subprocess.run(
                ["ip", "route", "show", "default"],
                capture_output=True, text=True, timeout=5
            )
            m = re.search(r"dev (\S+)", out.stdout)
            if m:
                return m.group(1)
        elif system == "darwin":
            out = subprocess.run(
                ["route", "-n", "get", "default"],
                capture_output=True, text=True, timeout=5
            )
            m = re.search(r"interface:\s*(\S+)", out.stdout)
            if m:
                return m.group(1)
    except Exception:
        pass
    return "unknown"


def get_wifi_signal():
    """Get WiFi signal strength percentage. Returns int or None."""
    system = platform.system().lower()
    try:
        if system == "darwin":
            # macOS: use airport utility
            airport = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
            if os.path.exists(airport):
                out = subprocess.run(
                    [airport, "-I"], capture_output=True, text=True, timeout=5
                )
                m = re.search(r"agrCtlRSSI:\s*(-?\d+)", out.stdout)
                noise = re.search(r"agrCtlNoise:\s*(-?\d+)", out.stdout)
                if m:
                    rssi = int(m.group(1))
                    # Convert RSSI to percentage (approx)
                    pct = max(0, min(100, 2 * (rssi + 100)))
                    return pct
        elif system == "linux":
            if os.path.exists("/proc/net/wireless"):
                with open("/proc/net/wireless") as f:
                    lines = f.readlines()
                for line in lines[2:]:
                    parts = line.split()
                    if len(parts) >= 3:
                        quality = float(parts[2].rstrip("."))
                        # quality is usually 0-70; convert to pct
                        return min(100, int(quality * 100 / 70))
    except Exception:
        pass
    return None


def start_traceroute(target, state):
    """Start a background traceroute. Rate-limited to 1 per 60s."""
    if state.trace_thread is not None and state.trace_thread.is_alive():
        return
    now = datetime.datetime.now()
    if (now - state.last_trace_time).total_seconds() < 60:
        return
    state.last_trace_time = now

    def _run():
        hops = []
        try:
            system = platform.system().lower()
            if system == "windows":
                cmd = ["tracert", "-d", "-w", "500", "-h", "10", target]
            else:
                cmd = ["traceroute", "-n", "-w", "1", "-m", "10", target]

            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=30
            )
            for line in result.stdout.splitlines():
                line = line.strip()
                if re.match(r"^\d", line):
                    parts = [p for p in line.split() if p]
                    hop_num = parts[0]
                    hop_ip = "*"
                    hop_lat = "*"
                    for p in parts:
                        if re.match(r"^\d+\.\d+\.\d+\.\d+$", p):
                            hop_ip = p
                    for p in parts[1:]:
                        if re.match(r"^[\d.]+$", p) and "." in p:
                            hop_lat = p + "ms"
                            break
                        elif re.match(r"^\d+$", p):
                            hop_lat = p + "ms"
                            break
                    hops.append({"hop": hop_num, "ip": hop_ip, "latency": hop_lat})
        except Exception:
            pass

        entry = {
            "target": target,
            "time": datetime.datetime.now().strftime("%H:%M:%S"),
            "hops": hops,
        }
        with state.lock:
            state.traceroutes.append(entry)
            while len(state.traceroutes) > 3:
                state.traceroutes.pop(0)
        state.trace_thread = None

    state.trace_thread = threading.Thread(target=_run, daemon=True)
    state.trace_thread.start()
