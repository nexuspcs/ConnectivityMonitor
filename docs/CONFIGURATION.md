# Configuration Guide

Connectivity Monitor saves its configuration as a JSON file and reuses it on subsequent runs. This document covers all configuration options across platforms.

## Configuration File Location

| Platform | Path |
|----------|------|
| Windows | `%USERPROFILE%\ConnectivityMonitor\monitor_config.json` |
| macOS | `~/ConnectivityMonitor/monitor_config.json` |
| Linux / Raspberry Pi | `~/ConnectivityMonitor/monitor_config.json` |

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| `poll_interval` | `2` | How often to ping targets, in seconds |
| `failure_threshold` | `4` | Consecutive failed pings before an outage is recorded |
| `targets` | `["1.1.1.1", "8.8.8.8", "208.67.222.222"]` | IP addresses to ping (Cloudflare, Google DNS, OpenDNS) |
| `latency_warning` | `100` | Latency threshold in milliseconds for flagging high latency |
| `dns_check` | `true` | Whether to check DNS resolution each cycle |
| `dns_hostname` | `"google.com"` | Hostname used for DNS health checks |
| `web_port` | `8080` | Port for the live web dashboard (Python version only) |

## Example Configuration

```json
{
    "poll_interval": 2,
    "failure_threshold": 4,
    "targets": ["1.1.1.1", "8.8.8.8", "208.67.222.222"],
    "latency_warning": 100,
    "dns_check": true,
    "dns_hostname": "google.com",
    "web_port": 8080
}
```

## Changing Configuration

### Interactive Mode (Python / macOS)

Run the monitor without `--headless` and follow the setup prompts:

```bash
python3 -m connectivity_monitor
```

### Headless Override (Python)

Override individual settings via CLI flags without modifying the config file:

```bash
python3 -m connectivity_monitor --headless --targets 1.1.1.1,8.8.8.8 --poll 5 --web-port 9090
```

### Manual Edit

Edit `monitor_config.json` directly with a text editor. The monitor reads the configuration on startup.

## Output Directory Structure

All platforms save output files to the same directory as the config file:

```
ConnectivityMonitor/
├── logs/
│   ├── ping_log_YYYY-MM-DD.csv        # Every ping result
│   ├── drops_YYYY-MM-DD.csv           # Connectivity drop events
│   └── breaches_YYYY-MM-DD.csv        # Latency threshold breaches
├── reports/
│   └── report_YYYY-MM-DD_HHMMSS.html  # HTML reports with charts
└── monitor_config.json                # Configuration file
```

### CSV Log Columns (ping_log)

The ping log CSV contains the following 18 columns:

| Column | Description |
|--------|-------------|
| timestamp | ISO 8601 timestamp |
| target | IP address pinged |
| latency_ms | Round-trip time in milliseconds |
| success | Whether the ping succeeded |
| gateway_latency_ms | Gateway/router latency |
| dns_ok | Whether DNS resolution succeeded |
| dns_latency_ms | DNS resolution time |
| wifi_signal | Wi-Fi signal strength (if applicable) |
| health_score | Current health score (0–100) |
| health_grade | Letter grade (A+ to F) |
| jitter_ms | Latency jitter |
| packet_loss_pct | Packet loss percentage |
| avg_latency_ms | Running average latency |
| min_latency_ms | Minimum latency observed |
| max_latency_ms | Maximum latency observed |
| uptime_pct | Uptime percentage |
| is_baseline | Whether in baseline learning phase |
| diagnosis | Current diagnostic status |

## Health Score Grades

| Grade | Score Range | Meaning |
|-------|-------------|---------|
| A+ | 90–100 | Solid connection — low latency, minimal jitter, no drops |
| A | 80–89 | Great connection with very minor variations |
| B | 70–79 | Fine for most things, minor latency spikes |
| C | 60–69 | Noticeable issues — you'll feel it in video calls and gaming |
| D | 50–59 | Rough — frequent spikes or packet loss |
| F | 0–49 | Broken — significant packet loss or sustained high latency |
