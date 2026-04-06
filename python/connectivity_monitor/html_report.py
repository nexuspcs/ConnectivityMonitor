"""HTML report generation — Chart.js charts, dark theme, heatmap.

Matches the exact HTML structure and CSS from ConnectivityDropMonitor.ps1.
"""

import datetime
import html
import os

from . import metrics


def format_duration(td):
    """Format a timedelta into human-readable string."""
    total_seconds = int(td.total_seconds())
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    if hours >= 1:
        return "{}h {}m {}s".format(hours, minutes, seconds)
    if minutes >= 1:
        return "{}m {}s".format(minutes, seconds)
    return "{}s".format(seconds)


def generate_html_report(state, report_file):
    """Generate a complete HTML report with charts and statistics."""
    elapsed = datetime.datetime.now() - state.session_start
    l = metrics.loss(state)
    a = metrics.avg(state)
    mn = metrics.min_lat(state)
    mx = metrics.max_lat(state)
    p95 = metrics.percentile(state, 95)
    p99 = metrics.percentile(state, 99)
    j = metrics.jitter(state)
    up = metrics.uptime(state)
    health = metrics.get_health_score(state)

    # Build chart data
    labels_js = ",".join(
        '"{}"'.format(h["time"].strftime("%H:%M:%S")) for h in state.history
    )
    data_js = ",".join(
        str(h["latency"]) if h.get("latency") is not None else "null"
        for h in state.history
    )

    # Gateway chart data — pad to match history length
    gw_data = []
    for g in state.gw_history:
        if g.get("latency") is not None:
            gw_data.append(str(g["latency"]))
        else:
            gw_data.append("null")
    while len(gw_data) < len(state.history):
        gw_data.insert(0, "null")
    gw_js = ",".join(gw_data)

    # Histogram data — 6 buckets
    hist = [0, 0, 0, 0, 0, 0]
    for h in state.history:
        v = h.get("latency")
        if v is not None:
            if v < 10:
                hist[0] += 1
            elif v < 25:
                hist[1] += 1
            elif v < 50:
                hist[2] += 1
            elif v < 100:
                hist[3] += 1
            elif v < 200:
                hist[4] += 1
            else:
                hist[5] += 1
    hist_js = ",".join(str(x) for x in hist)

    # Per-target table rows
    target_rows = _build_target_rows(state)

    # Drop table rows
    drop_rows = _build_drop_rows(state)

    # Breach table rows
    breach_rows = _build_breach_rows(state)

    # Totals
    total_downtime = 0
    longest_drop = 0
    if state.drops:
        durations = [float(d["Duration"]) for d in state.drops]
        total_downtime = round(sum(durations), 2)
        longest_drop = round(max(durations), 2)

    # CSS colors
    health_css = _score_color(health["score"], [(60, "#ef4444"), (80, "#f59e0b")], "#22c55e")
    uptime_css = _score_color(up, [(95, "#ef4444"), (99, "#f59e0b")], "#22c55e")
    avg_css = "#22c55e"
    if a >= 80:
        avg_css = "#ef4444"
    elif a >= 30:
        avg_css = "#f59e0b"
    loss_css = "#22c55e"
    if l >= 5:
        loss_css = "#ef4444"
    elif l > 0:
        loss_css = "#f59e0b"
    jitter_css = "#22c55e"
    if j >= 15:
        jitter_css = "#ef4444"
    elif j >= 5:
        jitter_css = "#f59e0b"
    drops_css = "#22c55e" if not state.drops else "#ef4444"

    baseline_text = "N/A"
    if state.baseline_latency is not None:
        baseline_text = "{}ms".format(state.baseline_latency)

    # Drop/breach table HTML
    drops_table = '<p class="empty">No connection drops recorded during this session.</p>'
    if state.drops:
        drops_table = (
            "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th>"
            "<th>Target</th><th>Diagnosis</th></tr></thead><tbody>"
            + drop_rows + "</tbody></table>"
        )

    breach_table = '<p class="empty">No high latency events recorded during this session.</p>'
    if state.threshold_breaches:
        breach_table = (
            "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th>"
            "<th>Avg Latency</th></tr></thead><tbody>"
            + breach_rows + "</tbody></table>"
        )

    # Heatmap
    heatmap_html = _build_heatmap(state)

    report_date = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    session_start_str = state.session_start.strftime("%Y-%m-%d %H:%M:%S")
    duration_str = format_duration(elapsed)
    report_gen_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    total_lost = state.total_pings - state.total_success

    # Escape external/user-supplied strings before injecting into HTML
    safe_isp = html.escape(str(state.isp_name))
    safe_public_ip = html.escape(str(state.public_ip))

    html_out = _build_html(
        labels_js=labels_js, data_js=data_js, gw_js=gw_js, hist_js=hist_js,
        target_rows=target_rows, drops_table=drops_table, breach_table=breach_table,
        heatmap_html=heatmap_html, report_date=report_date,
        session_start_str=session_start_str, duration_str=duration_str,
        report_gen_str=report_gen_str, health=health, up=up, a=a, l=l, j=j,
        mn=mn, mx=mx, p95=p95, p99=p99, longest_drop=longest_drop,
        total_pings=state.total_pings, total_lost=total_lost,
        total_downtime=total_downtime, baseline_text=baseline_text,
        health_css=health_css, uptime_css=uptime_css, avg_css=avg_css,
        loss_css=loss_css, jitter_css=jitter_css, drops_css=drops_css,
        drops_count=len(state.drops), isp=safe_isp, public_ip=safe_public_ip,
    )

    d = os.path.dirname(report_file)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(report_file, "w", encoding="utf-8") as f:
        f.write(html_out)


