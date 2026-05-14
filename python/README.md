# Connectivity Monitor — Python (Cross-Platform)

The Python version of Connectivity Monitor is a cross-platform package that works on **Linux**, **macOS**, and **Raspberry Pi**. It features a built-in web dashboard accessible from any browser, real-time monitoring, and comprehensive logging.

## Requirements

- **Python 3.6+**
- **No external dependencies** — uses only the Python standard library
- Works on Linux, macOS, and Raspberry Pi

## Quick Start

```bash
# Clone the repository
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/python

# Run the monitor (interactive setup)
python3 -m connectivity_monitor

# Or run headless with defaults
python3 -m connectivity_monitor --headless
```

Open `http://localhost:8080` in your browser for the live dashboard.

## Features

- **Live web dashboard** with 5 tabs — auto-refreshes every 3 seconds
- **JSON API** — access monitoring data programmatically
- **Smart diagnostics** — identifies where connectivity issues occur (local network, gateway, ISP, DNS)
- **Health scoring** — grades your connection from A+ to F
- **Baseline learning** — learns normal latency from the first 30 pings
- **Traceroute on drops** — automatic traceroute when connectivity drops
- **HTML reports** — auto-generated with Chart.js charts
- **CSV logging** with daily rotation
- **Headless mode** — ideal for servers, Raspberry Pi, and unattended monitoring
- **systemd integration** — run as a system service on Linux

## CLI Options

```
python3 -m connectivity_monitor [OPTIONS]

Options:
  --headless              Run without interactive prompts (uses saved or default config)
  --targets TARGETS       Comma-separated ping targets (e.g. 1.1.1.1,8.8.8.8)
  --poll SECONDS          Poll interval in seconds (default: 2)
  --threshold N           Consecutive failures to declare an outage (default: 4)
  --web-port PORT         Web dashboard port (default: 8080)
```

### Examples

```bash
# Interactive setup
python3 -m connectivity_monitor

# Headless with saved config
python3 -m connectivity_monitor --headless

# Custom targets and port
python3 -m connectivity_monitor --headless --targets 1.1.1.1,8.8.8.8 --web-port 9090

# Adjust poll interval and threshold
python3 -m connectivity_monitor --headless --poll 5 --threshold 3
```

## Web Dashboard & API

The built-in HTTP server serves a live dashboard and JSON API:

| Endpoint | Description |
|----------|-------------|
| `/` or `/dashboard` | Live auto-refreshing dashboard with all 5 tabs |
| `/reports/` | List of generated HTML reports |
| `/logs/` | List of CSV log files |
| `/api/status` | JSON — health score, uptime, loss, latency stats, trend |
| `/api/history` | JSON — recent ping and gateway latency history |
| `/api/drops` | JSON — connection drop events |
| `/api/targets` | JSON — per-target statistics |
| `/api/heatmap` | JSON — hourly latency averages |

Access from any device on your network: `http://<device-ip>:8080`

## Running as a System Service (Linux)

A systemd service file is included for running the monitor as a background service:

```bash
# Copy the service file
sudo cp connectivity-monitor@.service /etc/systemd/system/

# Enable and start (replace YOUR_USER with your username)
sudo systemctl enable connectivity-monitor@YOUR_USER
sudo systemctl start connectivity-monitor@YOUR_USER

# Check status
sudo systemctl status connectivity-monitor@YOUR_USER

# View logs
sudo journalctl -u connectivity-monitor@YOUR_USER -f
```

### Hardened 24/7 service behavior

The included `connectivity-monitor@.service` is hardened for always-on usage:

- Restarts automatically (`Restart=always`) with short backoff
- Waits for `network-online.target` on boot
- Adds startup/shutdown timeout protections
- Sets file descriptor/task limits for long-running operation
- Restricts filesystem writes to `~/ConnectivityMonitor`

## Raspberry Pi Setup

The Python version works natively on Raspberry Pi:

```bash
# Ensure Python 3 is installed (usually pre-installed on Raspberry Pi OS)
python3 --version

# Clone and run
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/python
python3 -m connectivity_monitor --headless --web-port 8080
```

For always-on monitoring, set it up as a systemd service (see above). Then access the dashboard from any device on your network at `http://<pi-ip>:8080`.

## Raspberry Pi 24/7 Production Setup

### 1) Keep the Pi address stable (queryable anytime)

Use one of these:

- DHCP reservation on your router (recommended), or
- Static IP on Raspberry Pi OS

Then use a stable DNS name on your LAN (for example, `connectivity-monitor.local`) if available.

### 2) Install hardened service + timers

