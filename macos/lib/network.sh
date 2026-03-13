#!/bin/bash
# ============================================================================
#  NETWORK MODULE - Ping, DNS, gateway, public IP, WiFi, traceroute
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# ================================================================
#  PING TEST
#  Returns via global: _ping_ok, _ping_lat
# ================================================================
ping_test() {
    local target="$1"
    _ping_ok=0
    _ping_lat=""

    local output
    output=$(ping -c 1 -W 2 "$target" 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        local lat
        lat=$(echo "$output" | grep -oE 'time=[0-9]+\.?[0-9]*' | head -1 | cut -d= -f2)
        if [[ -n "$lat" ]]; then
            _ping_ok=1
            _ping_lat="$lat"
        fi
    fi
}

# ================================================================
#  DNS TEST
#  Returns via global: _dns_ok, _dns_ms
# ================================================================
dns_test() {
    local hostname="$1"
    _dns_ok=0
    _dns_ms=""

    local start_ms end_ms
    start_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)
    if host "$hostname" >/dev/null 2>&1; then
        end_ms=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)
        _dns_ok=1
        _dns_ms=$(( end_ms - start_ms ))
    fi
}

# ================================================================
#  GATEWAY DETECTION
# ================================================================
detect_gateway() {
    local gw
    gw=$(route -n get default 2>/dev/null | grep gateway | awk '{print $2}')
    if [[ -z "$gw" ]]; then
        gw=$(netstat -rn 2>/dev/null | grep '^default' | head -1 | awk '{print $2}')
    fi
    if [[ -z "$gw" ]]; then
        echo "N/A"
    else
        echo "$gw"
    fi
}

# ================================================================
#  LOCAL IP
# ================================================================
get_local_ip() {
    local iface="$1"
    local ip
    ip=$(ifconfig "$iface" 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
    if [[ -z "$ip" ]]; then
        echo "N/A"
    else
        echo "$ip"
    fi
}

# ================================================================
#  PUBLIC IP DETECTION
# ================================================================
detect_public_ip() {
    local resp
    resp=$(curl -s --connect-timeout 5 --max-time 8 "http://ip-api.com/json" 2>/dev/null)
    if [[ -n "$resp" ]]; then
        public_ip=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('query','N/A'))" 2>/dev/null)
        isp_name=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('isp','N/A'))" 2>/dev/null)
        if [[ -z "$public_ip" ]]; then public_ip="N/A"; fi
        if [[ -z "$isp_name" ]]; then isp_name="N/A"; fi
    else
        public_ip="N/A"
        isp_name="N/A"
    fi
}

# ================================================================
#  WIFI SIGNAL (macOS)
# ================================================================
get_wifi_signal() {
    last_wifi_sig=""
    local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
    if [[ -x "$airport" ]]; then
        local rssi
        rssi=$("$airport" -I 2>/dev/null | grep ' agrCtlRSSI:' | awk '{print $2}')
        if [[ -n "$rssi" ]]; then
            # Convert RSSI to percentage: 2*(rssi+100), clamped 0-100
            local pct=$(( 2 * (rssi + 100) ))
            if [[ $pct -lt 0 ]]; then pct=0; fi
            if [[ $pct -gt 100 ]]; then pct=100; fi
            last_wifi_sig="$pct"
        fi
    fi
}

# ================================================================
#  TRACEROUTE (background)
# ================================================================
start_traceroute() {
    local target="$1"
    # Don't start if one is already running
    if [[ -n "$trace_pid" ]]; then
        if ps -p "$trace_pid" >/dev/null 2>&1; then
            return
        fi
    fi
    # Rate limit: once per 60 seconds
    local now
    now=$(date +%s)
    if [[ $(( now - last_trace_time )) -lt 60 ]]; then
        return
    fi
    last_trace_time=$now
    trace_target="$target"
    traceroute -n -w 1 -m 10 "$target" > "$trace_outfile" 2>&1 &
    trace_pid=$!
}

collect_traceroute() {
    if [[ -z "$trace_pid" ]]; then return; fi
    if ps -p "$trace_pid" >/dev/null 2>&1; then return; fi

    # Job completed - parse results
    wait "$trace_pid" 2>/dev/null
    trace_pid=""

    if [[ -f "$trace_outfile" ]]; then
        local hops=""
        while IFS= read -r line; do
            # Parse traceroute output lines like "1  192.168.1.1  1.234 ms"
            local hop_num hop_ip hop_lat
            hop_num=$(echo "$line" | awk '{print $1}')
            if [[ "$hop_num" =~ ^[0-9]+$ ]]; then
                hop_ip=$(echo "$line" | awk '{print $2}')
                hop_lat=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+ ms' | head -1)
                if [[ -z "$hop_lat" ]]; then hop_lat="*"; fi
                if [[ -z "$hop_ip" ]] || [[ "$hop_ip" == "*" ]]; then
                    hop_ip="*"
                fi
                hops="${hops}${hop_num}:${hop_ip}:${hop_lat};"
            fi
        done < "$trace_outfile"

        local ttime
        ttime=$(date "+%Y-%m-%d %H:%M:%S")
        trace_entries+=("${trace_target}|${ttime}|${hops}")
        # Keep only last 3
        while [[ ${#trace_entries[@]} -gt 3 ]]; do
            trace_entries=("${trace_entries[@]:1}")
        done
        rm -f "$trace_outfile"
    fi
}

# ================================================================
#  ADAPTER STATUS CHECK
# ================================================================
check_adapter_status() {
    if ifconfig "$adapter_name" 2>/dev/null | grep -q "status: active"; then
        adapter_status="Up"
    elif ifconfig "$adapter_name" 2>/dev/null | grep -q "inet "; then
        adapter_status="Up"
    else
        adapter_status="Down"
    fi
}
