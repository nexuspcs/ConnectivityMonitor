# Connectivity Monitor

A real-time network monitoring tool that tracks latency, detects outages, and gives you the data to prove your ISP is dropping the ball. Runs on **Windows** (PowerShell) and **Linux / macOS / Raspberry Pi** (Python).

Built out of frustration with flaky ISPs and mysterious Wi-Fi drops. If you've ever wanted to prove to your ISP that yes, the connection *is* dropping, this tool gives you the data to back it up.

**KEY EXPORTS**
- **Export to CSV** — daily-rotating logs for ping results, drops, and latency breaches
- **HTML Dashboard export** — Chart.js-powered reports with dark theme
- **Live Web Dashboard** — auto-refreshing browser dashboard with 5 tabs (Python version)

---

## What It Does

Connectivity Monitor continuously pings targets (Cloudflare, Google DNS, OpenDNS by default), tracks latency and packet loss, detects outages, and logs everything to CSV. When it detects problems, it tells you *what's* wrong: whether it's your gateway, your ISP, DNS, or the target itself.

### Key features

- **Live dashboard** with 5 tabs — overview, latency graph, drop log, per-target stats, and a heatmap
- **Smart diagnostics** — automatically figures out where the problem is (local network, gateway, ISP, DNS)
- **Health scoring** — grades your connection from A+ to F based on latency, jitter, and packet loss
- **Baseline learning** — learns your normal latency from the first 30 pings, then flags deviations
- **Traceroute on drops** — kicks off a background traceroute when connectivity drops so you can see where packets are dying
- **HTML reports** — auto-generated every 500 pings and on exit, with Chart.js charts and stats
- **CSV logging** with daily rotation — ping results, drops, and latency threshold breaches all in separate files
- **Wi-Fi signal tracking** — monitors signal strength over time if you're on wireless
- **Built-in web server** — live auto-refreshing dashboard accessible from any browser on your network (Python version)

---
<img width="1421" height="1196" alt="image" src="https://github.com/user-attachments/assets/df128d6b-5e5b-4900-b4fc-a21498a57377" />
<img width="1337" height="741" alt="image" src="https://github.com/user-attachments/assets/56d99d9e-d255-4d27-8df9-14674edf6c10" />

---

## Quick Start

### Windows (PowerShell)

**Requirements:** Windows 10/11, PowerShell 5.0+

```powershell
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\ConnectivityDropMonitor.ps1
```

Follow the setup prompts — pick your network adapter, set your ping targets, and you're live. The tabbed terminal dashboard starts immediately.

### Linux / macOS / Raspberry Pi (Python)

**Requirements:** Python 3.6+ (no external dependencies — stdlib only)

```bash
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor
python3 -m connectivity_monitor
```

Follow the interactive prompts, then open `http://localhost:8080` in your browser for the live dashboard.

#### Headless mode (servers, Raspberry Pi, etc.)

```bash
# Run with defaults or saved config, no prompts
python3 -m connectivity_monitor --headless

# Customize from command line
python3 -m connectivity_monitor --headless --targets 1.1.1.1,8.8.8.8 --web-port 9090 --poll 5
```

Then access the live dashboard from any device on your network at `http://<device-ip>:8080`.

#### Run on boot with systemd

```bash
# Copy the service file
sudo cp connectivity-monitor@.service /etc/systemd/system/

# Enable and start (replace YOUR_USER with your username)
sudo systemctl enable connectivity-monitor@YOUR_USER
sudo systemctl start connectivity-monitor@YOUR_USER

# Check status
sudo systemctl status connectivity-monitor@YOUR_USER
```

---

## Setup & Configuration

On first run, you'll be prompted to configure:

| Setting | Default | What it does |
|---|---|---|
| Poll interval | 2 seconds | How often to ping |
| Failure threshold | 4 consecutive failures | How many missed pings before a "drop" is recorded |
| Ping targets | `1.1.1.1, 8.8.8.8, 208.67.222.222` | What to ping — Cloudflare, Google, OpenDNS |
| Latency warning | 100ms | Threshold for flagging high latency |
| DNS health check | Yes | Also check DNS resolution each cycle |
| DNS hostname | `google.com` | What hostname to resolve for DNS checks |
| Web dashboard port | 8080 | Port for the live web dashboard (Python version) |

