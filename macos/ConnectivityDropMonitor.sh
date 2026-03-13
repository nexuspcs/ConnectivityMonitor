#!/bin/bash
# ============================================================================
#  CONNECTIVITY MONITOR v4.0 (macOS)
#
#  A comprehensive network connectivity monitor with a terminal-based
#  dashboard featuring 5 tabbed views, real-time latency tracking,
#  drop detection, traceroute on outage, and HTML report generation.
#
#  Modular architecture:
#    lib/state.sh   - Global state variables
#    lib/config.sh  - Config save/load, prompt helpers, adapter selection
#    lib/network.sh - Ping, DNS, gateway, public IP, WiFi, traceroute
#    lib/metrics.sh - Statistics, health score, trend, diagnosis
#    lib/display.sh - Graph builders, sparkline, histogram, heatmap
#    lib/tabs.sh    - Tab bar, all 5 tab builders, renderer
#    lib/logging.sh - CSV logging, HTML report generation, session summary
#
#  Usage:
#    chmod +x ConnectivityDropMonitor.sh
#    ./ConnectivityDropMonitor.sh
#
#  Requirements: macOS, bash 3.2+, python3 (for JSON config & IP detection)
# ============================================================================

set -u

# Resolve the script's directory for sourcing modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ================================================================
#  SOURCE MODULES
# ================================================================
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/metrics.sh"
source "${SCRIPT_DIR}/lib/display.sh"
source "${SCRIPT_DIR}/lib/tabs.sh"
source "${SCRIPT_DIR}/lib/logging.sh"

# ================================================================
#  CLEANUP HANDLER
# ================================================================
cleanup() {
    shutdown_flag=1
}
trap cleanup INT TERM

# ================================================================
#  STARTUP
# ================================================================
ensure_dirs
get_daily_log_paths

# Hide cursor
printf '\033[?25l'

# Try to load saved config
use_config=0
if load_config; then
    echo ""
    printf '\033[32m Found saved configuration.\033[0m\n'
    printf "\033[90m   Adapter   : %s\033[0m\n" "$(config_get adapter)"
    printf "\033[90m   Targets   : %s\033[0m\n" "$(config_get targets)"
    printf "\033[90m   Poll      : %ss\033[0m\n" "$(config_get poll)"
    printf "\033[90m   Threshold : %s\033[0m\n" "$(config_get threshold)"
    printf "\033[90m   Lat Warn  : %sms\033[0m\n" "$(config_get latWarn)"
    printf "\033[90m   DNS       : %s\033[0m\n" "$(config_get enableDns)"
    printf "\033[90m   Beep      : %s\033[0m\n" "$(config_get enableBeep)"
    if prompt_yesno " Use saved config?" "Y"; then
        use_config=1
    fi
fi

if [[ $use_config -eq 1 ]]; then
    adapter_name="$(config_get adapter)"
    poll=$(config_get poll)
    threshold=$(config_get threshold)
    IFS=',' read -ra targets <<< "$(config_get targets)"
    lat_warn=$(config_get latWarn)
    enable_dns_raw=$(config_get enableDns)
    if [[ "$enable_dns_raw" == "True" ]] || [[ "$enable_dns_raw" == "true" ]] || [[ "$enable_dns_raw" == "1" ]]; then
        enable_dns=1
    else
        enable_dns=0
    fi
    dns_target="$(config_get dnsTarget)"
    enable_beep_raw=$(config_get enableBeep)
    if [[ "$enable_beep_raw" == "True" ]] || [[ "$enable_beep_raw" == "true" ]] || [[ "$enable_beep_raw" == "1" ]]; then
        enable_beep=1
    else
        enable_beep=0
    fi
    # Check adapter exists
    check_adapter_status
else
    select_adapter
    echo ""
    poll=$(prompt_default " Poll interval (seconds)" "2")
    threshold=$(prompt_default " Failure threshold for drop" "4")
    targets_raw=$(prompt_default " Ping targets (comma-sep)" "1.1.1.1,8.8.8.8,208.67.222.222")
    IFS=',' read -ra targets <<< "$targets_raw"
    lat_warn=$(prompt_default " Latency warning (ms)" "100")
    if prompt_yesno " Enable DNS health check?" "Y"; then
        enable_dns=1
        dns_target=$(prompt_default " DNS test hostname" "google.com")
    else
        enable_dns=0
        dns_target=""
    fi
    if prompt_yesno " Audible alert on drop?" "N"; then
        enable_beep=1
    else
        enable_beep=0
    fi

    # Save config
    local_targets="${targets[*]}"
    local_targets="${local_targets// /,}"
    save_config "$adapter_name" "$poll" "$threshold" "$local_targets" "$lat_warn" "$enable_dns" "$dns_target" "$enable_beep"
    printf "\033[90m Config saved to %s\033[0m\n" "$CM_CONFIG_PATH"