```bash
cd ~/ConnectivityMonitor/python

# Main monitor service
sudo cp connectivity-monitor@.service /etc/systemd/system/

# Health-check and archive timer units
sudo cp systemd/connectivity-monitor-healthcheck@.service /etc/systemd/system/
sudo cp systemd/connectivity-monitor-healthcheck@.timer /etc/systemd/system/
sudo cp systemd/connectivity-monitor-archive@.service /etc/systemd/system/
sudo cp systemd/connectivity-monitor-archive@.timer /etc/systemd/system/

sudo systemctl daemon-reload

# Enable monitor + safety timers
sudo systemctl enable connectivity-monitor@YOUR_USER
sudo systemctl start connectivity-monitor@YOUR_USER
sudo systemctl enable --now connectivity-monitor-healthcheck@YOUR_USER.timer
sudo systemctl enable --now connectivity-monitor-archive@YOUR_USER.timer
```

### 3) Reverse proxy for controlled remote access (TLS/auth)

Keep the monitor on localhost and publish through a reverse proxy (Nginx/Caddy/Traefik) to add:

- HTTPS/TLS certificates
- Basic auth or SSO
- IP allow-listing/rate limits

Proxy upstream target: `http://127.0.0.1:8080`

## Operational Safety Checks

### API health probe + alert trigger

`ops/health_probe.py` checks `/api/status` and exits non-zero when:

- Endpoint is unreachable
- Health score is below threshold
- Packet loss exceeds threshold

This is scheduled every minute by `connectivity-monitor-healthcheck@.timer` and visible in `journalctl`.

Optional auto-reboot trigger example:

```bash
python3 ops/health_probe.py \
  --url http://127.0.0.1:8080/api/status \
  --min-health 60 --max-loss 10 \
  --reboot-after-failures 15 \
  --allow-reboot
```

### Log/report persistence and archival

The monitor writes logs and reports under `~/ConnectivityMonitor`.

`ops/archive_artifacts.py` can archive and prune old data, and is scheduled daily by `connectivity-monitor-archive@.timer`.

## One-command Recovery and Validation

Use:

```bash
bash ~/ConnectivityMonitor/python/ops/recover_service.sh YOUR_USER
```

This command:

- Reloads systemd units
- Re-enables and restarts the monitor service
- Prints service status and recent journal logs
- Validates API response from `/api/status`

## Soak Test Checklist (48–72h)

Before calling deployment production-ready, run for 48–72 hours and verify:

- Service survives reboot (`systemctl is-enabled` + post-reboot status)
- Auto-restart behavior works when process is killed
- API remains queryable (`/api/status`, `/api/history`, `/api/drops`, `/api/targets`, `/api/heatmap`)
- Logs and reports continue to generate
- Health-check timer executes and records status
- Daily archival timer creates archives and prunes old ones

## Package Structure

```
python/
├── connectivity_monitor/             # Main package
│   ├── __init__.py                   # Package metadata (version 4.0)
│   ├── __main__.py                   # CLI entry point
│   ├── config.py                     # Configuration management
│   ├── state.py                      # Global monitor state
│   ├── network.py                    # Ping, DNS, gateway, traceroute
│   ├── metrics.py                    # Statistics, health score, trend analysis
│   ├── csv_logger.py                 # CSV logging with daily rotation
│   ├── html_report.py                # HTML report generation (Chart.js)
│   ├── web_server.py                 # Built-in HTTP server and live dashboard
│   └── monitor.py                    # Main monitoring loop
├── connectivity_monitor.py           # Wrapper script
└── connectivity-monitor@.service     # systemd service file for Linux
```

## Configuration

On first run (interactive mode), you'll be prompted to configure:

| Setting | Default | Description |
|---------|---------|-------------|
| Poll interval | 2 seconds | How often to ping |
| Failure threshold | 4 consecutive failures | Pings before a "drop" is recorded |
| Ping targets | `1.1.1.1, 8.8.8.8, 208.67.222.222` | Cloudflare, Google DNS, OpenDNS |
| Latency warning | 100ms | Threshold for flagging high latency |
| DNS health check | Yes | Also check DNS resolution each cycle |
| DNS hostname | `google.com` | Hostname to resolve for DNS checks |
| Web dashboard port | 8080 | Port for the live web dashboard |

Configuration is saved to `~/ConnectivityMonitor/monitor_config.json` and reused on subsequent runs.

## Output Files

All output is saved to `~/ConnectivityMonitor/`:

```
ConnectivityMonitor/
├── logs/
│   ├── ping_log_2025-01-15.csv        # Every ping result (18 columns)
│   ├── drops_2025-01-15.csv           # Connectivity drop events
│   └── breaches_2025-01-15.csv        # Latency threshold breaches
├── reports/
│   └── report_2025-01-15_143022.html  # HTML report with Chart.js charts
└── monitor_config.json                # Saved configuration
```
