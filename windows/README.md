# Connectivity Monitor — Windows (PowerShell)

The Windows version of Connectivity Monitor is a self-contained PowerShell script with a live terminal dashboard featuring 5 tabbed views, real-time latency tracking, drop detection, and HTML/CSV reporting.

## Requirements

- **Windows 10 or 11**
- **PowerShell 5.0+** (comes pre-installed on Windows 10/11)
- No external modules or dependencies — pure PowerShell

## Quick Start

```powershell
# Clone the repository
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/windows

# Allow script execution (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Run the monitor
.\ConnectivityDropMonitor.ps1
```

Follow the setup prompts to pick your network adapter, set your ping targets, and start monitoring. The tabbed terminal dashboard appears immediately.

## Features

- **Live terminal dashboard** with 5 tabs — overview, latency graph, drop log, per-target stats, and 24-hour heatmap
- **Flicker-free ASCII rendering** — no Unicode box-drawing characters, pure ASCII display
- **Smart diagnostics** — identifies whether the issue is your local network, gateway, ISP, or DNS
- **Health scoring** — grades your connection from A+ to F
- **Baseline learning** — learns normal latency from the first 30 pings, then flags deviations
- **Traceroute on drops** — background traceroute when connectivity drops
- **HTML reports** — auto-generated with Chart.js charts
- **CSV logging** with daily rotation — ping results, drops, and latency breaches in separate files
- **Wi-Fi signal tracking** — monitors signal strength over time

## Keyboard Controls

| Key | Action |
|-----|--------|
| `1`–`5` | Switch between dashboard tabs |
| `P` | Pause/resume monitoring |
| `R` | Reset statistics |
| `E` | Export HTML report |
| `Q` | Quit (generates final report) |

## Configuration

On first run, you'll be prompted to configure:

| Setting | Default | Description |
|---------|---------|-------------|
| Network adapter | Auto-detected | Which adapter to monitor |
| Poll interval | 2 seconds | How often to ping |
| Failure threshold | 4 consecutive failures | Pings before a "drop" is recorded |
| Ping targets | `1.1.1.1, 8.8.8.8, 208.67.222.222` | Cloudflare, Google DNS, OpenDNS |
| Latency warning | 100ms | Threshold for flagging high latency |
| DNS health check | Yes | Also check DNS resolution each cycle |
| DNS hostname | `google.com` | Hostname to resolve for DNS checks |

Configuration is saved to `%USERPROFILE%\ConnectivityMonitor\monitor_config.json` and reused on subsequent runs.

## Output Files

All output is saved to `%USERPROFILE%\ConnectivityMonitor\`:

```
ConnectivityMonitor\
├── logs\
│   ├── ping_log_2025-01-15.csv        # Every ping result (18 columns)
│   ├── drops_2025-01-15.csv           # Connectivity drop events
│   └── breaches_2025-01-15.csv        # Latency threshold breaches
├── reports\
│   └── report_2025-01-15_143022.html  # HTML report with Chart.js charts
└── monitor_config.json                # Saved configuration
```

Logs rotate daily. HTML reports are generated every 500 pings and on exit.

## Troubleshooting

- **"Running scripts is disabled on this system"** — Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`
- **No network adapter found** — Ensure you have an active network connection and try running PowerShell as Administrator
- **High latency readings** — Check if other applications are consuming bandwidth; try closing VPNs or large downloads
