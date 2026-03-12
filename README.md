# Connectivity Monitor

A real-time network monitoring tool built entirely in PowerShell. No installs, no dependencies, no bloat , just run the script and get a full dashboard showing exactly what your network is doing.

Built out of frustration with flaky ISPs and mysterious Wi-Fi drops. If you've ever wanted to prove to your ISP that yes, the connection *is* dropping, this tool gives you the data to back it up.

**KEY EXPORTS**
- **Export to CSV**
- **HTML Dashboard export**
---

## What It Does

Connectivity Monitor continuously pings targets (Cloudflare, Google DNS, OpenDNS by default), tracks latency and packet loss, detects outages, and logs everything to CSV. It runs in your terminal with a tabbed dashboard that updates in real time — no browser, no GUI framework, just your PowerShell window.

When it detects problems, it tells you *what's* wrong: whether it's your gateway, your ISP, DNS, or the target itself. It auto-generates HTML reports you can send to your ISP or keep for your own records.

### Key features

- **Live dashboard** with 5 tabs — overview, latency graph, drop log, per-target stats, and a heatmap
- **Dual-pane layout** with network stats on the left and latency graphs on the right
- **Smart diagnostics** — automatically figures out where the problem is (local network, gateway, ISP, DNS)
- **Health scoring** — grades your connection from A+ to F based on latency, jitter, and packet loss
- **Baseline learning** — learns your normal latency from the first 30 pings, then flags deviations
- **Traceroute on drops** — kicks off a background traceroute when connectivity drops so you can see where packets are dying
- **HTML reports** — auto-generated every 500 pings and on exit, with charts and stats
- **CSV logging** with daily rotation — ping results, drops, and latency threshold breaches all in separate files
- **Wi-Fi signal tracking** — monitors signal strength over time if you're on wireless
- **Audible alerts** — optional beep on connectivity drops (off by default, mercifully)
- **Flicker-free rendering** — the dashboard doesn't flash or tear, even at fast poll rates

---

## Quick Start

### Requirements

- **Windows** (uses `Get-NetAdapter`, `Test-Connection`, `netsh` — Windows-native stuff)
- **PowerShell 5.0+** (already on your machine if you're on Windows 10/11)

### Run it

1. Download or clone this repo:
   ```
   git clone https://github.com/nexuspcs/ConnectivityMonitor.git
   ```

2. Open PowerShell and navigate to the folder:
   ```powershell
   cd ConnectivityMonitor
   ```

3. If you haven't changed your execution policy before, you'll need to allow scripts to run:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

4. Run the script:
   ```powershell
   .\ConnectivityDropMonitor.ps1
   ```

5. Follow the setup prompts — pick your network adapter, set your ping targets, and you're live.

That's it. The dashboard starts immediately after setup.

### One-liner if you're in a hurry

```powershell
git clone https://github.com/nexuspcs/ConnectivityMonitor.git; cd ConnectivityMonitor; .\ConnectivityDropMonitor.ps1
```

---

## Setup Walkthrough

On first run, you'll be prompted to configure a few things:

| Setting | Default | What it does |
|---|---|---|
| Network adapter | *(auto-detected)* | Which adapter to monitor |
| Poll interval | 2 seconds | How often to ping |
| Failure threshold | 4 consecutive failures | How many missed pings before a "drop" is recorded |
| Ping targets | `1.1.1.1, 8.8.8.8, 208.67.222.222` | What to ping — Cloudflare, Google, OpenDNS |
| Latency warning | 100ms | Threshold for flagging high latency |
| DNS health check | Yes | Also check DNS resolution each cycle |
| DNS hostname | `google.com` | What hostname to resolve for DNS checks |
| Audible alerts | No | Beep on connectivity drops |

Your config is saved to `%USERPROFILE%\ConnectivityMonitor\monitor_config.json` and reused on the next run, so you only have to set it up once.

---

## Dashboard Tabs

Switch tabs with the number keys `1`-`5`:

**Tab 1 — Overview**
The main view. Left pane shows connection status, adapter info, public/local IP, gateway health, latency stats (avg, min, max, P95, P99, jitter), uptime, and smart diagnostics. Right pane shows a live latency graph and sparklines.

**Tab 2 — Graph**
Full-width latency graph with histogram showing the distribution of your latency values.

**Tab 3 — Drops**
Log of all connectivity drop events with timestamps, duration, and what happened.

**Tab 4 — Targets**
Per-target breakdown so you can see if one target is worse than others.

**Tab 5 — Heatmap**
Hourly heatmap of latency patterns — useful for spotting time-of-day trends (e.g., congestion during peak hours).

---

## Hotkeys

| Key | Action |
|---|---|
| `1`-`5` | Switch dashboard tab |
| `P` | Pause / resume monitoring |
| `R` | Reset all stats |
| `E` | Export HTML report now |
| `Q` | Quit gracefully |
| `Ctrl+C` | Also quits gracefully |

---

## Output Files

Everything gets saved under `%USERPROFILE%\ConnectivityMonitor\`:

```
ConnectivityMonitor/
├── logs/
│   ├── ping_log_2025-01-15.csv        # Every ping result
│   ├── drops_2025-01-15.csv           # Connectivity drop events
│   └── breaches_2025-01-15.csv        # Latency threshold breaches
├── reports/
│   └── report_2025-01-15_143022.html  # HTML report with charts
└── monitor_config.json                # Your saved config
```

Logs rotate daily, so they don't grow forever. HTML reports are generated automatically every 500 pings and when you exit.

---

## What the Health Score Means

The monitor grades your connection based on latency, jitter, and packet loss:

| Grade | What it means |
|---|---|
| A+ / A | Solid connection — low latency, minimal jitter, no drops |
| B | Fine for most things, minor latency spikes |
| C | Noticeable issues — you'll feel it in video calls and gaming |
| D | Rough — frequent spikes or packet loss |
| F | Broken — significant packet loss or sustained high latency |

---

## Contributing

This project is open source and contributions are welcome. If you've got an idea, found a bug, or want to add a feature — go for it.

- **Fork the repo** and make your changes
- **Open a pull request** with a clear description of what you changed and why
- **Report bugs** by opening an issue — include what you were doing, what happened, and what you expected

Some areas that could use work:
- Cross-platform support (Linux/macOS) — the biggest gap right now
- More ping targets / custom target presets
- Historical trend analysis across multiple sessions
- Network speed test integration
- Dark/light theme toggle

If you find this useful, **give it a star** — it helps other people find it and motivates continued development.

---

## License

This project doesn't currently have a formal license. If you want to use it, go ahead. Attribution is appreciated but not required.

---

## Credits

Built by [James Coates](https://github.com/nexuspcs) with assistance from Claude (via GitHub Copilot).

If this tool saved you a headache or helped you catch your ISP slacking, consider starring the repo. It's a small thing but it goes a long way.
