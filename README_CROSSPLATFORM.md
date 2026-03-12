# Connectivity Monitor — Cross-Platform Edition

A lightweight Python connectivity and DNS monitor for **Linux**, **macOS**, and **Raspberry Pi**.  
Zero dependencies — uses only the Python 3.6+ standard library.

## Features

| Feature | Description |
|---|---|
| **Ping monitoring** | Round-robin ICMP ping to multiple configurable targets |
| **DNS health checks** | Measure DNS resolution latency for a configurable hostname |
| **Gateway monitoring** | Auto-detect and ping your default gateway |
| **HTTP JSON API** | Built-in web server so other devices can query your monitor |
| **CSV logging** | Daily-rotating logs of every ping, outage, and latency event |
| **Outage detection** | Automatic detection with configurable failure threshold |
| **Health scoring** | 0–100 health score and A–F grade |
| **Headless mode** | Runs without interactive prompts — perfect for Raspberry Pi |
| **JSON config** | Persistent configuration saved between sessions |

## Quick Start

```bash
# Clone or download
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor

# Run (interactive setup on first launch)
python3 connectivity_monitor.py

# Or run headless with defaults
python3 connectivity_monitor.py --headless
```

## Raspberry Pi Setup

```bash
# 1. Install (Python 3 is pre-installed on Raspberry Pi OS)
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor

# 2. Run in headless mode with the HTTP API enabled
python3 connectivity_monitor.py --headless --api-port 8080

# 3. (Optional) Run as a systemd service for auto-start on boot
sudo cp connectivity-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable connectivity-monitor
sudo systemctl start connectivity-monitor

# 4. Query from another machine on your network
curl http://<pi-ip>:8080/status
```

### systemd Service File

A sample `connectivity-monitor.service` file is included in the repository.
Edit it to set your Pi's username and the path to the script.

## HTTP API Endpoints

When the API server is enabled (default port `8080`), other devices on your
network can query the monitor:

| Endpoint | Description |
|---|---|
| `GET /status` | Full status snapshot (JSON) |
| `GET /health` | Quick health check — score, grade, uptime |
| `GET /dns` | Run a live DNS resolution test and return the result |
| `GET /ping` | Run a live ping test and return the result |
| `GET /drops` | List of recorded outages this session |

### Example: Query from another machine

```bash
# Full status
curl http://192.168.1.50:8080/status

# Quick health check
curl http://192.168.1.50:8080/health
# {"status": "up", "health_score": 97, "health_grade": "A", "uptime_pct": 99.8}

# DNS test
curl http://192.168.1.50:8080/dns
# {"ok": true, "ms": 12.3, "target": "google.com"}
```

## CLI Options

```
python3 connectivity_monitor.py [OPTIONS]

Options:
  --config, -c PATH    Path to JSON config file
  --headless           Run without interactive prompts
  --targets, -t LIST   Comma-separated ping targets (e.g. 1.1.1.1,8.8.8.8)
  --api-port, -p PORT  HTTP API port (default: 8080, 0 to disable)
  --version, -v        Show version
  --help, -h           Show help
```

## Configuration

On first interactive run, you'll be prompted for settings.
Config is saved to `~/ConnectivityMonitor/monitor_config.json`:

```json
{
  "targets": ["1.1.1.1", "8.8.8.8", "208.67.222.222"],
  "poll": 2,
  "threshold": 4,
  "lat_warn": 100,
  "enable_dns": true,
  "dns_target": "google.com",
  "api_port": 8080
}
```

| Setting | Default | Description |
|---|---|---|
| `targets` | `1.1.1.1, 8.8.8.8, 208.67.222.222` | IP addresses to ping |
| `poll` | `2` | Seconds between ping cycles |
| `threshold` | `4` | Consecutive failures before declaring outage |
| `lat_warn` | `100` | Latency (ms) threshold for high-latency alerts |
| `enable_dns` | `true` | Enable DNS resolution checks |
| `dns_target` | `google.com` | Hostname for DNS tests |
| `api_port` | `8080` | HTTP API port (0 = disabled) |

## Log Files

Logs are written to `~/ConnectivityMonitor/logs/` with daily rotation:

| File | Content |
|---|---|
| `ping_log_YYYY-MM-DD.csv` | Every ping result with latency, DNS, health metrics |
| `drops_YYYY-MM-DD.csv` | Connectivity outage events with start/end/duration |

## Requirements

- **Python 3.6+** (standard library only — no pip install needed)
- **ping** command available in PATH
- Linux: `ip` command for gateway/interface detection
- macOS: `netstat` / `route` for gateway detection

## Comparison with Windows Version

| Feature | Windows (`ConnectivityDropMonitor.ps1`) | Cross-Platform (`connectivity_monitor.py`) |
|---|---|---|
| Dashboard | 5-tab interactive TUI | Single-line status output |
| HTML reports | Yes (Chart.js) | CSV logs (importable) |
| WiFi signal | Yes (netsh) | Not yet |
| Traceroute | Auto on outage | Not yet |
| HTTP API | No | Yes — queryable by other devices |
| Headless mode | No | Yes — ideal for Raspberry Pi |
| Dependencies | PowerShell 5+ | Python 3.6+ (stdlib only) |
