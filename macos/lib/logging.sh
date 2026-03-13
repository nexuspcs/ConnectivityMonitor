#!/bin/bash
# ============================================================================
#  LOGGING MODULE - CSV logging, HTML report generation, session summary
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# ================================================================
#  CSV LOGGING
# ================================================================
log_ping() {
    local ping_ok="$1" ping_lat="$2" ping_target="$3" ping_time="$4"
    local gw_ok="$5" gw_lat="$6"
    local dns_ok="$7" dns_ms="$8"
    local wifi_sig="$9"

    local lat_val=""
    if [[ -n "$ping_lat" ]]; then lat_val="$ping_lat"; fi
    local gw_lat_val=""
    if [[ $gw_ok -eq 1 ]] && [[ -n "$gw_lat" ]]; then gw_lat_val="$gw_lat"; fi
    local dns_ms_val=""
    if [[ $dns_ok -eq 1 ]] && [[ -n "$dns_ms" ]]; then dns_ms_val="$dns_ms"; fi
    local wifi_val=""
    if [[ -n "$wifi_sig" ]]; then wifi_val="$wifi_sig"; fi

    local loss avg_lat jitter_val p95_val uptime_pct
    loss=$(calc_loss)
    avg_lat=$(calc_avg)
    jitter_val=$(calc_jitter)
    p95_val=$(calc_percentile 95)
    uptime_pct=$(calc_uptime)
    get_trend
    get_health_score

    local bl_val=""
    if [[ -n "$baseline_latency" ]]; then bl_val="$baseline_latency"; fi

    local success="false"
    if [[ $ping_ok -eq 1 ]]; then success="true"; fi

    # Write CSV header if file doesn't exist
    if [[ ! -f "$ping_log_file" ]]; then
        echo '"Timestamp","Target","Success","LatencyMs","GatewayMs","DnsMs","WifiSignalPct","PacketLossPct","AvgLatencyMs","JitterMs","P95Ms","UptimePct","Trend","HealthScore","HealthGrade","BaselineMs","PublicIP","ISP"' > "$ping_log_file"
    fi

    echo "\"${ping_time}\",\"${ping_target}\",\"${success}\",\"${lat_val}\",\"${gw_lat_val}\",\"${dns_ms_val}\",\"${wifi_val}\",\"${loss}\",\"${avg_lat}\",\"${jitter_val}\",\"${p95_val}\",\"${uptime_pct}\",\"${_trend_label}\",\"${_health_score}\",\"${_health_grade}\",\"${bl_val}\",\"${public_ip}\",\"${isp_name}\"" >> "$ping_log_file"
}

log_drop() {
    local start="$1" end="$2" target="$3" diagnosis="$4"
    local now_s end_s dur
    now_s=$(date -j -f "%Y-%m-%d %H:%M:%S" "$end" +%s 2>/dev/null || date +%s)
    end_s=$(date -j -f "%Y-%m-%d %H:%M:%S" "$start" +%s 2>/dev/null || date +%s)
    dur=$(awk "BEGIN {printf \"%.2f\", $now_s - $end_s}")
    if awk "BEGIN {exit !($dur < 0)}"; then dur="0"; fi

    drop_starts+=("$start")
    drop_ends+=("$end")
    drop_durations+=("$dur")
    drop_targets+=("$target")
    drop_diagnoses+=("$diagnosis")

    if [[ ! -f "$drop_log_file" ]]; then
        echo '"Start","End","Duration","Target","Diagnosis"' > "$drop_log_file"
    fi
    echo "\"${start}\",\"${end}\",\"${dur}\",\"${target}\",\"${diagnosis}\"" >> "$drop_log_file"
}

log_threshold_breach() {
    local start="$1" end="$2" avg_lat="$3"
    local now_s end_s dur
    now_s=$(date -j -f "%Y-%m-%d %H:%M:%S" "$end" +%s 2>/dev/null || date +%s)
    end_s=$(date -j -f "%Y-%m-%d %H:%M:%S" "$start" +%s 2>/dev/null || date +%s)
    dur=$(awk "BEGIN {printf \"%.2f\", $now_s - $end_s}")
    if awk "BEGIN {exit !($dur < 0)}"; then dur="0"; fi

    breach_starts+=("$start")
    breach_ends+=("$end")
    breach_durations+=("$dur")
    breach_avglats+=("$avg_lat")

    if [[ ! -f "$breach_log_file" ]]; then
        echo '"Start","End","Duration","AvgLatency"' > "$breach_log_file"
    fi
    echo "\"${start}\",\"${end}\",\"${dur}\",\"${avg_lat}\"" >> "$breach_log_file"
}

