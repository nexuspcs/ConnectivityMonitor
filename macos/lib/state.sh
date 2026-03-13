#!/bin/bash
# ============================================================================
#  STATE MODULE - Global state variables
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# History arrays (parallel arrays for timestamp, latency, target)
declare -a hist_times=()
declare -a hist_lats=()
declare -a hist_targets=()

# Drop arrays
declare -a drop_starts=()
declare -a drop_ends=()
declare -a drop_durations=()
declare -a drop_targets=()
declare -a drop_diagnoses=()

# Per-target stats (associative arrays)
declare -A per_target_sent=()
declare -A per_target_ok=()
declare -A per_target_lats=()

# Gateway history
declare -a gw_lats=()

# Threshold breach arrays
declare -a breach_starts=()
declare -a breach_ends=()
declare -a breach_durations=()
declare -a breach_avglats=()

# Baseline learning
declare -a baseline_samples=()

# Hourly data (associative: hour -> comma-separated latencies)
declare -A hourly_data=()

# Traceroute entries (each entry is "target|time|hop_data")
declare -a trace_entries=()

# Counters and flags
fail_count=0
is_down=0
down_start=""
session_start=$(date +%s)
total_pings=0
total_success=0
shutdown_flag=0
max_history=1000
last_line_count=0
paused=0
baseline_latency=""
baseline_locked=0
public_ip="detecting..."
isp_name="detecting..."
active_tab=1
breach_active=0
breach_start=""
current_date=$(date +%Y-%m-%d)
last_diagnosis_msg="Initializing..."
last_diagnosis_color="90"
last_wifi_sig=""
last_trace_time=0
trace_pid=""
trace_target=""
trace_outfile="/tmp/cm_traceroute_$$.txt"
rr=0
enable_beep=0

# Directory setup
CM_BASE_DIR="$HOME/Documents/ConnectivityMonitor"
CM_LOGS_DIR="$CM_BASE_DIR/logs"
CM_REPORTS_DIR="$CM_BASE_DIR/reports"
CM_CONFIG_PATH="$CM_BASE_DIR/monitor_config.json"

# Log file paths (set by get_daily_log_paths)
ping_log_file=""
drop_log_file=""
breach_log_file=""

# Adapter info
adapter_name=""
adapter_status="Down"

# ============================================================================
#  RESET STATE
# ============================================================================
reset_state() {
    hist_times=()
    hist_lats=()
    hist_targets=()
    drop_starts=()
    drop_ends=()
    drop_durations=()
    drop_targets=()
    drop_diagnoses=()
    per_target_sent=()
    per_target_ok=()
    per_target_lats=()
    gw_lats=()
    breach_starts=()
    breach_ends=()
    breach_durations=()
    breach_avglats=()
    baseline_samples=()
    hourly_data=()
    trace_entries=()
    fail_count=0
    is_down=0
    total_pings=0
    total_success=0
    session_start=$(date +%s)
    baseline_latency=""
    baseline_locked=0
    last_line_count=0
}