fi

# Detect public IP
printf "\033[90m Detecting public IP...\033[0m\n"
detect_public_ip

# Clear screen and start
clear

# Initialize variables used in the main loop
gw="N/A"
local_ip="N/A"
target="${targets[0]}"
gw_ok=0
gw_lat=""
_ping_ok=0
_ping_lat=""
_dns_ok=1
_dns_ms=""
ping_time=""
end_time=""
breach_end_time=""
breach_avg=""
auto_report=""
snap_file=""

# ================================================================
#  MAIN LOOP
# ================================================================
while [[ $shutdown_flag -eq 0 ]]; do

    # Check for daily log rotation
    check_date_roll

    # Handle hotkeys (non-blocking single character read)
    if read -rsn1 -t 0.01 key 2>/dev/null; then
        case "$key" in
            1) active_tab=1 ;;
            2) active_tab=2 ;;
            3) active_tab=3 ;;
            4) active_tab=4 ;;
            5) active_tab=5 ;;
            p|P) paused=$(( 1 - paused )) ;;
            r|R) reset_state ;;
            q|Q) shutdown_flag=1; continue ;;
            e|E)
                snap_file="${CM_REPORTS_DIR}/report_$(date +%Y-%m-%d_%H%M%S).html"
                generate_html_report "$snap_file"
                ;;
        esac
    fi

    if [[ $paused -eq 1 ]]; then
        build_frame "$gw" "$local_ip" "$target" "$_ping_ok" "$_ping_lat" \
            "$gw_ok" "$gw_lat" "$_dns_ok" "$_dns_ms" "$lat_warn" "$enable_dns"
        sleep 0.5
        continue
    fi

    # Check adapter
    check_adapter_status

    # Detect gateway and local IP
    gw=$(detect_gateway)
    local_ip=$(get_local_ip "$adapter_name")

    # Select target (round robin)
    target="${targets[$((rr % ${#targets[@]}))]}"
    rr=$((rr + 1))

    # Ping target
    if [[ "$adapter_status" != "Up" ]]; then
        _ping_ok=0
        _ping_lat=""
        update_history "" "$target"
    else
        ping_test "$target"
        if [[ $_ping_ok -eq 1 ]]; then
            update_history "$_ping_lat" "$target"
        else
            update_history "" "$target"
        fi
    fi

    # Update hourly data
    if [[ $_ping_ok -eq 1 ]] && [[ -n "$_ping_lat" ]]; then
        update_hourly_data "$_ping_lat"
    fi

    # Ping gateway
    gw_ok=0
    gw_lat=""
    if [[ "$adapter_status" == "Up" ]] && [[ "$gw" != "N/A" ]] && [[ "$gw" != "None" ]]; then
        ping_test "$gw"
        gw_ok=$_ping_ok
        gw_lat="$_ping_lat"
        if [[ $gw_ok -eq 1 ]]; then
            update_gw_history "$gw_lat"
        else
            update_gw_history ""
        fi
        # Restore target ping result
        ping_test "$target"
    fi

    # DNS test
    _dns_ok=1
    _dns_ms=""
    if [[ $enable_dns -eq 1 ]] && [[ "$adapter_status" == "Up" ]]; then
        dns_test "$dns_target"
    fi

    # WiFi signal (every 5th iteration)
    if [[ $((rr % 5)) -eq 0 ]]; then
        get_wifi_signal
    fi

    # Diagnose
    diagnose_issue "$gw_ok" "$_ping_ok"

    # Log ping
    ping_time=$(date "+%Y-%m-%d %H:%M:%S.%N" 2>/dev/null || date "+%Y-%m-%d %H:%M:%S")
    log_ping "$_ping_ok" "$_ping_lat" "$target" "$ping_time" \
        "$gw_ok" "$gw_lat" "$_dns_ok" "$_dns_ms" "$last_wifi_sig"

    # Collect any background traceroute results
    collect_traceroute

    # Outage detection
    if [[ $_ping_ok -eq 0 ]]; then
        fail_count=$((fail_count + 1))
        if [[ $fail_count -ge $threshold ]] && [[ $is_down -eq 0 ]]; then
            is_down=1
            down_start=$(date "+%Y-%m-%d %H:%M:%S")
            if [[ $enable_beep -eq 1 ]]; then
                # macOS beep
                osascript -e 'beep' 2>/dev/null || true
            fi
            start_traceroute "$target"
        fi
    else
        if [[ $is_down -eq 1 ]]; then
            end_time=$(date "+%Y-%m-%d %H:%M:%S")
            log_drop "$down_start" "$end_time" "$target" "$last_diagnosis_msg"
            is_down=0
            if [[ $enable_beep -eq 1 ]]; then
                osascript -e 'beep 2' 2>/dev/null || true
            fi
        fi
        fail_count=0
    fi

    # High latency threshold breach tracking
    if [[ $_ping_ok -eq 1 ]] && [[ -n "$_ping_lat" ]]; then
        if awk "BEGIN {exit !($_ping_lat >= $lat_warn)}"; then
            if [[ $breach_active -eq 0 ]]; then
                breach_active=1
                breach_start=$(date "+%Y-%m-%d %H:%M:%S")
            fi
            if [[ $enable_beep -eq 1 ]]; then
                osascript -e 'beep' 2>/dev/null || true
            fi
        else
            if [[ $breach_active -eq 1 ]]; then
                breach_end_time=$(date "+%Y-%m-%d %H:%M:%S")
                breach_avg=$(calc_avg)
                log_threshold_breach "$breach_start" "$breach_end_time" "$breach_avg"
                breach_active=0
            fi
        fi
    else
        if [[ $breach_active -eq 1 ]]; then
            breach_end_time=$(date "+%Y-%m-%d %H:%M:%S")
            breach_avg=$(calc_avg)
            log_threshold_breach "$breach_start" "$breach_end_time" "$breach_avg"
            breach_active=0
        fi
    fi

    # Re-detect public IP every 100 pings
    if [[ $((total_pings % 100)) -eq 0 ]] && [[ $total_pings -gt 0 ]]; then
        detect_public_ip
    fi

    # Auto-generate HTML report every 500 pings
    if [[ $((total_pings % 500)) -eq 0 ]] && [[ $total_pings -gt 0 ]]; then
        auto_report="${CM_REPORTS_DIR}/report_$(date +%Y-%m-%d_%H%M%S).html"
        generate_html_report "$auto_report"
    fi

    # Render
    build_frame "$gw" "$local_ip" "$target" "$_ping_ok" "$_ping_lat" \
        "$gw_ok" "$gw_lat" "$_dns_ok" "$_dns_ms" "$lat_warn" "$enable_dns"

    sleep "$poll"
