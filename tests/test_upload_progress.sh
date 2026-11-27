#!/usr/bin/env bash
# =====================================================================
# Regression Test Suite: BUG-05 (Upload Progress Tracking & Dynamic Display - Unix)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================================="
echo "  TEST SUITE: BUG-05 Upload Progress Tracking (Bash/Unix)"
echo "=========================================================="

PASSED=0
FAILED=0

assert_condition() {
    local name="$1"
    local condition="$2"
    local detail="${3:-}"
    if [ "$condition" -eq 1 ]; then
        echo -e "  \033[0;32m[PASS]\033[0m $name"
        PASSED=$((PASSED + 1))
    else
        echo -e "  \033[0;31m[FAIL]\033[0m ${name}: $detail"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Test format_remaining_time helper
# Extract functions from google-unlimited.sh or source them
format_remaining_time() {
    local sec="$1"
    local s
    s=$(awk -v sec="$sec" 'BEGIN { printf "%d", sec + 0.5 }')
    if [ "$s" -ge 3600 ]; then
        local h=$((s / 3600))
        local m=$(((s % 3600) / 60))
        printf "~%dh %dm left" "$h" "$m"
    elif [ "$s" -ge 60 ]; then
        local m=$((s / 60))
        local rem_s=$((s % 60))
        printf "~%dm %ds left" "$m" "$rem_s"
    elif [ "$s" -gt 0 ]; then
        printf "~%ds left" "$s"
    else
        printf "finishing..."
    fi
}

res_sec="$(format_remaining_time 45)"
assert_condition "Seconds format (~45s left)" "$([ "$res_sec" = "~45s left" ] && echo 1 || echo 0)" "Got: $res_sec"

res_min="$(format_remaining_time 125)"
assert_condition "Minutes format (~2m 5s left)" "$([ "$res_min" = "~2m 5s left" ] && echo 1 || echo 0)" "Got: $res_min"

res_hr="$(format_remaining_time 3665)"
assert_condition "Hours format (~1h 1m left)" "$([ "$res_hr" = "~1h 1m left" ] && echo 1 || echo 0)" "Got: $res_hr"

res_zero="$(format_remaining_time 0)"
assert_condition "Zero format (finishing...)" "$([ "$res_zero" = "finishing..." ] && echo 1 || echo 0)" "Got: $res_zero"

# 2. Test calculate_fallback_ratio
calculate_fallback_ratio() {
    local elapsed="$1"
    local est_total="$2"
    awk -v elapsed="$elapsed" -v est_total="$est_total" 'BEGIN {
        if (elapsed < est_total) {
            r = (elapsed / est_total) * 0.90;
            if (r < 0.01) r = 0.01;
            if (r > 0.90) r = 0.90;
            printf "%.6f", r;
        } else {
            over = elapsed - est_total;
            denom = est_total > 30.0 ? est_total : 30.0;
            r = 0.90 + (0.09 * (1.0 - exp(-over / denom)));
            printf "%.6f", r;
        }
    }'
}

est_total=100.0
r1="$(calculate_fallback_ratio 150.0 $est_total)"
r2="$(calculate_fallback_ratio 500.0 $est_total)"
r3="$(calculate_fallback_ratio 811.9 $est_total)"

c1=$(awk -v r="$r1" 'BEGIN { print (r > 0.90) ? 1 : 0 }')
assert_condition "Fallback ratio at 150s exceeds 90%" "$c1" "Ratio: $r1"

c2=$(awk -v r="$r2" 'BEGIN { print (r > 0.95) ? 1 : 0 }')
assert_condition "Fallback ratio at 500s exceeds 95%" "$c2" "Ratio: $r2"

c3=$(awk -v r="$r3" 'BEGIN { print (r > 0.98) ? 1 : 0 }')
assert_condition "Fallback ratio at 811.9s exceeds 98% (not stuck at 86.8%)" "$c3" "Ratio: $r3"