def _score_color(value, thresholds, default):
    """Return CSS color based on threshold list [(threshold, color), ...]."""
    for threshold, color in thresholds:
        if value < threshold:
            return color
    return default


def _build_target_rows(state):
    """Build HTML table rows for per-target stats."""
    rows = ""
    for t, info in state.per_target.items():
        t_loss = 0
        if info["sent"] > 0:
            t_loss = round((1 - info["ok"] / info["sent"]) * 100, 1)
        t_avg = t_min = t_max = 0
        if info["lats"]:
            t_avg = round(sum(info["lats"]) / len(info["lats"]), 1)
            t_min = round(min(info["lats"]), 1)
            t_max = round(max(info["lats"]), 1)
        cls = ""
        if t_loss >= 5:
            cls = ' class="bad"'
        elif t_loss > 0:
            cls = ' class="warn"'
        rows += (
            "<tr{}><td>{}</td><td>{}</td><td>{}</td><td>{}%</td>"
            "<td>{}ms</td><td>{}ms</td><td>{}ms</td></tr>\n"
        ).format(cls, html.escape(t), info["sent"], info["ok"], t_loss, t_avg, t_min, t_max)
    return rows


def _build_drop_rows(state):
    """Build HTML table rows for drop events."""
    rows = ""
    for d in state.drops:
        cls = ""
        dv = float(d["Duration"])
        if dv >= 30:
            cls = ' class="bad"'
        elif dv >= 10:
            cls = ' class="warn"'
        rows += (
            "<tr{}><td>{}</td><td>{}</td><td>{}s</td><td>{}</td><td>{}</td></tr>\n"
        ).format(
            cls,
            html.escape(str(d["Start"])),
            html.escape(str(d["End"])),
            d["Duration"],
            html.escape(str(d["Target"])),
            html.escape(str(d["Diagnosis"])),
        )
    return rows


def _build_breach_rows(state):
    """Build HTML table rows for breach events."""
    rows = ""
    for b in state.threshold_breaches:
        rows += (
            "<tr><td>{}</td><td>{}</td><td>{}s</td><td>{}ms</td></tr>\n"
        ).format(b["Start"], b["End"], b["Duration"], b["AvgLatency"])
    return rows


