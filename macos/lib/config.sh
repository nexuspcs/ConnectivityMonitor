#!/bin/bash
# ============================================================================
#  CONFIG MODULE - Configuration save/load, prompt helpers, directory setup
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# ================================================================
#  DIRECTORY SETUP
# ================================================================
ensure_dirs() {
    mkdir -p "$CM_BASE_DIR" "$CM_LOGS_DIR" "$CM_REPORTS_DIR"
}

# ================================================================
#  DAILY LOG FILE PATHS
# ================================================================
get_daily_log_paths() {
    current_date=$(date +%Y-%m-%d)
    ping_log_file="$CM_LOGS_DIR/ping_log_${current_date}.csv"
    drop_log_file="$CM_LOGS_DIR/drops_${current_date}.csv"
    breach_log_file="$CM_LOGS_DIR/breaches_${current_date}.csv"
}

check_date_roll() {
    local today
    today=$(date +%Y-%m-%d)
    if [[ "$today" != "$current_date" ]]; then
        get_daily_log_paths
    fi
}

# ================================================================
#  CONFIG FILE (JSON via python3)
# ================================================================
load_config() {
    if [[ -f "$CM_CONFIG_PATH" ]]; then
        if python3 -c "import json; json.load(open('$CM_CONFIG_PATH'))" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

config_get() {
    local key="$1"
    python3 -c "import json; d=json.load(open('${CM_CONFIG_PATH}')); print(d.get('${key}',''))" 2>/dev/null
}

save_config() {
    local cfg_adapter="$1" cfg_poll="$2" cfg_threshold="$3" cfg_targets="$4"
    local cfg_latwarn="$5" cfg_enabledns="$6" cfg_dnstarget="$7" cfg_enablebeep="$8"
    python3 -c "
import json
d = {
    'adapter': '${cfg_adapter}',
    'poll': ${cfg_poll},
    'threshold': ${cfg_threshold},
    'targets': '${cfg_targets}',
    'latWarn': ${cfg_latwarn},
    'enableDns': bool(${cfg_enabledns}),
    'dnsTarget': '${cfg_dnstarget}',
    'enableBeep': bool(${cfg_enablebeep})
}
with open('${CM_CONFIG_PATH}', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
}

# ================================================================
#  PROMPT HELPERS
# ================================================================
prompt_default() {
    local prompt="$1"
    local default="$2"
    local val
    printf '\033[?25h'
    read -rp "$prompt [$default] " val
    printf '\033[?25l'
    if [[ -z "$val" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

prompt_yesno() {
    local prompt="$1"
    local default="$2"
    local val
    printf '\033[?25h'
    read -rp "$prompt [$default] " val
    printf '\033[?25l'
    if [[ -z "$val" ]]; then
        val="$default"
    fi
    case "$val" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ================================================================
#  ADAPTER SELECTION (macOS)
# ================================================================
select_adapter() {
    echo ""
    printf '\033[36m+================================================+\033[0m\n'
    printf '\033[36m|       CONNECTIVITY MONITOR v4.0 (macOS)         |\033[0m\n'
    printf '\033[36m+================================================+\033[0m\n'
    echo ""
    printf '\033[33m Network Interfaces Detected:\033[0m\n'
    echo ""

    local -a iface_names=()
    local -a iface_ports=()
    local i=1

    while IFS= read -r line; do
        if [[ "$line" == "Hardware Port:"* ]]; then
            local port="${line#Hardware Port: }"
            local dev=""
            read -r devline
            if [[ "$devline" == "Device:"* ]]; then
                dev="${devline#Device: }"
            fi
            if [[ -n "$dev" ]]; then
                local status="Down"
                if ifconfig "$dev" 2>/dev/null | grep -q "status: active"; then
                    status="Up"
                elif ifconfig "$dev" 2>/dev/null | grep -q "inet "; then
                    status="Up"
                fi
                local color="\033[31m"
                if [[ "$status" == "Up" ]]; then
                    color="\033[32m"
                fi
                printf "${color}  %d) %-25s (%s) %s\033[0m\n" "$i" "$dev" "$port" "$status"
                iface_names+=("$dev")
                iface_ports+=("$port")
                i=$((i + 1))
            fi
        fi
    done < <(networksetup -listallhardwareports 2>/dev/null)

    # Fallback: use ifconfig to list interfaces
    if [[ ${#iface_names[@]} -eq 0 ]]; then
        for iface in $(ifconfig -l 2>/dev/null); do
            if [[ "$iface" == lo* ]]; then continue; fi
            local status="Down"
            if ifconfig "$iface" 2>/dev/null | grep -q "inet "; then
                status="Up"
            fi
            local color="\033[31m"
            if [[ "$status" == "Up" ]]; then
                color="\033[32m"
            fi
            printf "${color}  %d) %-25s %s\033[0m\n" "$i" "$iface" "$status"
            iface_names+=("$iface")
            iface_ports+=("$iface")
            i=$((i + 1))
        done
    fi

    echo ""
    printf '\033[?25h'
    read -rp " Select adapter number: " n
    printf '\033[?25l'

    if [[ -z "$n" ]] || [[ "$n" -lt 1 ]] || [[ "$n" -gt ${#iface_names[@]} ]]; then
        n=1
    fi
    adapter_name="${iface_names[$((n - 1))]}"

    # Check adapter status
    if ifconfig "$adapter_name" 2>/dev/null | grep -q "status: active"; then
        adapter_status="Up"
    elif ifconfig "$adapter_name" 2>/dev/null | grep -q "inet "; then
        adapter_status="Up"
    else
        adapter_status="Down"
    fi
}
