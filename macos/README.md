# Connectivity Monitor — macOS (Bash)

The macOS version of Connectivity Monitor is a modular Bash script with a live terminal dashboard, real-time latency tracking, drop detection, and HTML/CSV reporting. Built specifically for macOS with native system utilities.

## Requirements

- **macOS** (tested on macOS 12+)
- **Bash 3.2+** (ships with macOS)
- **python3** (ships with macOS or install via Homebrew — used for JSON config parsing and IP detection)

No external dependencies required.

## Quick Start

```bash
# Clone the repository
git clone https://github.com/nexuspcs/ConnectivityMonitor.git
cd ConnectivityMonitor/macos

# Make executable
chmod +x ConnectivityDropMonitor.sh

# Run the monitor
./ConnectivityDropMonitor.sh
```

Follow the setup prompts to select your network interface, configure targets, and start monitoring.

## Features

- **Live terminal dashboard** with 5 tabs — overview, latency graph, drop log, per-target stats, and 24-hour heatmap
- **Modular architecture** — split across 7 library files for maintainability
- **Smart diagnostics** — identifies where connectivity issues occur (local network, gateway, ISP, DNS)
- **Health scoring** — grades your connection from A+ to F
- **Baseline learning** — learns normal latency from the first 30 pings
- **Traceroute on drops** — automatic traceroute when connectivity drops
- **HTML reports** — auto-generated with Chart.js charts
- **CSV logging** with daily rotation
- **Wi-Fi signal tracking** via macOS native utilities

## Architecture

The macOS version uses a modular design with separate library files:

```
macos/
├── ConnectivityDropMonitor.sh   # Main entry point
└── lib/
    ├── state.sh                 # Global state variables
    ├── config.sh                # Configuration save/load, adapter selection
    ├── network.sh               # Ping, DNS, gateway, public IP, Wi-Fi, traceroute
    ├── metrics.sh               # Statistics, health score, trend analysis, diagnosis
    ├── display.sh               # Graph builders, sparkline, histogram, heatmap
    ├── tabs.sh                  # Tab bar and 5 tab view builders
    └── logging.sh               # CSV logging, HTML report generation
```

## Configuration

On first run, you'll be prompted to configure:

| Setting | Default | Description |
|---------|---------|-------------|
| Network interface | Auto-detected | Which interface to monitor |
| Poll interval | 2 seconds | How often to ping |
| Failure threshold | 4 consecutive failures | Pings before a "drop" is recorded |
| Ping targets | `1.1.1.1, 8.8.8.8, 208.67.222.222` | Cloudflare, Google DNS, OpenDNS |
| Latency warning | 100ms | Threshold for flagging high latency |
| DNS health check | Yes | Also check DNS resolution each cycle |

Configuration is saved to `~/ConnectivityMonitor/monitor_config.json` and reused on subsequent runs.

## Output Files

All output is saved to `~/ConnectivityMonitor/`:

```
ConnectivityMonitor/
├── logs/
│   ├── ping_log_2025-01-15.csv        # Every ping result
│   ├── drops_2025-01-15.csv           # Connectivity drop events
│   └── breaches_2025-01-15.csv        # Latency threshold breaches
├── reports/
│   └── report_2025-01-15_143022.html  # HTML report with Chart.js charts
└── monitor_config.json                # Saved configuration
```

## Troubleshooting

- **"Permission denied"** — Run `chmod +x ConnectivityDropMonitor.sh` to make the script executable
- **"python3: command not found"** — Install Python 3 via Homebrew: `brew install python3`
- **No network interface detected** — Ensure Wi-Fi or Ethernet is connected and active
