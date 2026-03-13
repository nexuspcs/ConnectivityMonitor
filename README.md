# Connectivity Monitor

A real-time network monitoring tool that tracks latency, detects outages, and gives you the data to prove your ISP is dropping the ball. Available for **Windows** (PowerShell), **macOS** (Bash), and **Linux / Raspberry Pi** (Python).

Built out of frustration with flaky ISPs and mysterious Wi-Fi drops. If you've ever wanted to prove to your ISP that yes, the connection *is* dropping, this tool gives you the data to back it up.

**KEY EXPORTS**
- **Export to CSV** — daily-rotating logs for ping results, drops, and latency breaches
- **HTML Dashboard export** — Chart.js-powered reports with dark theme
- **Live Web Dashboard** — auto-refreshing browser dashboard with 5 tabs (Python version)

---

## What It Does

Connectivity Monitor continuously pings targets (Cloudflare, Google DNS, OpenDNS by default), tracks latency and packet loss, detects outages, and logs everything to CSV. When it detects problems, it tells you *what's* wrong: whether it's your gateway, your ISP, DNS, or the target itself.

### Key Features

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

## Platform Support

| Platform | Version | Directory | Details |
|----------|---------|-----------|---------|
| **Windows** | PowerShell terminal dashboard | [`windows/`](windows/) | [Windows README](windows/README.md) |
| **macOS** | Bash terminal dashboard | [`macos/`](macos/) | [macOS README](macos/README.md) |
| **Linux / Raspberry Pi** | Python web dashboard | [`python/`](python/) | [Python README](python/README.md) |

Each platform directory contains a self-contained implementation with its own documentation. See the platform-specific READMEs for detailed setup instructions.

---

## Quick Start

### Windows (PowerShell)

**Requirements:** Windows 10/11, PowerShell 5.0+

```powershell
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor\windows
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\ConnectivityDropMonitor.ps1
```

Follow the setup prompts — pick your network adapter, set your ping targets, and you're live. The tabbed terminal dashboard starts immediately.

> 📖 Full details: [windows/README.md](windows/README.md)

### macOS (Bash)

**Requirements:** macOS, Bash 3.2+, python3

```bash
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/macos
chmod +x ConnectivityDropMonitor.sh
./ConnectivityDropMonitor.sh
```

> 📖 Full details: [macos/README.md](macos/README.md)

### Linux / Raspberry Pi (Python)

**Requirements:** Python 3.6+ (no external dependencies — stdlib only)

```bash
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/python
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
sudo cp python/connectivity-monitor@.service /etc/systemd/system/

# Enable and start (replace YOUR_USER with your username)
sudo systemctl enable connectivity-monitor@YOUR_USER
sudo systemctl start connectivity-monitor@YOUR_USER

# Check status
sudo systemctl status connectivity-monitor@YOUR_USER
```

> 📖 Full details: [python/README.md](python/README.md)

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

> 📖 Full configuration guide: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

---

## Dashboard Tabs

All versions have 5 tabs with the same information:

| Tab | Content |
|---|---|
| **Overview** | Health score, uptime, latency stats, diagnostics, latency chart, and histogram |
| **Graph** | Full-width latency-over-time chart with gateway overlay |
| **Drops** | Log of all connectivity drop events with timestamps, duration, and diagnosis |
| **Targets** | Per-target breakdown showing loss, avg, min, max for each ping target |
| **Heatmap** | 24-hour heatmap of average latency — spot time-of-day patterns |

**PowerShell / macOS versions:** Switch tabs with `1`–`5` keys. Press `P` to pause, `R` to reset, `E` to export, `Q` to quit.

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

> 📖 Full API reference: [docs/API.md](docs/API.md)

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

## Repository Structure

```
ConnectivityMonitor/
├── windows/                              # Windows PowerShell version
│   ├── ConnectivityDropMonitor.ps1       #   Main script (2132 lines)
│   └── README.md                         #   Windows-specific documentation
├── macos/                                # macOS Bash version
│   ├── ConnectivityDropMonitor.sh        #   Main entry point
│   ├── lib/                              #   Modular library files
│   │   ├── state.sh                      #     Global state variables
│   │   ├── config.sh                     #     Configuration management
│   │   ├── network.sh                    #     Ping, DNS, gateway, traceroute
│   │   ├── metrics.sh                    #     Statistics and health scoring
│   │   ├── display.sh                    #     Graph and display builders
│   │   ├── tabs.sh                       #     Tab bar and view builders
│   │   └── logging.sh                    #     CSV logging and HTML reports
│   └── README.md                         #   macOS-specific documentation
├── python/                               # Cross-platform Python version
│   ├── connectivity_monitor/             #   Main package
│   │   ├── __init__.py                   #     Package metadata
│   │   ├── __main__.py                   #     CLI entry point
│   │   ├── config.py                     #     Configuration management
│   │   ├── state.py                      #     Global monitor state
│   │   ├── network.py                    #     Ping, DNS, gateway, traceroute
│   │   ├── metrics.py                    #     Statistics and health scoring
│   │   ├── csv_logger.py                 #     CSV logging with daily rotation
│   │   ├── html_report.py                #     HTML report generation
│   │   ├── web_server.py                 #     Built-in HTTP server + dashboard
│   │   └── monitor.py                    #     Main monitoring loop
│   ├── connectivity_monitor.py           #   Wrapper script
│   ├── connectivity-monitor@.service     #   systemd service file for Linux
│   └── README.md                         #   Python-specific documentation
├── docs/                                 # Documentation
│   ├── CONFIGURATION.md                  #   Configuration guide
│   └── API.md                            #   Web dashboard & API reference
├── README.md                             # This file
├── CONTRIBUTING.md                       # Contribution guidelines
└── CODE_OF_CONDUCT.md                    # Community code of conduct
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [README.md](README.md) | Project overview and quick start (this file) |
| [windows/README.md](windows/README.md) | Windows PowerShell setup and usage |
| [macos/README.md](macos/README.md) | macOS Bash setup and usage |
| [python/README.md](python/README.md) | Python cross-platform setup, CLI options, and Raspberry Pi guide |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Full configuration reference and CSV log format |
| [docs/API.md](docs/API.md) | Web dashboard and JSON API reference |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute to the project |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Community code of conduct |

---

## Contributing

This project is open source and contributions are welcome — code, documentation, bug reports, feature ideas, and more. If you've got an idea, found a bug, or want to add a feature — go for it.

- **Fork the repo** and make your changes
- **Open a pull request** with a clear description of what you changed and why
- **Report bugs** by opening an issue — include what you were doing, what happened, and what you expected

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

If you find this useful, **give it a star** — it helps other people find it and motivates continued development.

---

## License

This project doesn't currently have a formal license. If you want to use it, go ahead. Attribution is appreciated but not required.

---

## Credits

Built by [James Coates](https://github.com/nexuspcs) with assistance from Claude (via GitHub Copilot).

If this tool saved you a headache or helped you catch your ISP slacking, consider starring the repo. It's a small thing but it goes a long way.