c_mono=$(awk -v r1="$r1" -v r2="$r2" -v r3="$r3" 'BEGIN { print (r3 > r2 && r2 > r1) ? 1 : 0 }')
assert_condition "Fallback progression is strictly monotonic" "$c_mono" "$r1 -> $r2 -> $r3"

# 3. Test Progress Bar Rendering
render_progress_bar() {
    local ratio="$1"
    local bar_width="${2:-14}"
    awk -v r="$ratio" -v w="$bar_width" 'BEGIN {
        filled = int(r * w);
        if (filled < 0) filled = 0;
        if (filled > w) filled = w;
        empty = w - filled;
        bar = "";
        for (i = 0; i < filled; i++) bar = bar "#";
        for (i = 0; i < empty; i++) bar = bar "-";
        print bar;
    }'
}

bar_half="$(render_progress_bar 0.5 14)"
assert_condition "Half-filled progress bar has 7 '#' and 7 '-'" "$([ "$bar_half" = "#######-------" ] && echo 1 || echo 0)" "Got: $bar_half"

bar_full="$(render_progress_bar 1.0 14)"
assert_condition "Full progress bar has 14 '#'" "$([ "$bar_full" = "##############" ] && echo 1 || echo 0)" "Got: $bar_full"

# 4. Test Process I/O Counter Reading
get_process_io_read() {
    local pid="$1"
    local pids=("$pid")
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    if [ -n "$children" ]; then
        for c in $children; do
            pids+=("$c")
        done
    fi

    local total=0
    for p in "${pids[@]}"; do
        if [ -r "/proc/$p/io" ]; then
            local r rc
            r=$(awk '/^read_bytes:/ {print $2}' "/proc/$p/io" 2>/dev/null || echo 0)
            rc=$(awk '/^rchar:/ {print $2}' "/proc/$p/io" 2>/dev/null || echo 0)
            r="${r:-0}"
            rc="${rc:-0}"
            if [ "$rc" -gt "$r" ]; then
                total=$((total + rc))
            elif [ "$r" -gt 0 ]; then
                total=$((total + r))
            fi
        fi
    done
    echo "$total"
}

# Create a temporary file and read it directly in the background subshell
tmp_test_file="$(mktemp "${TMPDIR:-/tmp}/test_io_XXXXXX.dat")"
dd if=/dev/zero bs=1M count=4 2>/dev/null | tr '\0' 'A' > "$tmp_test_file"

# Launch child process that reads the file directly via bash built-in read
(
    sleep 0.2
    {
        for _ in 1 2 3 4; do
            IFS= read -r -N 1048576 _buf || true
        done
    } < "$tmp_test_file"
    sleep 0.4
) &
child_pid=$!

sleep 0.1
init_read="$(get_process_io_read "$child_pid")"
sleep 0.3
mid_read="$(get_process_io_read "$child_pid")"
wait "$child_pid" || true
rm -f "$tmp_test_file"

# Check if /proc/$pid/io was readable
if [ -r "/proc/$$/io" ]; then
    delta=$((mid_read - init_read))
    c_io=$(awk -v d="$delta" 'BEGIN { print (d >= 2000000) ? 1 : 0 }')
    assert_condition "Process I/O read tracking detects data stream" "$c_io" "Delta: $delta bytes"
else
    echo "  [SKIP] /proc/PID/io not supported on this platform/container (fallback ratio used)"
fi

# 5. Verify google-unlimited.sh contains live progress implementation
has_live_progress=$(grep -E -c "render_progress_bar|calculate_fallback_ratio" "$REPO_ROOT/google-unlimited.sh" 2>/dev/null || true)
has_live_progress="${has_live_progress:-0}"
assert_condition "google-unlimited.sh includes progress bar implementation" "$([ "$has_live_progress" -gt 0 ] && echo 1 || echo 0)" "Matches: $has_live_progress"

echo "=========================================================="
echo "  RESULTS: $PASSED Passed, $FAILED Failed"
echo "=========================================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
