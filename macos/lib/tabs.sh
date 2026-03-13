#!/bin/bash
# ============================================================================
#  TABS MODULE - Tab bar, all 5 tab builders, frame renderer
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# Frame is built as parallel arrays: _frame_texts[] and _frame_colors[]
# Multi-segment lines use _frame_segs_* arrays

# ================================================================
#  RENDERER (flicker-free with ANSI cursor home)
# ================================================================
render_frame() {
    local console_width="${1:-120}"
    local output=""

    # Move cursor to top-left without clearing
    output+="\033[H"

    local i
    for ((i = 0; i < ${#_frame_texts[@]}; i++)); do
        local text="${_frame_texts[$i]}"
        local color="${_frame_colors[$i]}"
        local text_len=${#text}
        local pad=$((console_width - text_len))
        if [[ $pad -lt 0 ]]; then
            text="${text:0:$console_width}"
            pad=0
        fi
        output+="\033[${color}m${text}$(printf '%*s' $pad '')\033[0m\n"
    done

    local current_count=${#_frame_texts[@]}
    if [[ $last_line_count -gt $current_count ]]; then
        local blank
        blank=$(printf '%*s' "$console_width" '')
        local j
        for ((j = 0; j < $((last_line_count - current_count)); j++)); do
            output+="${blank}\n"
        done
    fi
    last_line_count=$current_count

    printf "$output"
}

# ================================================================
#  ADD FRAME LINE HELPER
# ================================================================
_add_frame() {
    local text="$1"
    local color="$2"
    _frame_texts+=("$text")
    _frame_colors+=("$color")
}

# ================================================================
#  TAB BAR
# ================================================================
build_tab_bar() {
    local tab_names=("Overview" "Graph" "Drops" "Targets" "Heatmap")
    local bar="  "
    local t
    for ((t = 0; t < 5; t++)); do
        local num=$((t + 1))
        if [[ $num -eq $active_tab ]]; then
            bar+="[${num}:${tab_names[$t]}]  "
        else
            bar+=" ${num}:${tab_names[$t]}   "
        fi
    done
    echo "$bar"
}

# ================================================================
#  TAB 1: OVERVIEW (DUAL-PANE)
# ================================================================
build_tab1() {
    local gw="$1" local_ip="$2" target="$3"
    local ping_ok="$4" ping_lat="$5"
    local gw_ok="$6" gw_lat="$7"
    local dns_ok="$8" dns_ms="$9"
    local lat_warn="${10}" enable_dns="${11}" console_width="${12}"

    local left_width=$(( console_width * 52 / 100 ))
    if [[ $left_width -lt 40 ]]; then left_width=40; fi
    local right_width=$(( console_width - left_width - 3 ))
    if [[ $right_width -lt 10 ]]; then right_width=10; fi

    # Build left pane lines
    local -a left_texts=()
    local -a left_colors=()

    _add_left() {
        local text="$1"
        local color="$2"
        if [[ ${#text} -gt $left_width ]]; then
            text="${text:0:$left_width}"
        fi
        left_texts+=("$text")
        left_colors+=("$color")
    }

    local loss avg jitter min_lat max_lat p95 uptime_pct
    loss=$(calc_loss)
    avg=$(calc_avg)
    jitter=$(calc_jitter)
    min_lat=$(calc_min)
    max_lat=$(calc_max)
    p95=$(calc_percentile 95)
    uptime_pct=$(calc_uptime)
    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - session_start))
    local elapsed_str
    elapsed_str=$(format_duration $elapsed)
    get_trend
    get_health_score
    get_network_weather

    # Header
    local header_time
    header_time=$(date "+%Y-%m-%d %H:%M:%S")
    _add_left "+-- CONNECTIVITY MONITOR v4.0 -- ${header_time} --+" "36"

    # ASCII art
    if [[ $ping_ok -eq 1 ]]; then
        get_online_art
        for al in "${_art_lines[@]}"; do _add_left "  $al" "32"; done
    else
        get_offline_art
        for al in "${_art_lines[@]}"; do _add_left "  $al" "31"; done
    fi

    # Sparkline
    build_sparkline
    if [[ -n "$_sparkline" ]]; then
        _add_left "  Spark: $_sparkline" "36"
    fi

    # Uptime timeline
    build_uptime_timeline 60
    if [[ -n "$_timeline" ]]; then
        _add_left "  Up:    $_timeline" "90"
    fi
    _add_left "" "37"

    # Connection info
    _add_left "  Adapter  : $adapter_name" "37"
    _add_left "  Local IP : $local_ip" "37"
    _add_left "  Gateway  : $gw" "37"
    _add_left "  Public   : $public_ip  ($isp_name)" "37"
    _add_left "  Target   : $target" "33"
    _add_left "  Session  : $elapsed_str" "37"

    if [[ -n "$last_wifi_sig" ]]; then
        local wifi_color="32"
        if [[ $last_wifi_sig -lt 40 ]]; then wifi_color="31"
        elif [[ $last_wifi_sig -lt 70 ]]; then wifi_color="33"
        fi
        _add_left "  WiFi     : ${last_wifi_sig}%" "$wifi_color"
    fi

    if [[ $baseline_locked -eq 1 ]]; then
        _add_left "  Baseline : ${baseline_latency} ms (learned)" "36"
    else
        local remaining=$((30 - ${#baseline_samples[@]}))
        _add_left "  Baseline : learning... ($remaining more)" "90"
    fi
    _add_left "" "37"

    # Status panel
    _add_left "  +--- Status ----------------------------+" "90"

    local link_str="[DOWN]"
    if [[ "$adapter_status" == "Up" ]]; then link_str="[UP]  "; fi
    local inet="DOWN"
    if [[ "$adapter_status" == "Up" ]]; then
        if [[ $ping_ok -eq 1 ]]; then inet="OK"; else inet="FAIL"; fi
    fi

    local gw_str=""
    if [[ $gw_ok -eq 1 ]]; then
        gw_str="  GW:OK(${gw_lat}ms)"
    elif [[ -n "$gw" ]] && [[ "$gw" != "N/A" ]] && [[ "$gw" != "None" ]]; then
        gw_str="  GW:FAIL"
    fi

    local dns_str=""
    if [[ $enable_dns -eq 1 ]]; then
        if [[ $dns_ok -eq 1 ]]; then
            dns_str="  DNS:OK(${dns_ms}ms)"
        else
            dns_str="  DNS:FAIL"
        fi
    fi

    local status_color="32"
    if [[ "$adapter_status" != "Up" ]] || [[ $ping_ok -ne 1 ]]; then status_color="31"; fi
    _add_left "  |  Link:${link_str} Net:${inet}${gw_str}${dns_str}" "$status_color"

    # Current latency
    local lat_str="--"
    local lc="31"
    if [[ -n "$ping_lat" ]]; then
        lat_str="${ping_lat} ms"
        if awk "BEGIN {exit !($ping_lat >= $lat_warn)}"; then
            lat_str+=" !! HIGH"
        fi
        lc=$(latency_color "$ping_lat")
    fi
    _add_left "  |  Latency: $lat_str" "$lc"
    _add_left "  +---------------------------------------+" "90"
    _add_left "" "37"

    # Network weather
    _add_left "  Weather: $_weather_label" "$_weather_color"
    _add_left "    $_weather_icon1" "$_weather_color"
    _add_left "    $_weather_icon2" "$_weather_color"
    _add_left "    $_weather_icon3" "$_weather_color"
    _add_left "" "37"

    # Health score
    _add_left "  Health: ${_health_score}/100  Grade: $_health_grade  Trend: $_trend_arrow $_trend_label" "$_health_color"

    # Diagnosis
    _add_left "  Diagnosis: $last_diagnosis_msg" "$last_diagnosis_color"

    if [[ $paused -eq 1 ]]; then
        _add_left "  ** PAUSED ** (press P to resume)" "33"
    fi
    _add_left "" "37"

    # Stats
    _add_left "  +--- Stats -----------------------------+" "90"
    _add_left "  |  Loss   : ${loss}%" "$(loss_color "$loss")"
    _add_left "  |  Avg    : ${avg} ms" "37"
    _add_left "  |  Min    : ${min_lat} ms" "32"
    _add_left "  |  Max    : ${max_lat} ms" "31"
    _add_left "  |  P95    : ${p95} ms" "33"
    _add_left "  |  Jitter : ${jitter} ms" "37"
    _add_left "  |  Uptime : ${uptime_pct}%" "37"
    _add_left "  +---------------------------------------+" "90"

    # === BUILD RIGHT PANE ===
    local -a right_texts=()
    local -a right_colors=()

    _add_right() {
        local text="$1"
        local color="$2"
        if [[ ${#text} -gt $right_width ]]; then
            text="${text:0:$right_width}"
        fi
        right_texts+=("$text")
        right_colors+=("$color")
    }

    # Compact latency graph
    build_latency_graph 28 6
    for gl in "${_graph_lines[@]}"; do
        _add_right "$gl" "$(graph_line_color "$gl")"
    done
    _add_right "" "37"

    # Compact histogram
    build_histogram
    for hl in "${_hist_lines[@]}"; do
        _add_right "$hl" "36"
    done
    _add_right "" "37"

    # Recent drops (last 8)
    _add_right " Recent Drops:" "33"
    if [[ ${#drop_starts[@]} -eq 0 ]]; then
        _add_right "   (none)" "90"
    else
        local start_idx=$((${#drop_starts[@]} > 8 ? ${#drop_starts[@]} - 8 : 0))
        local d
        for ((d = start_idx; d < ${#drop_starts[@]}; d++)); do
            local drop_time="${drop_starts[$d]}"
            if [[ ${#drop_time} -gt 19 ]]; then
                drop_time="${drop_time:11:8}"
            fi
            local dur="${drop_durations[$d]}"
            local diag="${drop_diagnoses[$d]}"
            local d_color="37"
            if awk "BEGIN {exit !($dur >= 30)}"; then d_color="31"
            elif awk "BEGIN {exit !($dur >= 10)}"; then d_color="33"
            fi
            _add_right "  ${drop_time} ${dur}s ${diag}" "$d_color"
        done
    fi
    _add_right "" "37"

    # Per-target health
    _add_right " Per-Target:" "35"
    for t in "${!per_target_sent[@]}"; do
        local info_sent="${per_target_sent[$t]}"
        local info_ok="${per_target_ok[$t]:-0}"
        local t_loss=0
        if [[ $info_sent -gt 0 ]]; then
            t_loss=$(awk "BEGIN {printf \"%.1f\", (1 - $info_ok/$info_sent) * 100}")
        fi
        local t_avg=0
        local lats_str="${per_target_lats[$t]:-}"
        if [[ -n "$lats_str" ]]; then
            t_avg=$(echo "$lats_str" | tr ',' '\n' | awk '{s+=$1; n++} END {if(n>0) printf "%.1f", s/n; else print "0"}')
        fi
        local t_color="37"
        if awk "BEGIN {exit !($t_loss > 0)}"; then t_color="33"; fi
        if awk "BEGIN {exit !($t_loss >= 5)}"; then t_color="31"; fi
        local short_t="$t"
        if [[ ${#short_t} -gt 15 ]]; then short_t="${short_t:0:15}"; fi
        printf -v tline "  %-15s L:%s%% A:%sms" "$short_t" "$t_loss" "$t_avg"
        _add_right "$tline" "$t_color"
    done

    # === MERGE DUAL PANE ===
    local max_lines=${#left_texts[@]}
    if [[ ${#right_texts[@]} -gt $max_lines ]]; then
        max_lines=${#right_texts[@]}
    fi

    local sep=" | "
    for ((i = 0; i < max_lines; i++)); do
        local l_text=""
        local l_color="37"
        if [[ $i -lt ${#left_texts[@]} ]]; then
            l_text="${left_texts[$i]}"
            l_color="${left_colors[$i]}"
        fi
        # Pad left to exact width
        local l_len=${#l_text}
        if [[ $l_len -gt $left_width ]]; then
            l_text="${l_text:0:$left_width}"
        elif [[ $l_len -lt $left_width ]]; then
            l_text+=$(printf '%*s' $((left_width - l_len)) '')
        fi

        local r_text=""
        local r_color="37"
        if [[ $i -lt ${#right_texts[@]} ]]; then
            r_text="${right_texts[$i]}"
            r_color="${right_colors[$i]}"
        fi
        if [[ ${#r_text} -gt $right_width ]]; then
            r_text="${r_text:0:$right_width}"
        fi

        # Combine: left + separator + right (use left color for whole line for simplicity)
        _add_frame "${l_text}${sep}${r_text}" "$l_color"
    done

    unset -f _add_left
    unset -f _add_right
}

# ================================================================
#  TAB 2: FULL GRAPH
# ================================================================
build_tab2() {
    local console_width="${1:-120}"

    _add_frame "" "37"
    _add_frame "  === FULL LATENCY GRAPH ===" "36"
    _add_frame "" "37"

    local graph_w=$((console_width - 20))
    if [[ $graph_w -gt 100 ]]; then graph_w=100; fi
    if [[ $graph_w -lt 20 ]]; then graph_w=20; fi

    build_latency_graph $graph_w 12
    for gl in "${_graph_lines[@]}"; do
        _add_frame "$gl" "$(graph_line_color "$gl")"
    done
    _add_frame "" "37"

    # Full uptime timeline (last 100)
    build_uptime_timeline 100
    if [[ -n "$_timeline" ]]; then
        _add_frame "  Uptime:  $_timeline" "90"
        _add_frame "  Legend:  - OK  ~ >50ms  ! >100ms  X drop" "90"
    fi
    _add_frame "" "37"

    # Full histogram
    build_histogram
    for hl in "${_hist_lines[@]}"; do
        _add_frame "$hl" "36"
    done
}

# ================================================================
#  TAB 3: DROPS & TRACEROUTES
# ================================================================
build_tab3() {
    _add_frame "" "37"
    _add_frame "  === DROP HISTORY ===" "33"
    _add_frame "" "37"

    if [[ ${#drop_starts[@]} -eq 0 ]]; then
        _add_frame "    (no drops recorded)" "90"
    else
        printf -v hdr "    %-22s %-22s %-10s %-18s %s" "Start" "End" "Duration" "Target" "Diagnosis"
        _add_frame "$hdr" "33"
        printf -v sep "    %s %s %s %s %s" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..18})" "$(printf '%0.s-' {1..20})"
        _add_frame "$sep" "90"

        local start_idx=$((${#drop_starts[@]} > 20 ? ${#drop_starts[@]} - 20 : 0))
        local d
        for ((d = start_idx; d < ${#drop_starts[@]}; d++)); do
            local dur="${drop_durations[$d]}"
            local d_color="37"
            if awk "BEGIN {exit !($dur >= 30)}"; then d_color="31"
            elif awk "BEGIN {exit !($dur >= 10)}"; then d_color="33"
            fi
            printf -v line "    %-22s %-22s %-10s %-18s %s" "${drop_starts[$d]}" "${drop_ends[$d]}" "${dur}s" "${drop_targets[$d]}" "${drop_diagnoses[$d]}"
            _add_frame "$line" "$d_color"
        done
    fi

    _add_frame "" "37"
    _add_frame "  === HIGH LATENCY BREACHES ===" "33"
    _add_frame "" "37"

    if [[ ${#breach_starts[@]} -eq 0 ]]; then
        _add_frame "    (no breaches recorded)" "90"
    else
        printf -v hdr "    %-22s %-22s %-10s %s" "Start" "End" "Duration" "Avg Latency"
        _add_frame "$hdr" "33"
        printf -v sep "    %s %s %s %s" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..22})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..12})"
        _add_frame "$sep" "90"

        local start_idx=$((${#breach_starts[@]} > 15 ? ${#breach_starts[@]} - 15 : 0))
        local b
        for ((b = start_idx; b < ${#breach_starts[@]}; b++)); do
            printf -v line "    %-22s %-22s %-10s %sms" "${breach_starts[$b]}" "${breach_ends[$b]}" "${breach_durations[$b]}s" "${breach_avglats[$b]}"
            _add_frame "$line" "33"
        done
    fi

    _add_frame "" "37"
    _add_frame "  === TRACEROUTE RESULTS (last 3) ===" "36"
    _add_frame "" "37"

    if [[ ${#trace_entries[@]} -eq 0 ]]; then
        _add_frame "    (no traceroutes recorded yet)" "90"
        _add_frame "    Traceroutes run automatically on outages." "90"
    else
        for tr_entry in "${trace_entries[@]}"; do
            local tr_target tr_time tr_hops
            tr_target=$(echo "$tr_entry" | cut -d'|' -f1)
            tr_time=$(echo "$tr_entry" | cut -d'|' -f2)
            tr_hops=$(echo "$tr_entry" | cut -d'|' -f3)
            _add_frame "    Target: $tr_target  Time: $tr_time" "36"

            if [[ -z "$tr_hops" ]]; then
                _add_frame "      (no hops captured)" "90"
            else
                printf -v hop_hdr "      %-5s %-18s %s" "Hop" "IP" "Latency"
                _add_frame "$hop_hdr" "36"
                IFS=';' read -ra hop_arr <<< "$tr_hops"
                for hop in "${hop_arr[@]}"; do
                    if [[ -z "$hop" ]]; then continue; fi
                    local hop_num hop_ip hop_lat
                    hop_num=$(echo "$hop" | cut -d: -f1)
                    hop_ip=$(echo "$hop" | cut -d: -f2)
                    hop_lat=$(echo "$hop" | cut -d: -f3)
                    printf -v hop_line "      %-5s %-18s %s" "$hop_num" "$hop_ip" "$hop_lat"
                    _add_frame "$hop_line" "37"
                done
            fi
            _add_frame "" "37"
        done
    fi
}

# ================================================================
#  TAB 4: PER-TARGET DETAIL
# ================================================================
build_tab4() {
    _add_frame "" "37"
    _add_frame "  === PER-TARGET DETAIL ===" "35"
    _add_frame "" "37"

    if [[ ${#per_target_sent[@]} -eq 0 ]]; then
        _add_frame "    (no target data yet)" "90"
    else
        printf -v hdr "    %-20s %6s %6s %7s %8s %8s %8s %8s" "Target" "Sent" "OK" "Loss%" "Avg" "Min" "Max" "P95"
        _add_frame "$hdr" "36"
        printf -v sep "    %s %s %s %s %s %s %s %s" "$(printf '%0.s-' {1..20})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..7})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..8})"
        _add_frame "$sep" "90"

        for t in "${!per_target_sent[@]}"; do
            local info_sent="${per_target_sent[$t]}"
            local info_ok="${per_target_ok[$t]:-0}"
            local t_loss=0
            if [[ $info_sent -gt 0 ]]; then
                t_loss=$(awk "BEGIN {printf \"%.1f\", (1 - $info_ok/$info_sent) * 100}")
            fi
            local t_avg=0 t_min=0 t_max=0 t_p95=0
            local lats_str="${per_target_lats[$t]:-}"
            if [[ -n "$lats_str" ]]; then
                local stats
                stats=$(echo "$lats_str" | tr ',' '\n' | awk '
                    BEGIN {min=999999; max=0; s=0; n=0}
                    {s+=$1; n++; if($1<min) min=$1; if($1>max) max=$1; vals[n]=$1}
                    END {
                        printf "%.1f %.1f %.1f", s/n, min, max
                        # Sort for P95
                        asort(vals)
                        idx = int(n * 0.95)
                        if (idx >= n) idx = n
                        if (idx < 1) idx = 1
                        printf " %.1f", vals[idx]
                    }
                ')
                t_avg=$(echo "$stats" | awk '{print $1}')
                t_min=$(echo "$stats" | awk '{print $2}')
                t_max=$(echo "$stats" | awk '{print $3}')
                t_p95=$(echo "$stats" | awk '{print $4}')
            fi
            local t_color="37"
            if awk "BEGIN {exit !($t_loss > 0)}"; then t_color="33"; fi
            if awk "BEGIN {exit !($t_loss >= 5)}"; then t_color="31"; fi
            printf -v line "    %-20s %6d %6d %6.1f%% %7sms %7sms %7sms %7sms" "$t" "$info_sent" "$info_ok" "$t_loss" "$t_avg" "$t_min" "$t_max" "$t_p95"
            _add_frame "$line" "$t_color"
        done
    fi

    _add_frame "" "37"
    _add_frame "  === GATEWAY LATENCY ===" "36"
    _add_frame "" "37"

    # Gateway stats from gw_lats array
    local gw_valid=()
    for g in "${gw_lats[@]}"; do
        if [[ -n "$g" ]]; then gw_valid+=("$g"); fi
    done

    if [[ ${#gw_valid[@]} -eq 0 ]]; then
        _add_frame "    (no gateway data yet)" "90"
    else
        local gw_stats
        gw_stats=$(printf '%s\n' "${gw_valid[@]}" | awk '
            BEGIN {min=999999; max=0; s=0; n=0}
            {s+=$1; n++; if($1<min) min=$1; if($1>max) max=$1}
            END {printf "%d %.1f %.1f %.1f", n, s/n, min, max}
        ')
        local gw_count gw_avg gw_min gw_max
        gw_count=$(echo "$gw_stats" | awk '{print $1}')
        gw_avg=$(echo "$gw_stats" | awk '{print $2}')
        gw_min=$(echo "$gw_stats" | awk '{print $3}')
        gw_max=$(echo "$gw_stats" | awk '{print $4}')
        _add_frame "    Samples: $gw_count    Avg: ${gw_avg}ms    Min: ${gw_min}ms    Max: ${gw_max}ms" "37"
    fi
}

# ================================================================
#  TAB 5: TIME-OF-DAY HEATMAP
# ================================================================
build_tab5() {
    _add_frame "" "37"
    _add_frame "  === TIME-OF-DAY HEATMAP ===" "32"
    _add_frame "" "37"

    build_heatmap
    for hml in "${_heatmap_lines[@]}"; do
        _add_frame "$hml" "37"
    done
}

# ================================================================
#  MASTER FRAME BUILDER
# ================================================================
build_frame() {
    local gw="$1" local_ip="$2" target="$3"
    local ping_ok="$4" ping_lat="$5"
    local gw_ok="$6" gw_lat="$7"
    local dns_ok="$8" dns_ms="$9"
    local lat_warn="${10}" enable_dns="${11}"

    local console_width
    console_width=$(tput cols 2>/dev/null || echo 120)
    if [[ $console_width -lt 60 ]]; then console_width=60; fi

    _frame_texts=()
    _frame_colors=()

    # Tab bar
    local tab_bar
    tab_bar=$(build_tab_bar)
    _add_frame "$tab_bar" "36"
    local sep_len=$((console_width - 4))
    local sep_line="  "
    local s
    for ((s = 0; s < sep_len; s++)); do sep_line+="="; done
    _add_frame "$sep_line" "90"

    case $active_tab in
        1)
            build_tab1 "$gw" "$local_ip" "$target" "$ping_ok" "$ping_lat" \
                "$gw_ok" "$gw_lat" "$dns_ok" "$dns_ms" "$lat_warn" "$enable_dns" "$console_width"
            ;;
        2)
            build_tab2 "$console_width"
            ;;
        3)
            build_tab3
            ;;
        4)
            build_tab4
            ;;
        5)
            build_tab5
            ;;
    esac

    # Footer
    _add_frame "" "37"
    _add_frame "  [1-5] Tab  [P]ause  [R]eset  [E]xport  [Q]uit  |  Ctrl+C stop" "90"

    render_frame "$console_width"
}
