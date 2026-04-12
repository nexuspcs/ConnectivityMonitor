#!/bin/bash
# ============================================================================
#  STATE MODULE - Global state variables
#  Connectivity Monitor v4.0 (macOS)
#
#  This module defines all global variables used throughout the monitoring
#  session. Variables are organized into logical groups for clarity.
#
#  IMPORTANT: This file must be sourced before all other library modules.
#
#  Global Variable Groups:
#  - History arrays: Store ping results over time (circular buffer, max 1000)
#  - Drop tracking: Record connectivity drop events
#  - Per-target stats: Statistics per ping target (associative arrays)
#  - Gateway tracking: Monitor gateway latency separately
#  - Baseline learning: Learn normal latency from first 30 pings
#  - Hourly heatmap: Aggregate latency by hour of day
#  - Traceroute data: Store recent traceroute results
#  - Session state: Counters, flags, timestamps
#  - Directory paths: Base directory, logs, reports, config
# ============================================================================

# ============================================================================
#  HISTORY ARRAYS - Recent ping results (circular buffer)
# ============================================================================
# Parallel arrays storing ping history (max 1000 entries):
# - hist_times: Unix timestamps of ping attempts
# - hist_lats: Latency values in ms (empty string for failed pings)
# - hist_targets: Target IP/hostname for each ping
declare -a hist_times=()
declare -a hist_lats=()
declare -a hist_targets=()

# ============================================================================
#  DROP TRACKING - Connectivity outage events
# ============================================================================
# Parallel arrays storing drop events:
# - drop_starts: ISO 8601 timestamp when drop started
# - drop_ends: ISO 8601 timestamp when connectivity restored
# - drop_durations: Duration in seconds
# - drop_targets: Target being monitored when drop occurred
# - drop_diagnoses: Diagnostic message (e.g., "Gateway unreachable")
declare -a drop_starts=()
declare -a drop_ends=()
declare -a drop_durations=()
declare -a drop_targets=()
declare -a drop_diagnoses=()

# ============================================================================
#  PER-TARGET STATISTICS - Associative arrays keyed by target IP/hostname
# ============================================================================
# Track statistics for each ping target independently:
# - per_target_sent: Number of pings sent to this target
# - per_target_ok: Number of successful pings
# - per_target_lats: Comma-separated latency values
declare -A per_target_sent=()
declare -A per_target_ok=()
declare -A per_target_lats=()

# ============================================================================
#  GATEWAY TRACKING
# ============================================================================
# Gateway latency history (separate from main ping targets)
declare -a gw_lats=()

# ============================================================================
#  LATENCY THRESHOLD BREACH TRACKING
# ============================================================================
# Track periods when latency exceeds configured threshold:
# - breach_starts: ISO timestamp when breach started
# - breach_ends: ISO timestamp when latency returned to normal
# - breach_durations: Duration in seconds
# - breach_avglats: Average latency during breach period
declare -a breach_starts=()
declare -a breach_ends=()
declare -a breach_durations=()
declare -a breach_avglats=()

# ============================================================================
#  BASELINE LEARNING
# ============================================================================
# Store first 30 successful ping latencies to establish baseline
declare -a baseline_samples=()

# ============================================================================
#  HOURLY HEATMAP DATA
# ============================================================================
# Associative array: hour (0-23) -> comma-separated latencies
# Used to generate 24-hour heatmap showing time-of-day patterns
declare -A hourly_data=()

# ============================================================================
#  TRACEROUTE DATA
# ============================================================================
# Array of recent traceroute results (max 3 entries)
# Each entry format: "target|timestamp|hop_data"
declare -a trace_entries=()

# ============================================================================
#  SESSION STATE - Counters and flags
# ============================================================================
fail_count=0                # Consecutive failed pings
is_down=0                   # Boolean: currently in a drop state (0=up, 1=down)
down_start=""               # ISO timestamp when current drop started
session_start=$(date +%s)   # Unix timestamp of session start
total_pings=0               # Total ping attempts this session
total_success=0             # Total successful pings this session
shutdown_flag=0             # Boolean: user requested shutdown (0=run, 1=exit)
max_history=1000            # Maximum ping history entries (circular buffer)
last_line_count=0           # Terminal line count for display updates
paused=0                    # Boolean: monitoring paused (0=running, 1=paused)
baseline_latency=""         # Calculated baseline latency (ms) after 30 samples
baseline_locked=0           # Boolean: baseline calculation complete
public_ip="detecting..."    # Public IP address (from ip-api.com)
isp_name="detecting..."     # ISP name (from ip-api.com)
active_tab=1                # Currently displayed dashboard tab (1-5)
breach_active=0             # Boolean: currently in latency threshold breach
breach_start=""             # ISO timestamp of current breach start
current_date=$(date +%Y-%m-%d)  # Current date for log rotation detection
last_diagnosis_msg="Initializing..."  # Last diagnostic message
last_diagnosis_color="90"   # ANSI color code for last diagnosis
last_wifi_sig=""            # Last WiFi signal strength percentage
last_trace_time=0           # Unix timestamp of last traceroute invocation
trace_pid=""                # PID of background traceroute process
trace_target=""             # Target for current/last traceroute
# Use mktemp for secure temporary file creation
trace_outfile=$(mktemp 2>/dev/null) || trace_outfile="/tmp/cm_traceroute_$$_${RANDOM}.txt"
rr=0                        # Round-robin index for target rotation
enable_beep=0               # Boolean: audible beep on drops (0=off, 1=on)

# ============================================================================
#  DIRECTORY PATHS
# ============================================================================
CM_BASE_DIR="$HOME/Documents/ConnectivityMonitor"
CM_LOGS_DIR="$CM_BASE_DIR/logs"
CM_REPORTS_DIR="$CM_BASE_DIR/reports"
CM_CONFIG_PATH="$CM_BASE_DIR/monitor_config.json"

# ============================================================================
#  LOG FILE PATHS (set by get_daily_log_paths function)
# ============================================================================
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
