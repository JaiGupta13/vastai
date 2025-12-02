#!/usr/bin/env bash
# Wrapper to run run_quickmark_startup.sh against multiple machines in parallel.
# Accepts comma-separated machine IDs, runs each in the background, and monitors status.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run_quickmark_startup.sh"
LOG_DIR="${SCRIPT_DIR}/quickmark_logs"
STATUS_INTERVAL="${STATUS_INTERVAL:-5}"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# Track if we should cleanup on exit
CLEANUP_ON_EXIT=0
declare -a machine_ids=()
declare -a pids=()

cleanup_and_exit() {
    echo ""
    echo "${YELLOW}Interrupted! Cleaning up...${NC}"
    
    # Kill all background jobs
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "  Killing process $pid..."
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    # Wait a moment for processes to die
    sleep 1
    
    # Destroy all instances for these machine IDs
    echo ""
    echo "Destroying Vast.ai instances..."
    for mid in "${machine_ids[@]}"; do
        # Find instances with label quickmark-$mid
        echo "  Looking for instances for machine $mid..."
        INSTANCES=$(vast show instances --raw 2>/dev/null | jq -r ".[] | select(.label == \"quickmark-$mid\") | .id" 2>/dev/null || echo "")
        
        if [[ -n "$INSTANCES" ]]; then
            for inst_id in $INSTANCES; do
                echo "  ${RED}Destroying instance $inst_id (machine $mid)${NC}"
                vast destroy instance "$inst_id" --raw 2>/dev/null || true
            done
        fi
    done
    
    echo ""
    echo "${GREEN}Cleanup complete.${NC}"
    exit 1
}

usage() {
    echo "Usage: ./run_quickmark_parallel.sh <machine_ids>"
    echo ""
    echo "Run QuickMark benchmarks on multiple Vast.ai machines in parallel."
    echo ""
    echo "Examples:"
    echo "  ./run_quickmark_parallel.sh 12345,67890,11223"
    echo "  ./run_quickmark_parallel.sh 12345 67890 11223"
    echo ""
    echo "Environment:"
    echo "  STATUS_INTERVAL   Seconds between status refreshes (default: 5)"
    echo ""
    echo "Logs are written to quickmark_logs/"
}

format_duration() {
    local seconds=$1
    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $(((seconds % 3600) / 60))m"
    fi
}

strip_ansi() {
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr -d '\r'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -x "$RUNNER" ]]; then
    echo "${RED}ERROR:${NC} Cannot execute $RUNNER"
    echo "Ensure run_quickmark_startup.sh exists and is executable."
    exit 1
fi

mkdir -p "$LOG_DIR"