done

# ================================================================
#  SHUTDOWN
# ================================================================

# Clean up background traceroute
if [[ -n "$trace_pid" ]]; then
    kill "$trace_pid" 2>/dev/null || true
    wait "$trace_pid" 2>/dev/null || true
    trace_pid=""
fi
rm -f "$trace_outfile"

if [[ $is_down -eq 1 ]]; then
    end_time=$(date "+%Y-%m-%d %H:%M:%S")
    log_drop "$down_start" "$end_time" "N/A" "Session ended during outage"
fi

if [[ $breach_active -eq 1 ]]; then
    breach_end_time=$(date "+%Y-%m-%d %H:%M:%S")
    breach_avg=$(calc_avg)
    log_threshold_breach "$breach_start" "$breach_end_time" "$breach_avg"
fi

# Generate final HTML report
clear
printf "\033[36m Generating HTML report...\033[0m\n"
final_report="${CM_REPORTS_DIR}/report_$(date +%Y-%m-%d_%H%M%S).html"
generate_html_report "$final_report"

show_summary

printf "\033[90m Files saved to:\033[0m\n"
printf "\033[37m   Base dir    : %s\033[0m\n" "$CM_BASE_DIR"
printf "\033[37m   Ping log    : %s\033[0m\n" "$ping_log_file"
printf "\033[37m   Drop log    : %s\033[0m\n" "$drop_log_file"
printf "\033[37m   Breach log  : %s\033[0m\n" "$breach_log_file"
printf "\033[37m   HTML report : %s\033[0m\n" "$final_report"
printf "\033[37m   Config      : %s\033[0m\n" "$CM_CONFIG_PATH"
echo ""

# Ask to open HTML report
printf '\033[?25h'
if prompt_yesno " Open HTML report in browser?" "Y"; then
    open "$final_report" 2>/dev/null || true
fi

printf '\033[?25h'
echo ""
printf "\033[36m Monitor stopped.\033[0m\n"
