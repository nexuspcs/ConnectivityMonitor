#!/bin/bash
# ============================================================================
#  DISPLAY MODULE - Graph builders, sparkline, histogram, heatmap, ASCII art
#  Connectivity Monitor v4.0 (macOS)
# ============================================================================

# All build functions append lines to the _display_buf array
# Caller should: _display_buf=() before calling, then read _display_buf after

# ================================================================
#  ASCII ART
# ================================================================
get_online_art() {
    _art_lines=(
        '  ___        _ _            '
        ' / _ \ _ __ | (_)_ __   ___ '
        '| | | |  _ \| | |  _ \ / _ \'
        '| |_| | | | | | | | | |  __/'
        ' \___/|_| |_|_|_|_| |_|\___|'
    )
}

get_offline_art() {
    _art_lines=(
        '  ___   __  __ _ _            '
        ' / _ \ / _|/ _| (_)_ __   ___ '
        '| | | | |_| |_| | |  _ \ / _ \'
        '| |_| |  _|  _| | | | | |  __/'
        ' \___/|_| |_| |_|_|_| |_|\___|'
    )
}

# ================================================================
#  LATENCY GRAPH
# ================================================================
# Args: width, height
# Populates _graph_lines array
build_latency_graph() {
    local width="$1"
    local height="$2"
    _graph_lines=()

    local count=${#hist_lats[@]}
    local start=$((count > width ? count - width : 0))
    local -a vals=()
    local i
    for ((i = start; i < count; i++)); do
        vals+=("${hist_lats[$i]}")
    done

    if [[ ${#vals[@]} -eq 0 ]]; then return; fi

    # Find max
    local max_val=1
    for v in "${vals[@]}"; do
        if [[ -n "$v" ]]; then
            if awk "BEGIN {exit !($v > $max_val)}"; then
                max_val="$v"
            fi
        fi
    done

    local max_rounded
    max_rounded=$(awk "BEGIN {printf \"%d\", $max_val}")
    _graph_lines+=("  Latency (ms) -- last ${#vals[@]} pings  [max: ${max_rounded}ms]")

    local row
    for ((row = height; row >= 1; row--)); do
        local row_threshold
        row_threshold=$(awk "BEGIN {printf \"%.2f\", ($row / $height) * $max_val}")
        local line=""
        for v in "${vals[@]}"; do
            if [[ -z "$v" ]]; then
                line+="X"
            elif awk "BEGIN {exit !($v >= $row_threshold)}"; then
                if awk "BEGIN {exit !($v < 10)}"; then
                    line+="."
                elif awk "BEGIN {exit !($v < 50)}"; then
                    line+="o"
                elif awk "BEGIN {exit !($v < 100)}"; then
                    line+="O"
                else
                    line+="@"
                fi
            else
                line+=" "
            fi
        done
        local label
        label=$(awk "BEGIN {printf \"%6d\", $row_threshold}")
        _graph_lines+=("${label} |${line}|")
    done

    local bottom_line=""
    for ((i = 0; i < ${#vals[@]}; i++)); do bottom_line+="-"; done
    _graph_lines+=("       +${bottom_line}+")
    _graph_lines+=("       Legend: . <10  o <50  O <100  @ >100  X drop")
}

# ================================================================
#  SPARKLINE
# ================================================================
build_sparkline() {
    _sparkline=""
    local count=${#hist_lats[@]}
    local start=$((count > 50 ? count - 50 : 0))
    local -a vals=()
    local i
    for ((i = start; i < count; i++)); do
        vals+=("${hist_lats[$i]}")
    done
    if [[ ${#vals[@]} -eq 0 ]]; then return; fi

    local chars=("_" "." "-" "~" "^")
    local max_v=1
    for v in "${vals[@]}"; do
        if [[ -n "$v" ]]; then
            if awk "BEGIN {exit !($v > $max_v)}"; then max_v="$v"; fi
        fi
    done

    local spark=""
    for v in "${vals[@]}"; do
        if [[ -z "$v" ]]; then
            spark+="X"
        else
            local idx
            idx=$(awk "BEGIN {i=int(($v / $max_v) * 4); if(i>4) i=4; print i}")
            spark+="${chars[$idx]}"
        fi
    done
    _sparkline="$spark"
}

# ================================================================
#  UPTIME TIMELINE
# ================================================================
build_uptime_timeline() {
    local num="${1:-60}"
    _timeline=""
    local count=${#hist_lats[@]}
    local start=$((count > num ? count - num : 0))
    local bar=""
    local i
    for ((i = start; i < count; i++)); do
        local v="${hist_lats[$i]}"
        if [[ -z "$v" ]]; then
            bar+="X"
        elif awk "BEGIN {exit !($v > 100)}"; then
            bar+="!"
        elif awk "BEGIN {exit !($v > 50)}"; then
            bar+="~"
        else
            bar+="-"
        fi
    done
    _timeline="$bar"
}

# ================================================================
#  HISTOGRAM
# ================================================================
build_histogram() {
    _hist_lines=()
    local -a bucket_names=("  0-10ms" " 10-25ms" " 25-50ms" " 50-100ms" "100-200ms" "  200ms+")
    local -a bucket_counts=(0 0 0 0 0 0)
    local total_vals=0

    local i
    for i in "${!hist_lats[@]}"; do
        local v="${hist_lats[$i]}"
        if [[ -n "$v" ]]; then
            total_vals=$((total_vals + 1))
            if awk "BEGIN {exit !($v < 10)}"; then
                bucket_counts[0]=$((bucket_counts[0] + 1))
            elif awk "BEGIN {exit !($v < 25)}"; then
                bucket_counts[1]=$((bucket_counts[1] + 1))
            elif awk "BEGIN {exit !($v < 50)}"; then
                bucket_counts[2]=$((bucket_counts[2] + 1))
            elif awk "BEGIN {exit !($v < 100)}"; then
                bucket_counts[3]=$((bucket_counts[3] + 1))
            elif awk "BEGIN {exit !($v < 200)}"; then
                bucket_counts[4]=$((bucket_counts[4] + 1))
            else
                bucket_counts[5]=$((bucket_counts[5] + 1))
            fi
        fi
    done

    if [[ $total_vals -lt 5 ]]; then
        _hist_lines+=("  (need more data for histogram)")
        return
    fi

    local max_count=1
    for c in "${bucket_counts[@]}"; do
        if [[ $c -gt $max_count ]]; then max_count=$c; fi
    done

    _hist_lines+=("  Latency Distribution:")
    local b
    for ((b = 0; b < 6; b++)); do
        local count="${bucket_counts[$b]}"
        local bar_len
        bar_len=$(awk "BEGIN {printf \"%d\", ($count / $max_count) * 20}")
        local bar=""
        local j
        for ((j = 0; j < bar_len; j++)); do bar+="="; done
        local pct
        pct=$(awk "BEGIN {printf \"%d\", ($count / $total_vals) * 100}")
        printf -v line "  %s |%-20s %4d (%s%%)" "${bucket_names[$b]}" "$bar" "$count" "$pct"
        _hist_lines+=("$line")
    done
}

# ================================================================
#  HEATMAP
# ================================================================
build_heatmap() {
    _heatmap_lines=()
    _heatmap_lines+=("  Time-of-Day Latency Heatmap (today):")
    _heatmap_lines+=("")

    # Build hour labels
    local hour_labels="  Hour: "
    local h
    for ((h = 0; h < 24; h++)); do
        hour_labels+=$(printf "%3d" $h)
    done
    _heatmap_lines+=("$hour_labels")

    # Build heatmap row
    local heat_row="        "
    for ((h = 0; h < 24; h++)); do
        local hdata="${hourly_data[$h]:-}"
        if [[ -n "$hdata" ]]; then
            local havg
            havg=$(echo "$hdata" | tr ',' '\n' | awk '{s+=$1; n++} END {if(n>0) printf "%.0f", s/n; else print 0}')
            local ch
            if [[ $havg -lt 10 ]]; then ch="."
            elif [[ $havg -lt 30 ]]; then ch="o"
            elif [[ $havg -lt 60 ]]; then ch="O"
            elif [[ $havg -lt 100 ]]; then ch="@"
            else ch="#"
            fi
            heat_row+="  $ch"
        else
            heat_row+="  -"
        fi
    done
    _heatmap_lines+=("$heat_row")
    _heatmap_lines+=("")
    _heatmap_lines+=("  Legend: - none  . <10ms  o <30ms  O <60ms  @ <100ms  # >100ms")
    _heatmap_lines+=("")

    # Hourly detail table
    printf -v hdr "  %-6s %-8s %-8s %-8s %-6s %s" "Hour" "Avg" "Min" "Max" "Count" "Bar"
    _heatmap_lines+=("$hdr")
    printf -v sep "  %s %s %s %s %s %s" "------" "--------" "--------" "--------" "------" "--------------------"
    _heatmap_lines+=("$sep")

    # Find max count across hours for bar scaling
    local max_cnt=1
    for ((h = 0; h < 24; h++)); do
        local hdata="${hourly_data[$h]:-}"
        if [[ -n "$hdata" ]]; then
            local cnt
            cnt=$(echo "$hdata" | tr ',' '\n' | wc -l | tr -d ' ')
            if [[ $cnt -gt $max_cnt ]]; then max_cnt=$cnt; fi
        fi
    done

    for ((h = 0; h < 24; h++)); do
        local hdata="${hourly_data[$h]:-}"
        if [[ -n "$hdata" ]]; then
            local stats
            stats=$(echo "$hdata" | tr ',' '\n' | awk '
                BEGIN {min=999999; max=0; s=0; n=0}
                {s+=$1; n++; if($1<min) min=$1; if($1>max) max=$1}
                END {printf "%.1f %.1f %.1f %d", s/n, min, max, n}
            ')
            local havg hmin hmax hcount
            havg=$(echo "$stats" | awk '{print $1}')
            hmin=$(echo "$stats" | awk '{print $2}')
            hmax=$(echo "$stats" | awk '{print $3}')
            hcount=$(echo "$stats" | awk '{print $4}')

            local bar_len
            bar_len=$(awk "BEGIN {printf \"%d\", ($hcount / $max_cnt) * 20}")
            local bar=""
            local j
            for ((j = 0; j < bar_len; j++)); do bar+="="; done

            printf -v line "  %-6s %-8s %-8s %-8s %-6s %s" "$(printf '%02d:00' $h)" "${havg}ms" "${hmin}ms" "${hmax}ms" "$hcount" "$bar"
            _heatmap_lines+=("$line")
        fi
    done
}

# ================================================================
#  GRAPH LINE COLOR HELPER
# ================================================================
graph_line_color() {
    local line="$1"
    if [[ "$line" == *"X"* ]]; then echo "33"; return; fi
    if [[ "$line" == *"@"* ]]; then echo "31"; return; fi
    if [[ "$line" == *"O"* ]]; then echo "33"; return; fi
    if [[ "$line" == *"o"* ]]; then echo "36"; return; fi
    if [[ "$line" == *"."* ]]; then echo "32"; return; fi
    echo "90"
}