# ================================================================
#  HTML REPORT GENERATOR
# ================================================================
generate_html_report() {
    local report_file="$1"
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - session_start))
    local duration_str
    duration_str=$(format_duration $elapsed)

    local loss avg min_lat max_lat p95 p99 jitter_val uptime_pct
    loss=$(calc_loss)
    avg=$(calc_avg)
    min_lat=$(calc_min)
    max_lat=$(calc_max)
    p95=$(calc_percentile 95)
    p99=$(calc_percentile 99)
    jitter_val=$(calc_jitter)
    uptime_pct=$(calc_uptime)
    get_health_score

    # Build chart data
    local chart_labels="" chart_data="" chart_gw=""
    local i
    for ((i = 0; i < ${#hist_times[@]}; i++)); do
        local t="${hist_times[$i]}"
        local tshort="${t:11:8}"
        if [[ -n "$chart_labels" ]]; then chart_labels+=","; fi
        chart_labels+="\"${tshort}\""
        if [[ -n "$chart_data" ]]; then chart_data+=","; fi
        if [[ -n "${hist_lats[$i]}" ]]; then
            chart_data+="${hist_lats[$i]}"
        else
            chart_data+="null"
        fi
    done

    for ((i = 0; i < ${#gw_lats[@]}; i++)); do
        if [[ -n "$chart_gw" ]]; then chart_gw+=","; fi
        if [[ -n "${gw_lats[$i]}" ]]; then
            chart_gw+="${gw_lats[$i]}"
        else
            chart_gw+="null"
        fi
    done

    # Pad gateway data if shorter
    local hist_count=${#hist_lats[@]}
    local gw_count=${#gw_lats[@]}
    while [[ $gw_count -lt $hist_count ]]; do
        chart_gw="null,${chart_gw}"
        gw_count=$((gw_count + 1))
    done

    # Histogram data
    local -a hist_data=(0 0 0 0 0 0)
    for i in "${!hist_lats[@]}"; do
        local v="${hist_lats[$i]}"
        if [[ -n "$v" ]]; then
            if awk "BEGIN {exit !($v < 10)}"; then hist_data[0]=$((hist_data[0] + 1))
            elif awk "BEGIN {exit !($v < 25)}"; then hist_data[1]=$((hist_data[1] + 1))
            elif awk "BEGIN {exit !($v < 50)}"; then hist_data[2]=$((hist_data[2] + 1))
            elif awk "BEGIN {exit !($v < 100)}"; then hist_data[3]=$((hist_data[3] + 1))
            elif awk "BEGIN {exit !($v < 200)}"; then hist_data[4]=$((hist_data[4] + 1))
            else hist_data[5]=$((hist_data[5] + 1))
            fi
        fi
    done
    local hist_js="${hist_data[0]},${hist_data[1]},${hist_data[2]},${hist_data[3]},${hist_data[4]},${hist_data[5]}"

    # Per-target table rows
    local target_rows=""
    for t in "${!per_target_sent[@]}"; do
        local info_sent="${per_target_sent[$t]}"
        local info_ok="${per_target_ok[$t]:-0}"
        local t_loss=0 t_avg=0 t_min=0 t_max=0
        if [[ $info_sent -gt 0 ]]; then
            t_loss=$(awk "BEGIN {printf \"%.1f\", (1 - $info_ok/$info_sent) * 100}")
        fi
        local lats_str="${per_target_lats[$t]:-}"
        if [[ -n "$lats_str" ]]; then
            local tstats
            tstats=$(echo "$lats_str" | tr ',' '\n' | awk 'BEGIN {min=999999; max=0; s=0; n=0} {s+=$1; n++; if($1<min) min=$1; if($1>max) max=$1} END {printf "%.1f %.1f %.1f", s/n, min, max}')
            t_avg=$(echo "$tstats" | awk '{print $1}')
            t_min=$(echo "$tstats" | awk '{print $2}')
            t_max=$(echo "$tstats" | awk '{print $3}')
        fi
        local row_class=""
        if awk "BEGIN {exit !($t_loss >= 5)}"; then row_class=' class="bad"'
        elif awk "BEGIN {exit !($t_loss > 0)}"; then row_class=' class="warn"'
        fi
        target_rows+="<tr${row_class}><td>${t}</td><td>${info_sent}</td><td>${info_ok}</td><td>${t_loss}%</td><td>${t_avg}ms</td><td>${t_min}ms</td><td>${t_max}ms</td></tr>"
    done

    # Drop table rows
    local drop_rows=""
    for ((d = 0; d < ${#drop_starts[@]}; d++)); do
        local dur="${drop_durations[$d]}"
        local row_class=""
        if awk "BEGIN {exit !($dur >= 30)}"; then row_class=' class="bad"'
        elif awk "BEGIN {exit !($dur >= 10)}"; then row_class=' class="warn"'
        fi
        drop_rows+="<tr${row_class}><td>${drop_starts[$d]}</td><td>${drop_ends[$d]}</td><td>${dur}s</td><td>${drop_targets[$d]}</td><td>${drop_diagnoses[$d]}</td></tr>"
    done

    # Breach table rows
    local breach_rows=""
    for ((b = 0; b < ${#breach_starts[@]}; b++)); do
        breach_rows+="<tr><td>${breach_starts[$b]}</td><td>${breach_ends[$b]}</td><td>${breach_durations[$b]}s</td><td>${breach_avglats[$b]}ms</td></tr>"
    done

    # Total downtime
    local total_downtime=0 longest_drop=0
    if [[ ${#drop_durations[@]} -gt 0 ]]; then
        total_downtime=$(printf '%s\n' "${drop_durations[@]}" | awk '{s+=$1} END {printf "%.2f", s}')
        longest_drop=$(printf '%s\n' "${drop_durations[@]}" | awk 'BEGIN{m=0} {if($1>m)m=$1} END {printf "%.2f", m}')
    fi

    # CSS colors
    local health_css="#22c55e"
    if [[ $_health_score -lt 60 ]]; then health_css="#ef4444"
    elif [[ $_health_score -lt 80 ]]; then health_css="#f59e0b"
    fi

    local uptime_css="#22c55e"
    if awk "BEGIN {exit !($uptime_pct < 95)}"; then uptime_css="#ef4444"
    elif awk "BEGIN {exit !($uptime_pct < 99)}"; then uptime_css="#f59e0b"
    fi

    local avg_css="#22c55e"
    if awk "BEGIN {exit !($avg >= 80)}"; then avg_css="#ef4444"
    elif awk "BEGIN {exit !($avg >= 30)}"; then avg_css="#f59e0b"
    fi

    local loss_css="#22c55e"
    if awk "BEGIN {exit !($loss >= 5)}"; then loss_css="#ef4444"
    elif awk "BEGIN {exit !($loss > 0)}"; then loss_css="#f59e0b"
    fi

    local jitter_css="#22c55e"
    if awk "BEGIN {exit !($jitter_val >= 15)}"; then jitter_css="#ef4444"
    elif awk "BEGIN {exit !($jitter_val >= 5)}"; then jitter_css="#f59e0b"
    fi

    local drops_css="#22c55e"
    if [[ ${#drop_starts[@]} -gt 0 ]]; then drops_css="#ef4444"; fi

    local baseline_text="N/A"
    if [[ -n "$baseline_latency" ]]; then baseline_text="${baseline_latency}ms"; fi

    local drops_table_html='<p class="empty">No connection drops recorded during this session.</p>'
    if [[ ${#drop_starts[@]} -gt 0 ]]; then
        drops_table_html="<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Target</th><th>Diagnosis</th></tr></thead><tbody>${drop_rows}</tbody></table>"
    fi

    local breach_table_html='<p class="empty">No high latency events recorded during this session.</p>'
    if [[ ${#breach_starts[@]} -gt 0 ]]; then
        breach_table_html="<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Avg Latency</th></tr></thead><tbody>${breach_rows}</tbody></table>"
    fi

    # Heatmap HTML
    local heatmap_html=""
    local hh
    for ((hh = 0; hh < 24; hh++)); do
        local hh_label
        hh_label=$(printf "%02d:00" $hh)
        local hh_avg="-" hh_color="#64748b"
        local hdata="${hourly_data[$hh]:-}"
        if [[ -n "$hdata" ]]; then
            local hh_avg_val
            hh_avg_val=$(echo "$hdata" | tr ',' '\n' | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print 0}')
            hh_avg="${hh_avg_val}ms"
            if awk "BEGIN {exit !($hh_avg_val < 30)}"; then hh_color="#22c55e"
            elif awk "BEGIN {exit !($hh_avg_val < 60)}"; then hh_color="#f59e0b"
            else hh_color="#ef4444"
            fi
        fi
        heatmap_html+="<div class='heat-cell' style='background:${hh_color}'><span class='heat-hour'>${hh_label}</span><span class='heat-val'>${hh_avg}</span></div>"
    done

    local report_date
    report_date=$(date "+%Y-%m-%d %H:%M")
    local session_start_str
    session_start_str=$(date -r "$session_start" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date "+%Y-%m-%d %H:%M:%S")
    local report_gen_str
    report_gen_str=$(date "+%Y-%m-%d %H:%M:%S")
    local total_pings_lost=$((total_pings - total_success))

    mkdir -p "$(dirname "$report_file")"

    cat > "$report_file" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Network Report - ${report_date}</title>
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
    text-align: center; padding: 40px 20px;
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    border: 1px solid var(--border); border-radius: 16px; margin-bottom: 24px;
  }
  .header h1 {
    font-size: 2rem; font-weight: 700;
    background: linear-gradient(90deg, #38bdf8, #818cf8);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 8px;
  }
  .header .subtitle { color: var(--muted); font-size: 0.95rem; }
  .header .session-info {
    display: flex; justify-content: center; gap: 32px; margin-top: 16px; flex-wrap: wrap;
  }
  .header .session-info span { color: var(--muted); font-size: 0.85rem; }
  .header .session-info strong { color: var(--text); }
  .score-row {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px; margin-bottom: 24px;
  }
  .score-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; text-align: center;
  }
  .score-card .label {
    font-size: 0.8rem; text-transform: uppercase; letter-spacing: 1px;
    color: var(--muted); margin-bottom: 8px;
  }
  .score-card .value { font-size: 2rem; font-weight: 700; }
  .score-card .sub { font-size: 0.8rem; color: var(--muted); margin-top: 4px; }
  .chart-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px;
  }
  .chart-card h2 { font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }
  .chart-row { display: grid; grid-template-columns: 2fr 1fr; gap: 24px; margin-bottom: 24px; }
  @media (max-width: 900px) { .chart-row { grid-template-columns: 1fr; } }
  .table-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px; overflow-x: auto;
  }
  .table-card h2 { font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th {
    text-align: left; padding: 10px 12px; border-bottom: 2px solid var(--border);
    color: var(--muted); font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.5px;
  }
  td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
  tr:hover { background: rgba(56, 189, 248, 0.05); }
  tr.bad { background: rgba(239, 68, 68, 0.1); }
  tr.warn { background: rgba(245, 158, 11, 0.1); }
  .empty { color: var(--muted); font-style: italic; padding: 20px; text-align: center; }
  .stats-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;
  }
  .stat-item {
    background: rgba(15, 23, 42, 0.5); padding: 14px; border-radius: 8px; border: 1px solid var(--border);
  }
  .stat-item .stat-label { font-size: 0.75rem; text-transform: uppercase; color: var(--muted); letter-spacing: 0.5px; }
  .stat-item .stat-value { font-size: 1.3rem; font-weight: 700; margin-top: 4px; }
  .heat-grid { display: grid; grid-template-columns: repeat(24, 1fr); gap: 4px; margin: 16px 0; }
  .heat-cell { padding: 8px 4px; border-radius: 6px; text-align: center; color: #fff; font-size: 0.7rem; }
  .heat-hour { display: block; font-weight: 600; }
  .heat-val { display: block; font-size: 0.65rem; opacity: 0.8; }
  .footer { text-align: center; padding: 24px; color: var(--muted); font-size: 0.8rem; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>Network Connectivity Report</h1>
    <p class="subtitle">Generated by Connectivity Monitor v4.0 (macOS)</p>
    <div class="session-info">
      <span>Started: <strong>${session_start_str}</strong></span>
      <span>Duration: <strong>${duration_str}</strong></span>
      <span>ISP: <strong>${isp_name}</strong></span>
      <span>Public IP: <strong>${public_ip}</strong></span>
    </div>
  </div>
  <div class="score-row">
    <div class="score-card">
      <div class="label">Health Score</div>
      <div class="value" style="color: ${health_css}">${_health_score}/100</div>
      <div class="sub">Grade: ${_health_grade}</div>
    </div>
    <div class="score-card">
      <div class="label">Uptime</div>
      <div class="value" style="color: ${uptime_css}">${uptime_pct}%</div>
      <div class="sub">${total_success} / ${total_pings} pings</div>
    </div>
    <div class="score-card">
      <div class="label">Avg Latency</div>
      <div class="value" style="color: ${avg_css}">${avg}ms</div>
      <div class="sub">Baseline: ${baseline_text}</div>
    </div>
    <div class="score-card">
      <div class="label">Packet Loss</div>
      <div class="value" style="color: ${loss_css}">${loss}%</div>
      <div class="sub">${total_pings_lost} packets lost</div>
    </div>
    <div class="score-card">
      <div class="label">Jitter</div>
      <div class="value" style="color: ${jitter_css}">${jitter_val}ms</div>
      <div class="sub">Avg variation</div>
    </div>
    <div class="score-card">
      <div class="label">Outages</div>
      <div class="value" style="color: ${drops_css}">${#drop_starts[@]}</div>
      <div class="sub">Total: ${total_downtime}s</div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Detailed Statistics</h2>
    <div class="stats-grid">
      <div class="stat-item"><div class="stat-label">Min Latency</div><div class="stat-value" style="color:var(--green)">${min_lat}ms</div></div>
      <div class="stat-item"><div class="stat-label">Max Latency</div><div class="stat-value" style="color:var(--red)">${max_lat}ms</div></div>
      <div class="stat-item"><div class="stat-label">P95 Latency</div><div class="stat-value" style="color:var(--yellow)">${p95}ms</div></div>
      <div class="stat-item"><div class="stat-label">P99 Latency</div><div class="stat-value" style="color:var(--yellow)">${p99}ms</div></div>
      <div class="stat-item"><div class="stat-label">Longest Drop</div><div class="stat-value" style="color:var(--red)">${longest_drop}s</div></div>
      <div class="stat-item"><div class="stat-label">Total Pings</div><div class="stat-value">${total_pings}</div></div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Time-of-Day Heatmap</h2>
    <div class="heat-grid">${heatmap_html}</div>
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
      <tbody>${target_rows}</tbody>
    </table>
  </div>
  <div class="table-card"><h2>Connection Drops</h2>${drops_table_html}</div>
  <div class="table-card"><h2>High Latency Events</h2>${breach_table_html}</div>
  <div class="footer">Report generated on ${report_gen_str} | Connectivity Monitor v4.0 (macOS)</div>
</div>
<script>
const ctx1 = document.getElementById('latencyChart').getContext('2d');
new Chart(ctx1, {
  type: 'line',
  data: {
    labels: [${chart_labels}],
    datasets: [
      { label: 'Latency (ms)', data: [${chart_data}], borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,0.1)', borderWidth: 1.5, pointRadius: 0, fill: true, tension: 0.3, spanGaps: false },
      { label: 'Gateway (ms)', data: [${chart_gw}], borderColor: '#818cf8', backgroundColor: 'rgba(129,140,248,0.05)', borderWidth: 1, pointRadius: 0, fill: false, tension: 0.3, spanGaps: false }
    ]
  },
  options: {
    responsive: true, interaction: { intersect: false, mode: 'index' },
    plugins: { legend: { labels: { color: '#94a3b8' } } },
    scales: {
      x: { ticks: { color: '#64748b', maxTicksLimit: 20, maxRotation: 45 }, grid: { color: 'rgba(51,65,85,0.5)' } },
      y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' }, title: { display: true, text: 'ms', color: '#64748b' } }
    }
  }
});
const ctx2 = document.getElementById('histChart').getContext('2d');
new Chart(ctx2, {
  type: 'bar',
  data: {
    labels: ['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],
    datasets: [{ label: 'Count', data: [${hist_js}], backgroundColor: ['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'], borderRadius: 6 }]
  },
  options: {
    responsive: true, plugins: { legend: { display: false } },
    scales: { x: { ticks: { color: '#64748b' }, grid: { display: false } }, y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' } } }
  }
});
</script>
</body>
</html>
HTMLEOF
}

# ================================================================
#  SESSION SUMMARY (CONSOLE)
# ================================================================
show_summary() {
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - session_start))
    get_health_score
    local loss avg jitter_val min_lat max_lat p95 p99 uptime_pct
    loss=$(calc_loss)
    avg=$(calc_avg)
    jitter_val=$(calc_jitter)
    min_lat=$(calc_min)
    max_lat=$(calc_max)
    p95=$(calc_percentile 95)
    p99=$(calc_percentile 99)
    uptime_pct=$(calc_uptime)

    echo ""
    printf '\033[36m+================================================================+\033[0m\n'
    printf '\033[36m|                     SESSION SUMMARY                             |\033[0m\n'
    printf '\033[36m+================================================================+\033[0m\n'
    echo ""
    printf "\033[${_health_color}m  Health Score : %s/100 (%s)\033[0m\n" "$_health_score" "$_health_grade"
    printf "\033[37m  Duration     : %s\033[0m\n" "$(format_duration $elapsed)"
    printf "\033[37m  Total Pings  : %s\033[0m\n" "$total_pings"
    printf "\033[32m  Successful   : %s\033[0m\n" "$total_success"
    printf "\033[31m  Failed       : %s\033[0m\n" "$((total_pings - total_success))"

    local loss_c
    loss_c=$(loss_color "$loss")
    printf "\033[${loss_c}m  Packet Loss  : %s%%\033[0m\n" "$loss"
    printf "\033[37m  Uptime       : %s%%\033[0m\n" "$uptime_pct"
    echo ""
    printf "\033[37m  Latency  Avg : %s ms\033[0m\n" "$avg"
    printf "\033[32m           Min : %s ms\033[0m\n" "$min_lat"
    printf "\033[31m           Max : %s ms\033[0m\n" "$max_lat"
    printf "\033[33m           P95 : %s ms\033[0m\n" "$p95"
    printf "\033[33m           P99 : %s ms\033[0m\n" "$p99"
    printf "\033[37m        Jitter : %s ms\033[0m\n" "$jitter_val"

    if [[ $baseline_locked -eq 1 ]]; then
        printf "\033[36m      Baseline : %s ms\033[0m\n" "$baseline_latency"
    fi

    echo ""
    printf "\033[37m  ISP          : %s\033[0m\n" "$isp_name"
    printf "\033[37m  Public IP    : %s\033[0m\n" "$public_ip"
    echo ""

    local drop_color="32"
    if [[ ${#drop_starts[@]} -gt 0 ]]; then drop_color="31"; fi
    printf "\033[${drop_color}m  Total Drops  : %s\033[0m\n" "${#drop_starts[@]}"

    if [[ ${#drop_durations[@]} -gt 0 ]]; then
        local total_down longest_d
        total_down=$(printf '%s\n' "${drop_durations[@]}" | awk '{s+=$1} END {printf "%.2f", s}')
        longest_d=$(printf '%s\n' "${drop_durations[@]}" | awk 'BEGIN{m=0} {if($1>m)m=$1} END {printf "%.2f", m}')
        printf "\033[31m  Total Downtime : %ss\033[0m\n" "$total_down"
        printf "\033[31m  Longest Drop   : %ss\033[0m\n" "$longest_d"
    fi

    printf "\033[33m  Latency Breaches : %s\033[0m\n" "${#breach_starts[@]}"
    echo ""

    printf "\033[35m  Per-Target Summary:\033[0m\n"
    for t in "${!per_target_sent[@]}"; do
        local info_sent="${per_target_sent[$t]}"
        local info_ok="${per_target_ok[$t]:-0}"
        local t_loss=0 t_avg=0 t_min=0 t_max=0
        if [[ $info_sent -gt 0 ]]; then
            t_loss=$(awk "BEGIN {printf \"%.1f\", (1 - $info_ok/$info_sent) * 100}")
        fi
        local lats_str="${per_target_lats[$t]:-}"
        if [[ -n "$lats_str" ]]; then
            local tstats
            tstats=$(echo "$lats_str" | tr ',' '\n' | awk 'BEGIN {min=999999; max=0; s=0; n=0} {s+=$1; n++; if($1<min) min=$1; if($1>max) max=$1} END {printf "%.1f %.1f %.1f", s/n, min, max}')
            t_avg=$(echo "$tstats" | awk '{print $1}')
            t_min=$(echo "$tstats" | awk '{print $2}')
            t_max=$(echo "$tstats" | awk '{print $3}')
        fi
        printf "\033[37m    %-18s Sent:%5d  Loss:%6s%%  Avg:%6sms  Min:%6sms  Max:%6sms\033[0m\n" "$t" "$info_sent" "$t_loss" "$t_avg" "$t_min" "$t_max"
    done

    echo ""
    printf '\033[36m=================================================================\033[0m\n'
    echo ""
}
