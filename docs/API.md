# Web Dashboard & API Reference

The Python version of Connectivity Monitor includes a built-in HTTP server that provides a live web dashboard and a JSON API. This document covers all available endpoints and how to use them.

## Starting the Web Dashboard

The web server starts automatically when you run the Python version:

```bash
# Default port 8080
python3 -m connectivity_monitor --headless

# Custom port
python3 -m connectivity_monitor --headless --web-port 9090
```

Access the dashboard at `http://localhost:8080` (or your configured port).

For remote access from other devices on your network, use the device's IP address: `http://<device-ip>:8080`

## Dashboard Tabs

The web dashboard provides 5 tabs that auto-refresh every 3 seconds:

| Tab | Content |
|-----|---------|
| **Overview** | Health score, uptime, latency stats, diagnostics, latency chart, and histogram |
| **Graph** | Full-width latency-over-time chart with gateway overlay |
| **Drops** | Log of all connectivity drop events with timestamps, duration, and diagnosis |
| **Targets** | Per-target breakdown showing loss %, avg, min, and max latency |
| **Heatmap** | 24-hour heatmap of average latency — spot time-of-day patterns |

## API Endpoints

All API endpoints return JSON and are available at the same port as the dashboard.

### `GET /api/status`

Returns current monitoring status and health metrics.

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `health_score` | number | Current health score (0–100) |
| `health_grade` | string | Letter grade (A+ to F) |
| `uptime_pct` | number | Uptime percentage |
| `packet_loss_pct` | number | Packet loss percentage |
| `avg_latency` | number | Average latency in ms |
| `min_latency` | number | Minimum latency in ms |
| `max_latency` | number | Maximum latency in ms |
| `jitter` | number | Latency jitter in ms |
| `trend` | string | Latency trend (improving, stable, degrading) |
| `total_pings` | number | Total pings sent this session |
| `diagnosis` | string | Current diagnostic status |

### `GET /api/history`

Returns recent ping and gateway latency history for graphing.

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `timestamps` | array | ISO 8601 timestamps |
| `latencies` | array | Ping latencies in ms |
| `gateway_latencies` | array | Gateway latencies in ms |

### `GET /api/drops`

Returns a list of connectivity drop events.

**Response fields (per drop):**

| Field | Type | Description |
|-------|------|-------------|
| `start` | string | Drop start timestamp |
| `end` | string | Drop end timestamp |
| `duration_sec` | number | Drop duration in seconds |
| `diagnosis` | string | Diagnosis of the drop cause |

### `GET /api/targets`

Returns per-target statistics.

**Response fields (per target):**

| Field | Type | Description |
|-------|------|-------------|
| `target` | string | IP address |
| `loss_pct` | number | Packet loss percentage |
| `avg_ms` | number | Average latency in ms |
| `min_ms` | number | Minimum latency in ms |
| `max_ms` | number | Maximum latency in ms |
| `total_pings` | number | Total pings sent to this target |

### `GET /api/heatmap`

Returns hourly latency averages for the 24-hour heatmap.

**Response fields:**

| Field | Type | Description |
|-------|------|-------------|
| `hours` | object | Keys are hour numbers (0–23), values are average latency in ms |

### `GET /reports/`

Returns an HTML page listing all generated HTML reports. Each report can be downloaded or viewed in the browser.

### `GET /logs/`

Returns an HTML page listing all CSV log files. Each log file can be downloaded.

## Example API Usage

### curl

```bash
# Get current status
curl http://localhost:8080/api/status

# Get drop history
curl http://localhost:8080/api/drops

# Get target stats (pretty-printed)
curl -s http://localhost:8080/api/targets | python3 -m json.tool
```

### Python

```python
import json
import urllib.request

url = "http://localhost:8080/api/status"
with urllib.request.urlopen(url) as response:
    data = json.loads(response.read())
    print(f"Health: {data['health_grade']} ({data['health_score']})")
    print(f"Uptime: {data['uptime_pct']:.1f}%")
```

### JavaScript

```javascript
fetch('http://localhost:8080/api/status')
  .then(response => response.json())
  .then(data => {
    console.log(`Health: ${data.health_grade} (${data.health_score})`);
    console.log(`Uptime: ${data.uptime_pct.toFixed(1)}%`);
  });
```