# Get machine IDs
raw_ids=""
if [[ $# -gt 0 ]]; then
    raw_ids="$*"
else
    echo "Enter Vast.ai machine IDs (comma or space separated):"
    read -r raw_ids
fi

# Parse machine IDs
machine_ids=()
IFS=',' read -ra parts <<< "${raw_ids// /,}"
for part in "${parts[@]}"; do
    trimmed="${part//[[:space:]]/}"
    [[ -z "$trimmed" ]] && continue
    if [[ ! "$trimmed" =~ ^[0-9]+$ ]]; then
        echo "${RED}ERROR:${NC} Invalid machine ID: $trimmed (must be numeric)"
        exit 1
    fi
    machine_ids+=("$trimmed")
done

if [[ ${#machine_ids[@]} -eq 0 ]]; then
    echo "${RED}ERROR:${NC} No machine IDs provided."
    exit 1
fi

# Launch jobs
echo ""
echo "${BOLD}=== QuickMark Parallel Runner ===${NC}"
echo ""
echo "Launching ${#machine_ids[@]} benchmark(s)..."
echo ""

declare -a logs
declare -a statuses
declare -a start_times
declare -a end_times
declare -a exit_codes

timestamp="$(date +%Y%m%d-%H%M%S)"
global_start=$(date +%s)

for mid in "${machine_ids[@]}"; do
    log_file="${LOG_DIR}/quickmark_${mid}_${timestamp}.log"
    echo "  Starting machine ${CYAN}${mid}${NC} -> ${DIM}${log_file}${NC}"
    (cd "$SCRIPT_DIR" && ./run_quickmark_startup.sh "$mid" >"$log_file" 2>&1) &
    pids+=("$!")
    logs+=("$log_file")
    statuses+=("running")
    start_times+=("$(date +%s)")
    end_times+=("")
    exit_codes+=("")
done

echo ""
echo "Monitoring progress (refresh every ${STATUS_INTERVAL}s)."
echo "${YELLOW}Press Ctrl+C to stop and destroy all instances.${NC}"
echo ""

# Set up cleanup trap now that we have pids and machine_ids
trap cleanup_and_exit INT TERM

sleep 2

# Monitoring loop
while true; do
    clear
    now=$(date +%s)
    elapsed=$((now - global_start))
    
    echo ""
    echo "${BOLD}=== QuickMark Parallel Runner ===${NC}  $(date '+%H:%M:%S')  (elapsed: $(format_duration $elapsed))"
    echo ""
    
    # Update statuses
    running_count=0
    success_count=0
    failed_count=0
    
    for idx in "${!machine_ids[@]}"; do
        pid="${pids[$idx]}"
        state="${statuses[$idx]}"
        
        if [[ "$state" == "running" ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                running_count=$((running_count + 1))
            else
                wait "$pid" && ec=0 || ec=$?
                exit_codes[$idx]="$ec"
                end_times[$idx]="$(date +%s)"
                if [[ $ec -eq 0 ]]; then
                    statuses[$idx]="success"
                    success_count=$((success_count + 1))
                else
                    statuses[$idx]="failed"
                    failed_count=$((failed_count + 1))
                fi
            fi
        elif [[ "$state" == "success" ]]; then
            success_count=$((success_count + 1))
        elif [[ "$state" == "failed" ]]; then
            failed_count=$((failed_count + 1))
        fi
    done
    
    completed=$((success_count + failed_count))
    total=${#machine_ids[@]}
    
    echo "Progress: ${completed}/${total}  |  ${GREEN}OK: ${success_count}${NC}  ${RED}FAIL: ${failed_count}${NC}  ${CYAN}RUNNING: ${running_count}${NC}"
    echo ""
    
    # Print each machine's status
    printf "%-10s  %-12s  %-10s  %s\n" "MACHINE" "STATUS" "TIME" "LAST LOG LINE"
    printf "%-10s  %-12s  %-10s  %s\n" "-------" "------" "----" "-------------"
    
    for idx in "${!machine_ids[@]}"; do
        mid="${machine_ids[$idx]}"
        state="${statuses[$idx]}"
        start_t="${start_times[$idx]}"
        end_t="${end_times[$idx]}"
        
        # Calculate duration
        if [[ -n "$end_t" ]]; then
            duration=$((end_t - start_t))
        else
            duration=$((now - start_t))
        fi
        duration_str=$(format_duration $duration)
        
        # Status string
        case "$state" in
            running)
                status_display="${CYAN}running${NC}"
                ;;
            success)
                status_display="${GREEN}success${NC}"
                ;;
            failed)
                ec="${exit_codes[$idx]}"
                status_display="${RED}failed(${ec})${NC}"
                ;;
            *)
                status_display="unknown"
                ;;
        esac
        
        # Get last meaningful line from log (skip empty lines)
        last_line=""
        if [[ -f "${logs[$idx]}" ]]; then
            last_line=$(tail -n 5 "${logs[$idx]}" 2>/dev/null | strip_ansi | grep -v '^$' | tail -n 1 | cut -c1-60)
        fi
        [[ -z "$last_line" ]] && last_line="(waiting for output...)"
        
        printf "%-10s  " "$mid"
        echo -n "$status_display"
        # Pad to align (status_display has color codes, so we need fixed width)
        printf "%*s" $((12 - ${#state})) ""
        printf "  %-10s  %s\n" "$duration_str" "$last_line"
    done
    
    echo ""
    
    # Check if all done
    if [[ $running_count -eq 0 ]]; then
        break
    fi
    
    sleep "$STATUS_INTERVAL"
done

# Final summary
echo ""
echo "${BOLD}=== COMPLETE ===${NC}"
echo ""
echo "Total time: $(format_duration $(($(date +%s) - global_start)))"
echo "Success: ${GREEN}${success_count}${NC} / ${total}"
echo "Failed:  ${RED}${failed_count}${NC} / ${total}"
echo ""

# Show results for each machine
echo "Results:"
for idx in "${!machine_ids[@]}"; do
    mid="${machine_ids[$idx]}"
    state="${statuses[$idx]}"
    log_file="${logs[$idx]}"
    
    if [[ "$state" == "success" ]]; then
        echo "  ${GREEN}✓${NC} Machine $mid - ${log_file}"
    else
        ec="${exit_codes[$idx]}"
        echo "  ${RED}✗${NC} Machine $mid (exit $ec) - ${log_file}"
    fi
done

echo ""
echo "Logs saved to: ${LOG_DIR}"

if [[ $failed_count -gt 0 ]]; then
    echo ""
    echo "${YELLOW}Some jobs failed. Check logs for details.${NC}"
    exit 1
fi
