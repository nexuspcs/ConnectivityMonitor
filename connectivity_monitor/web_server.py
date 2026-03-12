"""Built-in HTTP web server — live dashboard, JSON API, file serving."""

import datetime
import json
import os
import threading

from http.server import HTTPServer, BaseHTTPRequestHandler

from . import metrics
from .html_report import format_duration


def start_web_server(port, state, reports_dir, logs_dir, bind="0.0.0.0"):
    """Start HTTP server in a background thread. Returns server instance."""
    handler = _make_handler(state, reports_dir, logs_dir)
    server = HTTPServer((bind, port), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _make_handler(state, reports_dir, logs_dir):
    """Create a request handler class with access to monitor state."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass  # Suppress default access logs

        def do_GET(self):
            path = self.path.split("?")[0]  # Strip query params

            if path == "/" or path == "/dashboard":
                self._serve_dashboard()
            elif path == "/api/status":
                self._serve_api_status()
            elif path == "/api/history":
                self._serve_api_history()
            elif path == "/api/drops":
                self._serve_api_drops()
            elif path == "/api/targets":
                self._serve_api_targets()
            elif path == "/api/heatmap":
                self._serve_api_heatmap()
            elif path.startswith("/reports/"):
                self._serve_file(reports_dir, path[9:], "text/html")
            elif path.startswith("/logs/"):
                self._serve_file(logs_dir, path[6:], "text/csv")
            elif path == "/reports" or path == "/reports/":
                self._serve_file_list(reports_dir, "HTML Reports", "/reports/")
            elif path == "/logs" or path == "/logs/":
                self._serve_file_list(logs_dir, "CSV Log Files", "/logs/")
            else:
                self._send(404, "text/plain", "Not Found")

        def _send(self, code, content_type, body):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.wfile.write(body)

        def _serve_api_status(self):
            """JSON API: current monitor status."""
            health = metrics.get_health_score(state)
            trend = metrics.get_trend(state)
            weather = metrics.get_network_weather(state)
            elapsed = datetime.datetime.now() - state.session_start

            data = {
                "health_score": health["score"],
                "health_grade": health["grade"],
                "uptime": metrics.uptime(state),
                "loss": metrics.loss(state),
                "avg_latency": metrics.avg(state),
                "min_latency": metrics.min_lat(state),
                "max_latency": metrics.max_lat(state),
                "p95": metrics.percentile(state, 95),
                "p99": metrics.percentile(state, 99),
                "jitter": metrics.jitter(state),
                "total_pings": state.total_pings,
                "total_success": state.total_success,
                "drops_count": len(state.drops),
                "trend": trend["label"],
                "weather": weather["label"],
                "baseline": state.baseline_latency,
                "public_ip": state.public_ip,
                "isp": state.isp_name,
                "is_down": state.is_down,
                "session_duration": format_duration(elapsed),
                "session_start": state.session_start.isoformat(),
            }
            self._send(200, "application/json", json.dumps(data))

        def _serve_api_history(self):
            """JSON API: recent ping history."""
            hist = []
            for h in state.history[-200:]:
                hist.append({
                    "time": h["time"].strftime("%H:%M:%S"),
                    "latency": h.get("latency"),
                    "target": h.get("target", ""),
                })
            gw = []
            for g in state.gw_history[-200:]:
                gw.append({
                    "time": g["time"].strftime("%H:%M:%S"),
                    "latency": g.get("latency"),
                })
            self._send(200, "application/json", json.dumps({
                "history": hist, "gateway": gw
            }))

        def _serve_api_drops(self):
            """JSON API: drop events."""
            self._send(200, "application/json", json.dumps(state.drops))

        def _serve_api_targets(self):
            """JSON API: per-target statistics."""
            targets = {}
            for t, info in state.per_target.items():
                t_loss = 0
                if info["sent"] > 0:
                    t_loss = round((1 - info["ok"] / info["sent"]) * 100, 1)
                t_avg = t_min = t_max = 0
                if info["lats"]:
                    t_avg = round(sum(info["lats"]) / len(info["lats"]), 1)
                    t_min = round(min(info["lats"]), 1)
                    t_max = round(max(info["lats"]), 1)
                targets[t] = {
                    "sent": info["sent"], "ok": info["ok"],
                    "loss": t_loss, "avg": t_avg, "min": t_min, "max": t_max,
                }
            self._send(200, "application/json", json.dumps(targets))

        def _serve_api_heatmap(self):
            """JSON API: hourly heatmap data."""
            heatmap = {}
            for hh in range(24):
                if hh in state.hourly_data and state.hourly_data[hh]:
                    vals = state.hourly_data[hh]
                    heatmap[str(hh)] = {
                        "avg": round(sum(vals) / len(vals), 1),
                        "min": round(min(vals), 1),
                        "max": round(max(vals), 1),
                        "count": len(vals),
                    }
            self._send(200, "application/json", json.dumps(heatmap))

        def _serve_file(self, base_dir, filename, content_type):
            """Serve a file from reports or logs directory."""
            # Sanitize filename to prevent path traversal
            safe_name = os.path.basename(filename)
            filepath = os.path.join(base_dir, safe_name)
            if os.path.isfile(filepath):
                with open(filepath, "rb") as f:
                    self._send(200, content_type, f.read())
            else:
                self._send(404, "text/plain", "File not found")

        def _serve_file_list(self, directory, title, url_prefix):
            """List files in a directory as HTML."""
            files = []
            if os.path.isdir(directory):
                files = sorted(os.listdir(directory), reverse=True)
            items = ""
            for f in files:
                items += '<li><a href="{}{}">{}</a></li>\n'.format(
                    url_prefix, f, f
                )
            if not items:
                items = "<li>No files yet</li>"
            html = _file_list_html(title, items)
            self._send(200, "text/html", html)

        def _serve_dashboard(self):
            """Serve the live auto-refreshing dashboard."""
            html = _dashboard_html()
            self._send(200, "text/html", html)

    return Handler


def _file_list_html(title, items):
    """Simple file listing page."""
    return """<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>{title}</title>
<style>
body {{ font-family: system-ui; background: #0f172a; color: #e2e8f0; padding: 40px; }}
a {{ color: #38bdf8; }} li {{ margin: 8px 0; }}
h1 {{ color: #38bdf8; }} .back {{ margin-bottom: 20px; }}
</style></head><body>
<div class="back"><a href="/">← Dashboard</a></div>
<h1>{title}</h1><ul>{items}</ul>
</body></html>""".format(title=title, items=items)


def _dashboard_html():
    """Auto-refreshing live dashboard HTML — fetches from /api/* endpoints."""
    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Connectivity Monitor - Live Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #0f172a; --card: #1e293b; --border: #334155;
    --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8;
    --green: #22c55e; --yellow: #f59e0b; --red: #ef4444;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.6; padding: 20px;
  }
  .container { max-width: 1400px; margin: 0 auto; }
  .header {
    text-align: center; padding: 30px 20px;
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    border: 1px solid var(--border); border-radius: 16px; margin-bottom: 24px;
  }
  .header h1 {
    font-size: 1.8rem; font-weight: 700;
    background: linear-gradient(90deg, #38bdf8, #818cf8);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent;
  }
  .header .subtitle { color: var(--muted); font-size: 0.85rem; margin-top: 4px; }
  .header .session-info {
    display: flex; justify-content: center; gap: 24px; margin-top: 12px; flex-wrap: wrap;
  }
  .header .session-info span { color: var(--muted); font-size: 0.8rem; }
  .header .session-info strong { color: var(--text); }
  .tabs {
    display: flex; gap: 8px; margin-bottom: 20px; flex-wrap: wrap;
  }
  .tab {
    padding: 8px 20px; border-radius: 8px; cursor: pointer;
    background: var(--card); border: 1px solid var(--border);
    color: var(--muted); font-size: 0.85rem; transition: all 0.2s;
  }
  .tab:hover { border-color: var(--accent); color: var(--text); }
  .tab.active { background: var(--accent); color: #0f172a; border-color: var(--accent); font-weight: 600; }
  .tab-content { display: none; }
  .tab-content.active { display: block; }
  .score-row {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 14px; margin-bottom: 20px;
  }
  .score-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 18px; text-align: center;
  }
  .score-card .label {
    font-size: 0.75rem; text-transform: uppercase; letter-spacing: 1px;
    color: var(--muted); margin-bottom: 6px;
  }
  .score-card .value { font-size: 1.8rem; font-weight: 700; }
  .score-card .sub { font-size: 0.75rem; color: var(--muted); margin-top: 3px; }
  .chart-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; margin-bottom: 20px;
  }
  .chart-card h2 { font-size: 1rem; font-weight: 600; margin-bottom: 12px; color: var(--accent); }
  .chart-row { display: grid; grid-template-columns: 2fr 1fr; gap: 20px; margin-bottom: 20px; }
  @media (max-width: 900px) { .chart-row { grid-template-columns: 1fr; } }
  .table-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; margin-bottom: 20px; overflow-x: auto;
  }
  .table-card h2 { font-size: 1rem; font-weight: 600; margin-bottom: 12px; color: var(--accent); }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th {
    text-align: left; padding: 8px 10px; border-bottom: 2px solid var(--border);
    color: var(--muted); font-weight: 600; text-transform: uppercase; font-size: 0.7rem;
  }
  td { padding: 8px 10px; border-bottom: 1px solid var(--border); }
  tr:hover { background: rgba(56, 189, 248, 0.05); }
  .stats-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px;
  }
  .stat-item {
    background: rgba(15, 23, 42, 0.5); padding: 12px; border-radius: 8px; border: 1px solid var(--border);
  }
  .stat-item .stat-label { font-size: 0.7rem; text-transform: uppercase; color: var(--muted); }
  .stat-item .stat-value { font-size: 1.2rem; font-weight: 700; margin-top: 3px; }
  .heat-grid { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px; margin: 12px 0; }
  .heat-cell { padding: 6px 3px; border-radius: 5px; text-align: center; color: #fff; font-size: 0.65rem; }
  .heat-hour { display: block; font-weight: 600; }
  .heat-val { display: block; font-size: 0.6rem; opacity: 0.8; }
  .empty { color: var(--muted); font-style: italic; padding: 16px; text-align: center; }
  .status-dot {
    display: inline-block; width: 10px; height: 10px; border-radius: 50%;
    margin-right: 6px; animation: pulse 2s infinite;
  }
  .status-dot.online { background: var(--green); }
  .status-dot.offline { background: var(--red); }
  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
  .links { margin-top: 16px; text-align: center; }
  .links a {
    color: var(--accent); margin: 0 12px; font-size: 0.85rem; text-decoration: none;
  }
  .links a:hover { text-decoration: underline; }
  .footer { text-align: center; padding: 16px; color: var(--muted); font-size: 0.75rem; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1><span class="status-dot online" id="statusDot"></span> Connectivity Monitor</h1>
    <p class="subtitle">Live Dashboard — Auto-refreshes every 3 seconds</p>
    <div class="session-info">
      <span>Duration: <strong id="duration">-</strong></span>
      <span>ISP: <strong id="isp">-</strong></span>
      <span>Public IP: <strong id="publicIp">-</strong></span>
      <span>Weather: <strong id="weather">-</strong></span>
    </div>
    <div class="links">
      <a href="/reports/">HTML Reports</a> | <a href="/logs/">CSV Logs</a>
    </div>
  </div>

  <div class="tabs">
    <div class="tab active" onclick="switchTab(0)">Overview</div>
    <div class="tab" onclick="switchTab(1)">Graph</div>
    <div class="tab" onclick="switchTab(2)">Drops</div>
    <div class="tab" onclick="switchTab(3)">Targets</div>
    <div class="tab" onclick="switchTab(4)">Heatmap</div>
  </div>

  <!-- Tab 0: Overview -->
  <div class="tab-content active" id="tab0">
    <div class="score-row" id="scoreCards"></div>
    <div class="chart-card">
      <h2>Detailed Statistics</h2>
      <div class="stats-grid" id="statsGrid"></div>
    </div>
    <div class="chart-row">
      <div class="chart-card">
        <h2>Latency Over Time</h2>
        <canvas id="latencyChart" height="80"></canvas>
      </div>
      <div class="chart-card">
        <h2>Latency Distribution</h2>
        <canvas id="histChart" height="80"></canvas>
      </div>
    </div>
  </div>

  <!-- Tab 1: Graph (full-width) -->
  <div class="tab-content" id="tab1">
    <div class="chart-card">
      <h2>Latency Over Time (Full)</h2>
      <canvas id="latencyChartFull" height="150"></canvas>
    </div>
  </div>

  <!-- Tab 2: Drops -->
  <div class="tab-content" id="tab2">
    <div class="table-card">
      <h2>Connection Drops</h2>
      <div id="dropsTable"></div>
    </div>
  </div>

  <!-- Tab 3: Targets -->
  <div class="tab-content" id="tab3">
    <div class="table-card">
      <h2>Per-Target Breakdown</h2>
      <div id="targetsTable"></div>
    </div>
  </div>

  <!-- Tab 4: Heatmap -->
  <div class="tab-content" id="tab4">
    <div class="chart-card">
      <h2>Time-of-Day Heatmap</h2>
      <div class="heat-grid" id="heatmap"></div>
    </div>
  </div>

  <div class="footer">Connectivity Monitor v4.0 — Cross-Platform Python Edition</div>
</div>

<script>
let latChart = null, histChart = null, fullChart = null;

function switchTab(idx) {
  document.querySelectorAll('.tab').forEach((t, i) => t.classList.toggle('active', i === idx));
  document.querySelectorAll('.tab-content').forEach((c, i) => c.classList.toggle('active', i === idx));
}

function scoreColor(score) {
  if (score < 60) return '#ef4444';
  if (score < 80) return '#f59e0b';
  return '#22c55e';
}

function latColor(ms) {
  if (ms >= 80) return '#ef4444';
  if (ms >= 30) return '#f59e0b';
  return '#22c55e';
}

function lossColor(pct) {
  if (pct >= 5) return '#ef4444';
  if (pct > 0) return '#f59e0b';
  return '#22c55e';
}

async function refresh() {
  try {
    const [statusRes, histRes, dropsRes, targetsRes, heatRes] = await Promise.all([
      fetch('/api/status'), fetch('/api/history'),
      fetch('/api/drops'), fetch('/api/targets'), fetch('/api/heatmap')
    ]);
    const status = await statusRes.json();
    const hist = await histRes.json();
    const drops = await dropsRes.json();
    const targets = await targetsRes.json();
    const heatmap = await heatRes.json();

    // Header
    document.getElementById('duration').textContent = status.session_duration;
    document.getElementById('isp').textContent = status.isp;
    document.getElementById('publicIp').textContent = status.public_ip;
    document.getElementById('weather').textContent = status.weather;
    const dot = document.getElementById('statusDot');
    dot.className = 'status-dot ' + (status.is_down ? 'offline' : 'online');

    // Score cards
    const sc = document.getElementById('scoreCards');
    sc.innerHTML = `
      <div class="score-card"><div class="label">Health</div>
        <div class="value" style="color:${scoreColor(status.health_score)}">${status.health_score}/100</div>
        <div class="sub">Grade: ${status.health_grade}</div></div>
      <div class="score-card"><div class="label">Uptime</div>
        <div class="value" style="color:${status.uptime<95?'#ef4444':status.uptime<99?'#f59e0b':'#22c55e'}">${status.uptime}%</div>
        <div class="sub">${status.total_success} / ${status.total_pings}</div></div>
      <div class="score-card"><div class="label">Avg Latency</div>
        <div class="value" style="color:${latColor(status.avg_latency)}">${status.avg_latency}ms</div>
        <div class="sub">Baseline: ${status.baseline ? status.baseline+'ms' : 'N/A'}</div></div>
      <div class="score-card"><div class="label">Packet Loss</div>
        <div class="value" style="color:${lossColor(status.loss)}">${status.loss}%</div>
        <div class="sub">${status.total_pings - status.total_success} lost</div></div>
      <div class="score-card"><div class="label">Jitter</div>
        <div class="value" style="color:${status.jitter>=15?'#ef4444':status.jitter>=5?'#f59e0b':'#22c55e'}">${status.jitter}ms</div>
        <div class="sub">Avg variation</div></div>
      <div class="score-card"><div class="label">Outages</div>
        <div class="value" style="color:${status.drops_count>0?'#ef4444':'#22c55e'}">${status.drops_count}</div>
        <div class="sub">Trend: ${status.trend}</div></div>`;

    // Stats grid
    document.getElementById('statsGrid').innerHTML = `
      <div class="stat-item"><div class="stat-label">Min Latency</div><div class="stat-value" style="color:#22c55e">${status.min_latency}ms</div></div>
      <div class="stat-item"><div class="stat-label">Max Latency</div><div class="stat-value" style="color:#ef4444">${status.max_latency}ms</div></div>
      <div class="stat-item"><div class="stat-label">P95</div><div class="stat-value" style="color:#f59e0b">${status.p95}ms</div></div>
      <div class="stat-item"><div class="stat-label">P99</div><div class="stat-value" style="color:#f59e0b">${status.p99}ms</div></div>
      <div class="stat-item"><div class="stat-label">Total Pings</div><div class="stat-value">${status.total_pings}</div></div>
      <div class="stat-item"><div class="stat-label">Drops</div><div class="stat-value" style="color:#ef4444">${status.drops_count}</div></div>`;

    // Charts
    const labels = hist.history.map(h => h.time);
    const latData = hist.history.map(h => h.latency);
    const gwData = hist.gateway.map(g => g.latency);
    while (gwData.length < latData.length) gwData.unshift(null);

    updateChart('latencyChart', latChart, labels, latData, gwData, 80, c => latChart = c);
    updateChart('latencyChartFull', fullChart, labels, latData, gwData, 150, c => fullChart = c);

    // Histogram
    const buckets = [0,0,0,0,0,0];
    latData.forEach(v => { if (v!==null) {
      if (v<10) buckets[0]++; else if (v<25) buckets[1]++;
      else if (v<50) buckets[2]++; else if (v<100) buckets[3]++;
      else if (v<200) buckets[4]++; else buckets[5]++;
    }});
    updateHist(buckets);

    // Drops table
    updateDropsTable(drops);

    // Targets table
    updateTargetsTable(targets);

    // Heatmap
    updateHeatmap(heatmap);

  } catch (e) { console.error('Refresh error:', e); }
}

function updateChart(canvasId, chartRef, labels, latData, gwData, h, setter) {
  const ctx = document.getElementById(canvasId);
  if (!ctx) return;
  if (chartRef) { chartRef.data.labels = labels; chartRef.data.datasets[0].data = latData; chartRef.data.datasets[1].data = gwData; chartRef.update('none'); return; }
  const c = new Chart(ctx.getContext('2d'), {
    type: 'line',
    data: { labels, datasets: [
      { label: 'Latency (ms)', data: latData, borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,0.1)', borderWidth: 1.5, pointRadius: 0, fill: true, tension: 0.3, spanGaps: false },
      { label: 'Gateway (ms)', data: gwData, borderColor: '#818cf8', backgroundColor: 'rgba(129,140,248,0.05)', borderWidth: 1, pointRadius: 0, fill: false, tension: 0.3, spanGaps: false }
    ]},
    options: { responsive: true, interaction: { intersect: false, mode: 'index' },
      plugins: { legend: { labels: { color: '#94a3b8' } } },
      scales: { x: { ticks: { color: '#64748b', maxTicksLimit: 20 }, grid: { color: 'rgba(51,65,85,0.5)' } },
        y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' }, title: { display: true, text: 'ms', color: '#64748b' } } } }
  });
  setter(c);
}

function updateHist(buckets) {
  const ctx = document.getElementById('histChart');
  if (!ctx) return;
  if (histChart) { histChart.data.datasets[0].data = buckets; histChart.update('none'); return; }
  histChart = new Chart(ctx.getContext('2d'), {
    type: 'bar',
    data: { labels: ['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],
      datasets: [{ label: 'Count', data: buckets, backgroundColor: ['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'], borderRadius: 6 }] },
    options: { responsive: true, plugins: { legend: { display: false } },
      scales: { x: { ticks: { color: '#64748b' }, grid: { display: false } }, y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' } } } }
  });
}

function updateDropsTable(drops) {
  const el = document.getElementById('dropsTable');
  if (!drops.length) { el.innerHTML = '<p class="empty">No connection drops recorded.</p>'; return; }
  let html = '<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Target</th><th>Diagnosis</th></tr></thead><tbody>';
  drops.forEach(d => { html += `<tr><td>${d.Start}</td><td>${d.End}</td><td>${d.Duration}s</td><td>${d.Target}</td><td>${d.Diagnosis}</td></tr>`; });
  el.innerHTML = html + '</tbody></table>';
}

function updateTargetsTable(targets) {
  const el = document.getElementById('targetsTable');
  const keys = Object.keys(targets);
  if (!keys.length) { el.innerHTML = '<p class="empty">No target data yet.</p>'; return; }
  let html = '<table><thead><tr><th>Target</th><th>Sent</th><th>OK</th><th>Loss</th><th>Avg</th><th>Min</th><th>Max</th></tr></thead><tbody>';
  keys.forEach(t => { const d = targets[t]; html += `<tr><td>${t}</td><td>${d.sent}</td><td>${d.ok}</td><td>${d.loss}%</td><td>${d.avg}ms</td><td>${d.min}ms</td><td>${d.max}ms</td></tr>`; });
  el.innerHTML = html + '</tbody></table>';
}

function updateHeatmap(heatmap) {
  const el = document.getElementById('heatmap');
  let html = '';
  for (let h = 0; h < 24; h++) {
    const label = String(h).padStart(2, '0') + ':00';
    const data = heatmap[String(h)];
    let avg = '-', color = '#64748b';
    if (data) { avg = data.avg + 'ms'; color = data.avg < 30 ? '#22c55e' : data.avg < 60 ? '#f59e0b' : '#ef4444'; }
    html += `<div class="heat-cell" style="background:${color}"><span class="heat-hour">${label}</span><span class="heat-val">${avg}</span></div>`;
  }
  el.innerHTML = html;
}

// Initial load + auto-refresh
refresh();
setInterval(refresh, 3000);
</script>
</body>
</html>"""
