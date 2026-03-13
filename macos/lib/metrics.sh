#!/bin/bash
# ============================================================================
#  METRICS MODULE - Statistics, health score, trend, diagnosis
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# ================================================================
#  UPDATE HISTORY
# ================================================================
update_history() {
    local lat="$1"
    local target="$2"
    local now
    now=$(date "+%Y-%m-%d %H:%M:%S")

    hist_times+=("$now")
    hist_lats+=("$lat")
    hist_targets+=("$target")
    total_pings=$((total_pings + 1))
    if [[ -n "$lat" ]]; then
        total_success=$((total_success + 1))
    fi

    # Trim history to max
    while [[ ${#hist_lats[@]} -gt $max_history ]]; do
        hist_times=("${hist_times[@]:1}")
        hist_lats=("${hist_lats[@]:1}")
        hist_targets=("${hist_targets[@]:1}")
    done

    # Per-target stats
    local prev_sent="${per_target_sent[$target]:-0}"
    per_target_sent[$target]=$((prev_sent + 1))
    if [[ -n "$lat" ]]; then
        local prev_ok="${per_target_ok[$target]:-0}"
        per_target_ok[$target]=$((prev_ok + 1))
        local prev_lats="${per_target_lats[$target]:-}"
        if [[ -n "$prev_lats" ]]; then
            per_target_lats[$target]="${prev_lats},${lat}"
        else
            per_target_lats[$target]="$lat"
        fi
    fi

    # Baseline learning (first 30 successful pings)
    if [[ $baseline_locked -eq 0 ]] && [[ -n "$lat" ]]; then
        baseline_samples+=("$lat")
        if [[ ${#baseline_samples[@]} -ge 30 ]]; then
            baseline_latency=$(printf '%s\n' "${baseline_samples[@]}" | awk '{s+=$1} END {printf "%.1f", s/NR}')
            baseline_locked=1
        fi
    fi
}

update_gw_history() {
    local lat="$1"
    gw_lats+=("$lat")
    while [[ ${#gw_lats[@]} -gt 200 ]]; do
        gw_lats=("${gw_lats[@]:1}")
    done
}

update_hourly_data() {
    local lat="$1"
    if [[ -z "$lat" ]]; then return; fi
    local hour
    hour=$(date +%H | sed 's/^0//')
    local prev="${hourly_data[$hour]:-}"
    if [[ -n "$prev" ]]; then
        hourly_data[$hour]="${prev},${lat}"
    else
        hourly_data[$hour]="$lat"
    fi
}

# ================================================================
#  STATISTICAL FUNCTIONS (use awk for float math)
# ================================================================

# Get valid latency values from history as newline-separated
_get_valid_lats() {
    local i
    for i in "${!hist_lats[@]}"; do
        if [[ -n "${hist_lats[$i]}" ]]; then
            echo "${hist_lats[$i]}"
        fi
    done
}

calc_loss() {
    local total=${#hist_lats[@]}
    if [[ $total -eq 0 ]]; then echo "0"; return; fi
    local lost=0
    local i
    for i in "${!hist_lats[@]}"; do
        if [[ -z "${hist_lats[$i]}" ]]; then
            lost=$((lost + 1))
        fi
    done
    awk "BEGIN {printf \"%.1f\", ($lost/$total)*100}"
}

calc_avg() {
    local vals
    vals=$(_get_valid_lats)
    if [[ -z "$vals" ]]; then echo "0"; return; fi
    echo "$vals" | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "0"}'
}

calc_min() {
    local vals
    vals=$(_get_valid_lats)
    if [[ -z "$vals" ]]; then echo "0"; return; fi
    echo "$vals" | awk 'BEGIN{m=999999} {if($1<m) m=$1} END {printf "%.1f", m}'
}

calc_max() {
    local vals
    vals=$(_get_valid_lats)
    if [[ -z "$vals" ]]; then echo "0"; return; fi
    echo "$vals" | awk 'BEGIN{m=0} {if($1>m) m=$1} END {printf "%.1f", m}'
}

calc_percentile() {
    local pct="$1"
    local vals
    vals=$(_get_valid_lats | sort -n)
    if [[ -z "$vals" ]]; then echo "0"; return; fi
    local count
    count=$(echo "$vals" | wc -l | tr -d ' ')
    if [[ $count -eq 0 ]]; then echo "0"; return; fi
    local idx
    idx=$(awk "BEGIN {printf \"%d\", int($count * $pct / 100)}")
    if [[ $idx -ge $count ]]; then idx=$((count - 1)); fi
    echo "$vals" | sed -n "$((idx + 1))p" | awk '{printf "%.1f", $1}'
}

calc_jitter() {
    local vals
    vals=$(_get_valid_lats)
    if [[ -z "$vals" ]]; then echo "0"; return; fi
    local count
    count=$(echo "$vals" | wc -l | tr -d ' ')
    if [[ $count -lt 2 ]]; then echo "0"; return; fi
    echo "$vals" | awk '
    NR==1 {prev=$1; next}
    {
        d = $1 - prev
        if (d < 0) d = -d
        sum += d
        n++
        prev = $1
    }
    END {if(n>0) printf "%.1f", sum/n; else print "0"}'
}

calc_uptime() {
    local total=${#hist_lats[@]}
    if [[ $total -eq 0 ]]; then echo "100.0"; return; fi
    local ok=0
    local i
    for i in "${!hist_lats[@]}"; do
        if [[ -n "${hist_lats[$i]}" ]]; then
            ok=$((ok + 1))
        fi
    done
    awk "BEGIN {printf \"%.2f\", ($ok/$total)*100}"
}

# ================================================================
#  TREND DETECTION
# ================================================================
# Returns via globals: _trend_arrow, _trend_label, _trend_color
get_trend() {
    _trend_arrow="->"
    _trend_label="Collecting"
    _trend_color="90"

    local count=${#hist_lats[@]}
    local start=$((count > 30 ? count - 30 : 0))
    local -a recent=()
    local i
    for ((i = start; i < count; i++)); do
        if [[ -n "${hist_lats[$i]}" ]]; then
            recent+=("${hist_lats[$i]}")
        fi
    done

    if [[ ${#recent[@]} -lt 10 ]]; then return; fi

    local half=$(( ${#recent[@]} / 2 ))
    local avg_first avg_second
    avg_first=$(printf '%s\n' "${recent[@]:0:$half}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
    avg_second=$(printf '%s\n' "${recent[@]:$half}" | awk '{s+=$1} END {printf "%.2f", s/NR}')

    local pct_change
    pct_change=$(awk "BEGIN {
        if ($avg_first > 0) printf \"%.1f\", (($avg_second - $avg_first) / $avg_first) * 100
        else print \"0\"
    }")

    if awk "BEGIN {exit !($pct_change > 20)}"; then
        _trend_arrow="^^"; _trend_label="Degrading"; _trend_color="31"
    elif awk "BEGIN {exit !($pct_change > 8)}"; then
        _trend_arrow="^ "; _trend_label="Rising"; _trend_color="33"
    elif awk "BEGIN {exit !($pct_change < -20)}"; then
        _trend_arrow="vv"; _trend_label="Improving"; _trend_color="32"
    elif awk "BEGIN {exit !($pct_change < -8)}"; then
        _trend_arrow="v "; _trend_label="Falling"; _trend_color="32"
    else
        _trend_arrow="->"; _trend_label="Stable"; _trend_color="36"
    fi
}

# ================================================================
#  HEALTH SCORE
# ================================================================
# Returns via globals: _health_score, _health_grade, _health_color
get_health_score() {
    local loss avg jitter
    loss=$(calc_loss)
    avg=$(calc_avg)
    jitter=$(calc_jitter)

    _health_score=$(awk "BEGIN {
        score = 100
        score -= ($loss * 3)
        if ($avg > 100) score -= 20
        else if ($avg > 50) score -= 10
        else if ($avg > 30) score -= 5
        if ($jitter > 30) score -= 15
        else if ($jitter > 15) score -= 8
        else if ($jitter > 5) score -= 3
        if (score < 0) score = 0
        if (score > 100) score = 100
        printf \"%d\", score
    }")

    if [[ $_health_score -lt 50 ]]; then
        _health_grade="F"; _health_color="31"
    elif [[ $_health_score -lt 60 ]]; then
        _health_grade="D"; _health_color="31"
    elif [[ $_health_score -lt 70 ]]; then
        _health_grade="C"; _health_color="33"
    elif [[ $_health_score -lt 80 ]]; then
        _health_grade="B"; _health_color="33"
    elif [[ $_health_score -lt 90 ]]; then
        _health_grade="A"; _health_color="32"
    else
        _health_grade="A+"; _health_color="32"
    fi
}

# ================================================================
#  DIAGNOSE ISSUE
# ================================================================
# Args: gw_ok(0/1), ext_ok(0/1)
# Returns via globals: last_diagnosis_msg, last_diagnosis_color
diagnose_issue() {
    local gw_ok="$1"
    local ext_ok="$2"

    if [[ $gw_ok -eq 1 ]] && [[ $ext_ok -eq 1 ]]; then
        last_diagnosis_msg="All clear"
        last_diagnosis_color="32"
    elif [[ $gw_ok -eq 0 ]] && [[ $ext_ok -eq 0 ]]; then
        last_diagnosis_msg="Local network down (gateway unreachable)"
        last_diagnosis_color="31"
    elif [[ $gw_ok -eq 1 ]] && [[ $ext_ok -eq 0 ]]; then
        last_diagnosis_msg="ISP / upstream issue (gateway OK, internet down)"
        last_diagnosis_color="33"
    else
        last_diagnosis_msg="Unusual state"
        last_diagnosis_color="33"
    fi
}

# ================================================================
#  NETWORK WEATHER
# ================================================================
# Returns via globals: _weather_label, _weather_icon1/2/3, _weather_color
get_network_weather() {
    get_health_score
    local s=$_health_score

    if [[ $s -gt 90 ]]; then
        _weather_label="SUNNY"
        _weather_icon1=' \  |  / '
        _weather_icon2='  (  .  )  '
        _weather_icon3=' /  |  \ '
        _weather_color="32"
    elif [[ $s -gt 75 ]]; then
        _weather_label="PARTLY CLOUDY"
        _weather_icon1='    .-~~-.  '
        _weather_icon2=' .-(      )-.'
        _weather_icon3='(____________)'
        _weather_color="36"
    elif [[ $s -gt 50 ]]; then
        _weather_label="CLOUDY"
        _weather_icon1='   .------. '
        _weather_icon2=' .(        ).'
        _weather_icon3='(___________)'
        _weather_color="90"
    elif [[ $s -gt 25 ]]; then
        _weather_label="STORMY"
        _weather_icon1='   .------. '
        _weather_icon2=' .(        ).'
        _weather_icon3="(___________) '; ' "
        _weather_color="33"
    else
        _weather_label="HURRICANE"
        _weather_icon1='   .======. '
        _weather_icon2=' .(########).'
        _weather_icon3='(###########) X X X'
        _weather_color="31"
    fi
}

# ================================================================
#  COLOR HELPERS
# ================================================================
latency_color() {
    local ms="$1"
    if [[ -z "$ms" ]]; then echo "31"; return; fi
    if awk "BEGIN {exit !($ms < 30)}"; then echo "32"; return; fi
    if awk "BEGIN {exit !($ms < 80)}"; then echo "33"; return; fi
    echo "31"
}

loss_color() {
    local pct="$1"
    if [[ "$pct" == "0" ]] || [[ "$pct" == "0.0" ]]; then echo "32"; return; fi
    if awk "BEGIN {exit !($pct < 5)}"; then echo "33"; return; fi
    echo "31"
}

format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local mins=$(( (seconds % 3600) / 60 ))
    local secs=$((seconds % 60))
    if [[ $hours -ge 1 ]]; then
        echo "${hours}h ${mins}m ${secs}s"
    elif [[ $mins -ge 1 ]]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}
