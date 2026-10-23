#!/usr/bin/env bash
# watchdog_runner.sh - Adaptive Watchdog Wrapper for Background Tasks
# Usage: watchdog_runner.sh [-p POLL_SEC] [-s STALL_SEC] [-t HARD_TIMEOUT_SEC] [-l LOG_FILE] -- <COMMAND> [ARGS...]

set -u

POLL_INTERVAL=5
STALL_THRESHOLD=30
HARD_TIMEOUT=180
LOG_FILE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] -- <COMMAND> [ARGS...]

Options:
  -p <seconds>   Poll interval in seconds (default: 5)
  -s <seconds>   Stall threshold without log growth or CPU activity (default: 30)
  -t <seconds>   Hard timeout in seconds (default: 180)
  -l <path>      Custom log file path (default: /tmp/watchdog_<timestamp>_<pid>.log)
  -h             Show this help message
EOF
    exit 2
}

while getopts ":p:s:t:l:h" opt; do
    case "$opt" in
        p) POLL_INTERVAL="$OPTARG" ;;
        s) STALL_THRESHOLD="$OPTARG" ;;
        t) HARD_TIMEOUT="$OPTARG" ;;
        l) LOG_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ "${1:-}" == "--" ]]; then
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "[WATCHDOG ERROR] No command specified." >&2
    usage
fi

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/tmp/watchdog_$(date +%s)_$$.log"
fi

touch "$LOG_FILE"

# Launch command in a new process group (setsid if available) with stdin closed and line-buffered output
LAUNCH_PREFIX=()
if command -v setsid >/dev/null 2>&1; then
    LAUNCH_PREFIX+=(setsid)
fi
if command -v stdbuf >/dev/null 2>&1; then
    LAUNCH_PREFIX+=(stdbuf -oL -eL)
fi

"${LAUNCH_PREFIX[@]}" "$@" < /dev/null > "$LOG_FILE" 2>&1 &
TASK_PID=$!

START_TIME=$(date +%s)
LAST_ACTIVE_TIME=$START_TIME
LAST_LOG_SIZE=0
LAST_CPU_TICKS=0

# Helper: recursively collect all descendant PIDs of a given PID
get_tree_pids() {
    local parent="$1"
    local children
    echo "$parent"
    children=$(pgrep -P "$parent" 2>/dev/null || true)
    for child in $children; do
        get_tree_pids "$child"
    done
}

# Helper: sum cumulative CPU ticks (utime + stime from /proc/<pid>/stat) and check active states (R or D)
get_tree_activity() {
    local root_pid="$1"
    local total_ticks=0
    local has_active_state=0
    local pids
    pids=$(get_tree_pids "$root_pid")

    for pid in $pids; do
        if [[ -r "/proc/$pid/stat" ]]; then
            # Read fields safely even if comm contains spaces/parentheses
            local stat_line after_comm state utime stime
            stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || true)
            if [[ -n "$stat_line" ]]; then
                after_comm="${stat_line##*) }"
                state=$(awk '{print $1}' <<< "$after_comm")
                utime=$(awk '{print $12}' <<< "$after_comm")
                stime=$(awk '{print $13}' <<< "$after_comm")
                total_ticks=$((total_ticks + ${utime:-0} + ${stime:-0}))
                if [[ "$state" == "R" || "$state" == "D" ]]; then
                    has_active_state=1
                fi
            fi
        fi
    done

    echo "${total_ticks}:${has_active_state}"
}

# Helper: graduated termination of the entire process tree
terminate_tree() {
    local root_pid="$1"
    local reason="$2"
    local elapsed="$3"

    echo "[WATCHDOG ALERT] Triggered: ${reason} after ${elapsed}s (PID: ${root_pid})" >&2

    local all_pids
    all_pids=$(get_tree_pids "$root_pid" | tac)

    # Step 1: SIGTERM
    for p in $all_pids; do
        kill -15 "$p" 2>/dev/null || true
    done

    # Wait up to 5 seconds for graceful exit
    local i
    for ((i = 0; i < 10; i++)); do
        if ! kill -0 "$root_pid" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done

    # Step 2: SIGKILL any survivors
    all_pids=$(get_tree_pids "$root_pid" | tac)
    for p in $all_pids; do
        if kill -0 "$p" 2>/dev/null; then
            echo "[WATCHDOG ALERT] Escalating to SIGKILL for PID $p" >&2
            kill -9 "$p" 2>/dev/null || true
        fi
    done

    echo "--- [WATCHDOG DIAGNOSTIC REPORT] ---" >&2
    echo "Command       : $*" >&2
    echo "Reason        : $reason" >&2
    echo "Elapsed Time  : ${elapsed}s (Stall Limit: ${STALL_THRESHOLD}s, Hard Limit: ${HARD_TIMEOUT}s)" >&2
    echo "Log File      : $LOG_FILE" >&2
    echo "--- Last 20 lines of log ---" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
    echo "------------------------------------" >&2
}

echo "[WATCHDOG] Started PID $TASK_PID | Poll: ${POLL_INTERVAL}s | Stall: ${STALL_THRESHOLD}s | Hard Timeout: ${HARD_TIMEOUT}s | Log: $LOG_FILE"

while kill -0 "$TASK_PID" 2>/dev/null; do
    sleep "$POLL_INTERVAL"

    if ! kill -0 "$TASK_PID" 2>/dev/null; then
        break
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))

    # 1. Check Hard Timeout
    if (( ELAPSED >= HARD_TIMEOUT )); then
        terminate_tree "$TASK_PID" "HARD_TIMEOUT_EXCEEDED" "$ELAPSED" "$@"
        exit 124
    fi

    # 2. Check Log Size Progress
    CURRENT_LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)

    # 3. Check CPU Ticks & Active Process States (R/D) across process tree
    ACTIVITY_INFO=$(get_tree_activity "$TASK_PID")
    CURRENT_CPU_TICKS="${ACTIVITY_INFO%%:*}"
    HAS_ACTIVE_STATE="${ACTIVITY_INFO##*:}"

    if (( CURRENT_LOG_SIZE > LAST_LOG_SIZE )) || (( CURRENT_CPU_TICKS > LAST_CPU_TICKS )) || (( HAS_ACTIVE_STATE == 1 )); then
        LAST_ACTIVE_TIME=$NOW
        LAST_LOG_SIZE=$CURRENT_LOG_SIZE
        LAST_CPU_TICKS=$CURRENT_CPU_TICKS
    fi

    IDLE_TIME=$((NOW - LAST_ACTIVE_TIME))
    if (( IDLE_TIME >= STALL_THRESHOLD )); then
        terminate_tree "$TASK_PID" "INACTIVITY_STALL_DETECTED (${IDLE_TIME}s idle)" "$ELAPSED" "$@"
        exit 125
    fi
done

wait "$TASK_PID"
EXIT_CODE=$?
END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

echo "[WATCHDOG] Process $TASK_PID completed with exit code $EXIT_CODE in ${TOTAL_ELAPSED}s (Log: $LOG_FILE)"
exit "$EXIT_CODE"