Config is saved to `~/ConnectivityMonitor/monitor_config.json` (or `%USERPROFILE%\ConnectivityMonitor\` on Windows) and reused on next run.

---

## Dashboard Tabs

Both versions have 5 tabs with the same information:

| Tab | Content |
|---|---|
| **Overview** | Health score, uptime, latency stats, diagnostics, latency chart, and histogram |
| **Graph** | Full-width latency-over-time chart with gateway overlay |
| **Drops** | Log of all connectivity drop events with timestamps, duration, and diagnosis |
| **Targets** | Per-target breakdown showing loss, avg, min, max for each ping target |
| **Heatmap** | 24-hour heatmap of average latency — spot time-of-day patterns |

**PowerShell version:** Switch tabs with `1`-`5` keys. Press `P` to pause, `R` to reset, `E` to export, `Q` to quit.

**Python version:** Click tabs in the web dashboard. Auto-refreshes every 3 seconds.

---

## Web Dashboard & API (Python version)

The Python version includes a built-in HTTP server that serves:

| Endpoint | Description |
|---|---|
| `/` or `/dashboard` | Live auto-refreshing dashboard with all 5 tabs |
| `/reports/` | List of generated HTML reports |
| `/logs/` | List of CSV log files |
| `/api/status` | JSON: health score, uptime, loss, latency stats, trend |
| `/api/history` | JSON: recent ping and gateway latency history |
| `/api/drops` | JSON: connection drop events |
| `/api/targets` | JSON: per-target statistics |
| `/api/heatmap` | JSON: hourly latency averages |

Access from any device on your network: `http://<device-ip>:8080`

---

## CLI Options (Python version)

```
python3 -m connectivity_monitor [OPTIONS]

Options:
  --headless              Run without interactive prompts
  --targets TARGETS       Comma-separated ping targets
  --poll SECONDS          Poll interval (default: 2)
  --threshold N           Consecutive failures for outage (default: 4)
  --web-port PORT         Web dashboard port (default: 8080)
```

---

## Output Files

Everything gets saved under `~/ConnectivityMonitor/` (or `%USERPROFILE%\ConnectivityMonitor\` on Windows):

```
ConnectivityMonitor/
├── logs/
│   ├── ping_log_2025-01-15.csv        # Every ping result with 18 columns
│   ├── drops_2025-01-15.csv           # Connectivity drop events
│   └── breaches_2025-01-15.csv        # Latency threshold breaches
├── reports/
│   └── report_2025-01-15_143022.html  # HTML report with Chart.js charts
└── monitor_config.json                # Your saved config
```

Logs rotate daily. HTML reports are generated automatically every 500 pings and on exit.

---

## What the Health Score Means

| Grade | Score | What it means |
|---|---|---|
| A+ | 90-100 | Solid connection — low latency, minimal jitter, no drops |
| A | 80-89 | Great connection with very minor variations |
| B | 70-79 | Fine for most things, minor latency spikes |
| C | 60-69 | Noticeable issues — you'll feel it in video calls and gaming |
| D | 50-59 | Rough — frequent spikes or packet loss |
| F | 0-49 | Broken — significant packet loss or sustained high latency |

---

## Project Structure

```
ConnectivityMonitor/
├── ConnectivityDropMonitor.ps1        # Windows PowerShell version (2132 lines)
├── connectivity_monitor.py            # Python wrapper script
├── connectivity_monitor/              # Python package (cross-platform)
│   ├── __init__.py                    # Package init
│   ├── __main__.py                    # CLI entry point
│   ├── config.py                      # Configuration management
│   ├── state.py                       # Global monitor state
│   ├── network.py                     # Ping, DNS, gateway, traceroute
│   ├── metrics.py                     # Statistics, health score, trend
│   ├── csv_logger.py                  # CSV logging with daily rotation
│   ├── html_report.py                 # HTML report generation
│   ├── web_server.py                  # Built-in HTTP server + live dashboard
│   └── monitor.py                     # Main monitoring loop
├── connectivity-monitor@.service      # systemd service file for Linux
└── README.md
```

---

## Contributing

This project is open source and contributions are welcome.

- **Fork the repo** and make your changes
- **Open a pull request** with a clear description of what you changed and why
- **Report bugs** by opening an issue — include what you were doing, what happened, and what you expected

If you find this useful, **give it a star** — it helps other people find it and motivates continued development.

---

## License

This project doesn't currently have a formal license. If you want to use it, go ahead. Attribution is appreciated but not required.

---

## Credits

Built by [James Coates](https://github.com/nexuspcs) with assistance from Claude (via GitHub Copilot).

If this tool saved you a headache or helped you catch your ISP slacking, consider starring the repo. It's a small thing but it goes a long way.