def _build_heatmap(state):
    """Build 24-hour heatmap HTML cells."""
    html = ""
    for hh in range(24):
        label = "{:02d}:00".format(hh)
        hh_avg = "-"
        hh_color = "#64748b"
        if hh in state.hourly_data and state.hourly_data[hh]:
            vals = state.hourly_data[hh]
            avg_val = round(sum(vals) / len(vals), 1)
            hh_avg = "{}ms".format(avg_val)
            if avg_val < 30:
                hh_color = "#22c55e"
            elif avg_val < 60:
                hh_color = "#f59e0b"
            else:
                hh_color = "#ef4444"
        html += (
            "<div class='heat-cell' style='background:{}'>"
            "<span class='heat-hour'>{}</span>"
            "<span class='heat-val'>{}</span></div>"
        ).format(hh_color, label, hh_avg)
    return html


def _build_html(**kw):
    """Build the complete HTML report string."""
    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Network Report - {report_date}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js" integrity="sha384-OLBgp1GsljhM2TJ+sbHjaiH9txEUvgdDTAzHv2P24donTt6/529l+9Ua0vFImLlb" crossorigin="anonymous"></script>
<style>
  :root {{
    --bg: #0f172a; --card: #1e293b; --border: #334155;
    --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8;
    --green: #22c55e; --yellow: #f59e0b; --red: #ef4444;
  }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.6; padding: 20px;
  }}
  .container {{ max-width: 1400px; margin: 0 auto; }}
  .header {{
    text-align: center; padding: 40px 20px;
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    border: 1px solid var(--border); border-radius: 16px; margin-bottom: 24px;
  }}
  .header h1 {{
    font-size: 2rem; font-weight: 700;
    background: linear-gradient(90deg, #38bdf8, #818cf8);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 8px;
  }}
  .header .subtitle {{ color: var(--muted); font-size: 0.95rem; }}
  .header .session-info {{
    display: flex; justify-content: center; gap: 32px; margin-top: 16px; flex-wrap: wrap;
  }}
  .header .session-info span {{ color: var(--muted); font-size: 0.85rem; }}
  .header .session-info strong {{ color: var(--text); }}
  .score-row {{
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px; margin-bottom: 24px;
  }}
  .score-card {{
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; text-align: center;
  }}
  .score-card .label {{
    font-size: 0.8rem; text-transform: uppercase; letter-spacing: 1px;
    color: var(--muted); margin-bottom: 8px;
  }}
  .score-card .value {{ font-size: 2rem; font-weight: 700; }}
  .score-card .sub {{ font-size: 0.8rem; color: var(--muted); margin-top: 4px; }}
  .chart-card {{
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px;
  }}
  .chart-card h2 {{ font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }}
  .chart-row {{ display: grid; grid-template-columns: 2fr 1fr; gap: 24px; margin-bottom: 24px; }}
  @media (max-width: 900px) {{ .chart-row {{ grid-template-columns: 1fr; }} }}
  .table-card {{
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px; overflow-x: auto;
  }}
  .table-card h2 {{ font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }}
  table {{ width: 100%; border-collapse: collapse; font-size: 0.9rem; }}
  th {{
    text-align: left; padding: 10px 12px; border-bottom: 2px solid var(--border);
    color: var(--muted); font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.5px;
  }}
  td {{ padding: 10px 12px; border-bottom: 1px solid var(--border); }}
  tr:hover {{ background: rgba(56, 189, 248, 0.05); }}
  tr.bad {{ background: rgba(239, 68, 68, 0.1); }}
  tr.warn {{ background: rgba(245, 158, 11, 0.1); }}
  .empty {{ color: var(--muted); font-style: italic; padding: 20px; text-align: center; }}
  .stats-grid {{
    display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;
  }}
  .stat-item {{
    background: rgba(15, 23, 42, 0.5); padding: 14px; border-radius: 8px; border: 1px solid var(--border);
  }}
  .stat-item .stat-label {{ font-size: 0.75rem; text-transform: uppercase; color: var(--muted); letter-spacing: 0.5px; }}
  .stat-item .stat-value {{ font-size: 1.3rem; font-weight: 700; margin-top: 4px; }}
  .heat-grid {{ display: grid; grid-template-columns: repeat(24, 1fr); gap: 4px; margin: 16px 0; }}
  .heat-cell {{ padding: 8px 4px; border-radius: 6px; text-align: center; color: #fff; font-size: 0.7rem; }}
  .heat-hour {{ display: block; font-weight: 600; }}
  .heat-val {{ display: block; font-size: 0.65rem; opacity: 0.8; }}
  .footer {{ text-align: center; padding: 24px; color: var(--muted); font-size: 0.8rem; }}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>Network Connectivity Report</h1>
    <p class="subtitle">Generated by Connectivity Monitor v4.0</p>
    <div class="session-info">
      <span>Started: <strong>{session_start_str}</strong></span>
      <span>Duration: <strong>{duration_str}</strong></span>
      <span>ISP: <strong>{isp}</strong></span>
      <span>Public IP: <strong>{public_ip}</strong></span>
    </div>
  </div>
  <div class="score-row">
    <div class="score-card">
      <div class="label">Health Score</div>
      <div class="value" style="color: {health_css}">{health_score}/100</div>
      <div class="sub">Grade: {health_grade}</div>
    </div>
    <div class="score-card">
      <div class="label">Uptime</div>
      <div class="value" style="color: {uptime_css}">{up}%</div>
      <div class="sub">{total_success} / {total_pings} pings</div>
    </div>
    <div class="score-card">
      <div class="label">Avg Latency</div>
      <div class="value" style="color: {avg_css}">{a}ms</div>
      <div class="sub">Baseline: {baseline_text}</div>
    </div>
    <div class="score-card">
      <div class="label">Packet Loss</div>
      <div class="value" style="color: {loss_css}">{l}%</div>
      <div class="sub">{total_lost} packets lost</div>
    </div>
    <div class="score-card">
      <div class="label">Jitter</div>
      <div class="value" style="color: {jitter_css}">{j}ms</div>
      <div class="sub">Avg variation</div>
    </div>
    <div class="score-card">
      <div class="label">Outages</div>
      <div class="value" style="color: {drops_css}">{drops_count}</div>
      <div class="sub">Total: {total_downtime}s</div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Detailed Statistics</h2>
    <div class="stats-grid">
      <div class="stat-item"><div class="stat-label">Min Latency</div><div class="stat-value" style="color:var(--green)">{mn}ms</div></div>
      <div class="stat-item"><div class="stat-label">Max Latency</div><div class="stat-value" style="color:var(--red)">{mx}ms</div></div>
      <div class="stat-item"><div class="stat-label">P95 Latency</div><div class="stat-value" style="color:var(--yellow)">{p95}ms</div></div>
      <div class="stat-item"><div class="stat-label">P99 Latency</div><div class="stat-value" style="color:var(--yellow)">{p99}ms</div></div>
      <div class="stat-item"><div class="stat-label">Longest Drop</div><div class="stat-value" style="color:var(--red)">{longest_drop}s</div></div>
      <div class="stat-item"><div class="stat-label">Total Pings</div><div class="stat-value">{total_pings}</div></div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Time-of-Day Heatmap</h2>
    <div class="heat-grid">{heatmap_html}</div>
  </div>
  <div class="chart-row">
    <div class="chart-card">
      <h2>Latency Over Time</h2>
      <canvas id="latencyChart" height="100"></canvas>
    </div>
    <div class="chart-card">
      <h2>Latency Distribution</h2>
      <canvas id="histChart" height="100"></canvas>
    </div>
  </div>
  <div class="table-card">
    <h2>Per-Target Breakdown</h2>
    <table>
      <thead><tr><th>Target</th><th>Sent</th><th>OK</th><th>Loss</th><th>Avg</th><th>Min</th><th>Max</th></tr></thead>
      <tbody>{target_rows}</tbody>
    </table>
  </div>
  <div class="table-card"><h2>Connection Drops</h2>{drops_table}</div>
  <div class="table-card"><h2>High Latency Events</h2>{breach_table}</div>
  <div class="footer">Report generated on {report_gen_str} | Connectivity Monitor v4.0</div>
</div>
<script>
const ctx1 = document.getElementById('latencyChart').getContext('2d');
new Chart(ctx1, {{
  type: 'line',
  data: {{
    labels: [{labels_js}],
    datasets: [
      {{ label: 'Latency (ms)', data: [{data_js}], borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,0.1)', borderWidth: 1.5, pointRadius: 0, fill: true, tension: 0.3, spanGaps: false }},
      {{ label: 'Gateway (ms)', data: [{gw_js}], borderColor: '#818cf8', backgroundColor: 'rgba(129,140,248,0.05)', borderWidth: 1, pointRadius: 0, fill: false, tension: 0.3, spanGaps: false }}
    ]
  }},
  options: {{
    responsive: true, interaction: {{ intersect: false, mode: 'index' }},
    plugins: {{ legend: {{ labels: {{ color: '#94a3b8' }} }} }},
    scales: {{
      x: {{ ticks: {{ color: '#64748b', maxTicksLimit: 20, maxRotation: 45 }}, grid: {{ color: 'rgba(51,65,85,0.5)' }} }},
      y: {{ beginAtZero: true, ticks: {{ color: '#64748b' }}, grid: {{ color: 'rgba(51,65,85,0.5)' }}, title: {{ display: true, text: 'ms', color: '#64748b' }} }}
    }}
  }}
}});
const ctx2 = document.getElementById('histChart').getContext('2d');
new Chart(ctx2, {{
  type: 'bar',
  data: {{
    labels: ['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],
    datasets: [{{ label: 'Count', data: [{hist_js}], backgroundColor: ['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'], borderRadius: 6 }}]
  }},
  options: {{
    responsive: true, plugins: {{ legend: {{ display: false }} }},
    scales: {{ x: {{ ticks: {{ color: '#64748b' }}, grid: {{ display: false }} }}, y: {{ beginAtZero: true, ticks: {{ color: '#64748b' }}, grid: {{ color: 'rgba(51,65,85,0.5)' }} }} }}
  }}
}});
</script>
</body>
</html>""".format(
        report_date=kw["report_date"],
        session_start_str=kw["session_start_str"],
        duration_str=kw["duration_str"],
        isp=kw["isp"],
        public_ip=kw["public_ip"],
        health_css=kw["health_css"],
        health_score=kw["health"]["score"],
        health_grade=kw["health"]["grade"],
        uptime_css=kw["uptime_css"],
        up=kw["up"],
        total_success=kw["total_pings"] - kw["total_lost"],
        total_pings=kw["total_pings"],
        avg_css=kw["avg_css"],
        a=kw["a"],
        baseline_text=kw["baseline_text"],
        loss_css=kw["loss_css"],
        l=kw["l"],
        total_lost=kw["total_lost"],
        jitter_css=kw["jitter_css"],
        j=kw["j"],
        drops_css=kw["drops_css"],
        drops_count=kw["drops_count"],
        total_downtime=kw["total_downtime"],
        mn=kw["mn"],
        mx=kw["mx"],
        p95=kw["p95"],
        p99=kw["p99"],
        longest_drop=kw["longest_drop"],
        heatmap_html=kw["heatmap_html"],
        labels_js=kw["labels_js"],
        data_js=kw["data_js"],
        gw_js=kw["gw_js"],
        hist_js=kw["hist_js"],
        target_rows=kw["target_rows"],
        drops_table=kw["drops_table"],
        breach_table=kw["breach_table"],
        report_gen_str=kw["report_gen_str"],
    )
