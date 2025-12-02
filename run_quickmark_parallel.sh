#!/usr/bin/env bash
# Wrapper to run run_quickmark.sh against multiple machines in parallel.
# Accepts comma-separated machine IDs, runs each in the background, and streams a simple status view.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run_quickmark.sh"
LOG_DIR="${SCRIPT_DIR}/quickmark_logs"
STATUS_INTERVAL="${STATUS_INTERVAL:-5}"

usage() {
    cat <<'EOF'
Usage: ./run_quickmark_parallel.sh <machine_ids>

Provide machine IDs separated by commas (spaces are also accepted). If no IDs
are passed as arguments, the script will prompt for them.

Examples:
  ./run_quickmark_parallel.sh 12345,67890,11223
  ./run_quickmark_parallel.sh 12345 67890

Environment:
  STATUS_INTERVAL   Seconds between status refreshes (default: 5)

Logs for each run are written to quickmark_logs/.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -x "$RUNNER" ]]; then
    echo "Cannot execute $RUNNER. Ensure the original script exists and is executable."
    exit 1
fi

mkdir -p "$LOG_DIR"

prompt_for_ids() {
    echo "Enter Vast.ai machine IDs separated by commas:"
    read -r input_ids
    echo "$input_ids"
}

raw_ids=""
if [[ $# -gt 0 ]]; then
    raw_ids="$*"
else
    raw_ids="$(prompt_for_ids)"
fi

machine_ids=()
IFS=',' read -ra parts <<< "${raw_ids// /,}"
for part in "${parts[@]}"; do
    trimmed="${part//[[:space:]]/}"
    [[ -z "$trimmed" ]] && continue
    if [[ ! "$trimmed" =~ ^[0-9]+$ ]]; then
        echo "Invalid machine ID: $trimmed (must be numeric)."
        exit 1
    fi
    machine_ids+=("$trimmed")
done

if [[ ${#machine_ids[@]} -eq 0 ]]; then
    echo "No machine IDs provided. Aborting."
    exit 1
fi

echo "Launching ${#machine_ids[@]} run(s) using ${RUNNER}..."

pids=()
logs=()
statuses=()
timestamp="$(date +%Y%m%d-%H%M%S)"

for mid in "${machine_ids[@]}"; do
    log_file="${LOG_DIR}/quickmark_${mid}_${timestamp}.log"
    echo "  [${mid}] log -> ${log_file}"
    (cd "$SCRIPT_DIR" && ./run_quickmark.sh "$mid" >"$log_file" 2>&1) &
    pids+=("$!")
    logs+=("$log_file")
    statuses+=("running")
done

echo ""
echo "Monitoring progress (refresh every ${STATUS_INTERVAL}s)."
echo "Press Ctrl+C to stop monitoring; runs will continue in the background."

clear_screen() {
    if [[ -t 1 ]]; then
        printf "\033[2J\033[H"
    fi
}

strip_control_codes() {
    # Removes common ANSI color codes to keep status lines readable.
    perl -pe 's/\e\[[0-9;]*[A-Za-z]//g'
}

while :; do
    clear_screen
    echo "QuickMark parallel status @ $(date +%H:%M:%S)"
    echo "--------------------------------------------------"

    any_running=0
    for idx in "${!machine_ids[@]}"; do
        pid="${pids[$idx]}"
        state="${statuses[$idx]}"

        if [[ "$state" == "running" ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                any_running=1
            else
                if wait "$pid"; then
                    state="succeeded"
                else
                    exit_code=$?
                    state="failed (exit ${exit_code})"
                fi
                statuses[$idx]="$state"
            fi
        fi

        last_line=""
        if [[ -f "${logs[$idx]}" ]]; then
            last_line="$(tail -n 1 "${logs[$idx]}" 2>/dev/null | tr -d '\r' | strip_control_codes)"
        fi

        printf "  [%-8s] %-16s pid=%-6s log=%s\n" "${machine_ids[$idx]}" "$state" "$pid" "${logs[$idx]}"
        [[ -n "$last_line" ]] && printf "             last: %s\n" "$last_line"
    done

    if [[ $any_running -eq 0 ]]; then
        break
    fi

    sleep "$STATUS_INTERVAL"
done

echo ""
echo "All runs finished. Logs are in ${LOG_DIR}"
