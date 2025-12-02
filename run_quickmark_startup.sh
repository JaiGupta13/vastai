#!/usr/bin/env bash
#
# run_quickmark_startup.sh - Automated SiliconMark QuickMark benchmark on Vast.ai instances
#
# Usage: ./run_quickmark_startup.sh [machine_id]
#
# This script runs the benchmark entirely in the instance's startup script (no SSH required):
# 1. Prompts for a Vast.ai machine ID (or takes it as argument)
# 2. Creates a SiliconMark job to get an API key
# 3. Finds and rents the Vast.ai instance with onstart script that runs the benchmark
# 4. Waits for the benchmark to complete by monitoring logs
# 5. Parses results from logs and saves to quickmark_results.json
# 6. Destroys the instance
#
set -euo pipefail

# ============================================================================
# Configuration - Set these environment variables or edit defaults
# ============================================================================
SD_EMAIL="${SD_EMAIL:-tojaigupta@gmail.com}"
SD_PASSWORD="${SD_PASSWORD:-czq@ctc6rhr2TGE_unv}"
VAST_API_KEY="${VAST_API_KEY:-}"  # Will use ~/.vast_api_key if not set

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_FILE="${SCRIPT_DIR}/quickmark_results.json"

# ============================================================================
# Helper Functions
# ============================================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}════════════════════════════════════════${NC}"; }

cleanup() {
    if [[ -n "${INSTANCE_ID:-}" ]]; then
        log_warn "Cleaning up: destroying instance $INSTANCE_ID..."
        vast destroy instance "$INSTANCE_ID" --raw 2>/dev/null || true
    fi
    rm -f "${SCRIPT_DIR}/job.json" "${SCRIPT_DIR}/siliconmark_output.json" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================================
# Step 0: Validate Prerequisites
# ============================================================================
log_step "Step 0: Validating Prerequisites"

# Check for required tools
for cmd in curl jq vast; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command '$cmd' not found. Please install it."
        exit 1
    fi
done
log_success "All required tools found"

# Check SiliconData credentials
if [[ "$SD_EMAIL" == "you@example.com" || -z "$SD_PASSWORD" ]]; then
    log_error "Set SD_EMAIL and SD_PASSWORD environment variables"
    exit 1
fi
log_success "SiliconData credentials configured"

# Check Vast.ai API key
if [[ -z "$VAST_API_KEY" ]] && [[ ! -f ~/.vast_api_key ]]; then
    log_error "No Vast.ai API key found. Set VAST_API_KEY or run 'vast set api-key YOUR_KEY'"
    exit 1
fi
log_success "Vast.ai API key configured"

# ============================================================================
# Step 1: Get Machine ID
# ============================================================================
log_step "Step 1: Get Machine ID"

if [[ $# -ge 1 ]]; then
    MACHINE_ID="$1"
    log_info "Using machine ID from argument: $MACHINE_ID"
else
    echo -e "${YELLOW}Enter the Vast.ai machine ID to benchmark:${NC}"
    read -r MACHINE_ID
fi

if [[ -z "$MACHINE_ID" || ! "$MACHINE_ID" =~ ^[0-9]+$ ]]; then
    log_error "Invalid machine ID: '$MACHINE_ID'. Must be a number."
    exit 1
fi
log_success "Target machine ID: $MACHINE_ID"

# ============================================================================
# Step 2: Find Offer for Machine
# ============================================================================
log_step "Step 2: Finding Offer for Machine $MACHINE_ID"

log_info "Searching for available offers on machine $MACHINE_ID..."

# Search for offers on this specific machine
OFFER_JSON=$(vast search offers "machine_id=$MACHINE_ID rentable=true" --raw 2>/dev/null || echo "[]")

if [[ "$OFFER_JSON" == "[]" ]] || [[ -z "$OFFER_JSON" ]]; then
    log_error "No rentable offers found for machine $MACHINE_ID"
    log_info "The machine may be offline, already rented, or unlisted."
    exit 1
fi

# Parse offer details
OFFER_ID=$(echo "$OFFER_JSON" | jq -r '.[0].id // empty')
GPU_NAME=$(echo "$OFFER_JSON" | jq -r '.[0].gpu_name // "Unknown GPU"')
NUM_GPUS=$(echo "$OFFER_JSON" | jq -r '.[0].num_gpus // 1')
DPH_TOTAL=$(echo "$OFFER_JSON" | jq -r '.[0].dph_total // 0')
DLPERF=$(echo "$OFFER_JSON" | jq -r '.[0].dlperf // 0')
HOST_ID=$(echo "$OFFER_JSON" | jq -r '.[0].host_id // empty')
GEOLOCATION=$(echo "$OFFER_JSON" | jq -r '.[0].geolocation // "Unknown"')

if [[ -z "$OFFER_ID" ]]; then
    log_error "Could not parse offer ID from search results"
    echo "$OFFER_JSON" | jq .
    exit 1
fi

log_success "Found offer:"
echo -e "  ${CYAN}Offer ID:${NC}     $OFFER_ID"
echo -e "  ${CYAN}GPU:${NC}          $NUM_GPUS x $GPU_NAME"
echo -e "  ${CYAN}DLPerf:${NC}       $DLPERF"
echo -e "  ${CYAN}Price:${NC}        \$${DPH_TOTAL}/hr"
echo -e "  ${CYAN}Location:${NC}     $GEOLOCATION"
echo -e "  ${CYAN}Host ID:${NC}      $HOST_ID"

log_info "Proceeding automatically to rent this instance..."

# ============================================================================
# Step 3: Create SiliconMark Job
# ============================================================================
log_step "Step 3: Creating SiliconMark Job"

SD_JOBNAME="quickmark-machine-${MACHINE_ID}-$(date +%Y%m%d-%H%M%S)"
log_info "Job name: $SD_JOBNAME"

# Login to SiliconData
log_info "Logging into SiliconData as $SD_EMAIL..."
SD_LOGIN=$(cat <<EOF
{"email":"$SD_EMAIL","password":"$SD_PASSWORD"}
EOF
)

LOGIN_RESPONSE=$(curl -sS --location 'https://api.silicondata.com/api/user/login' \
    --header 'Content-Type: application/json' \
    --data-raw "$SD_LOGIN")

SD_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.data.id_token // .id_token // empty')

if [[ -z "$SD_TOKEN" || "$SD_TOKEN" == "null" ]]; then
    log_error "Failed to get SiliconData auth token"
    echo "$LOGIN_RESPONSE" | jq .
    exit 1
fi
log_success "Got SiliconData auth token"

# Create job
log_info "Creating SiliconMark job..."
SD_JOBDATA=$(cat <<EOF
{
    "name": "$SD_JOBNAME",
    "benchmarks": ["quick_mark"],
    "node_count": 1,
    "description": "QuickMark benchmark for Vast.ai machine $MACHINE_ID ($GPU_NAME)"
}
EOF
)

JOB_RESPONSE=$(curl -sS --location 'https://api.silicondata.com/api/silicon-mark/v1/jobs' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $SD_TOKEN" \
    --data "$SD_JOBDATA")

echo "$JOB_RESPONSE" > "${SCRIPT_DIR}/job.json"

JOB_TOKEN=$(echo "$JOB_RESPONSE" | jq -r '.data.token // .token // empty')
JOB_ID=$(echo "$JOB_RESPONSE" | jq -r '.data.id // .id // empty')

if [[ -z "$JOB_TOKEN" || "$JOB_TOKEN" == "null" ]]; then
    log_error "Failed to create SiliconMark job"
    cat "${SCRIPT_DIR}/job.json" | jq .
    exit 1
fi

log_success "SiliconMark job created"
echo -e "  ${CYAN}Job ID:${NC}    $JOB_ID"
echo -e "  ${CYAN}API Key:${NC}   ${JOB_TOKEN:0:40}..."

# ============================================================================
# Step 4: Create Vast.ai Instance
# ============================================================================
log_step "Step 4: Creating Vast.ai Instance"

# Create the onstart script that will install deps and run the benchmark
# Note: We embed the JOB_TOKEN directly into the script
ONSTART_SCRIPT=$(cat <<ONSTART_EOF
#!/bin/bash
set -ex
echo "=== QuickMark Setup Starting ==="

# Install dependencies
apt-get update
apt-get install -y libgpgme11 wget

# Install pynvml (might already be present)
pip3 install pynvml || true

# Install torch
pip3 install torch || true

# Download SiliconMark agent
cd /workspace
wget -q -O ./agent https://downloads.silicondata.com/agent
chmod +x ./agent

echo "=== Setup Complete, Running Benchmark ==="

# Run the benchmark with embedded API key
./agent -api-key '$JOB_TOKEN' 2>&1

echo "=== QUICKMARK_BENCHMARK_COMPLETE ==="
ONSTART_EOF
)

log_info "Creating instance from offer $OFFER_ID..."
log_info "Using image: vastai/pytorch"

CREATE_OUTPUT=$(vast create instance "$OFFER_ID" \
    --image "vastai/pytorch" \
    --ssh \
    --direct \
    --disk 20 \
    --onstart-cmd "$ONSTART_SCRIPT" \
    --label "quickmark-$MACHINE_ID" \
    --raw 2>&1) || {
    log_error "Failed to create instance"
    echo "$CREATE_OUTPUT"
    exit 1
}

echo "$CREATE_OUTPUT"
INSTANCE_ID=$(echo "$CREATE_OUTPUT" | jq -r '.new_contract // empty')

if [[ -z "$INSTANCE_ID" ]]; then
    log_error "Could not get instance ID from create response"
    exit 1
fi

log_success "Instance created: $INSTANCE_ID"

# ============================================================================
# Step 5: Wait for Instance to be Ready
# ============================================================================
log_step "Step 5: Waiting for Instance to be Ready"

MAX_WAIT=300  # 5 minutes
WAITED=0
POLL_INTERVAL=10

while [[ $WAITED -lt $MAX_WAIT ]]; do
    INSTANCE_INFO=$(vast show instance "$INSTANCE_ID" --raw 2>/dev/null || echo "{}")
    STATUS=$(echo "$INSTANCE_INFO" | jq -r '.actual_status // .status // "unknown"')
    
    echo -e "  Status: ${YELLOW}$STATUS${NC} (waited ${WAITED}s)"
    
    if [[ "$STATUS" == "running" ]]; then
        log_success "Instance is running!"
        break
    elif [[ "$STATUS" == "exited" ]] || [[ "$STATUS" == "error" ]]; then
        log_error "Instance failed to start (status: $STATUS)"
        vast logs "$INSTANCE_ID" 2>/dev/null | tail -50 || true
        exit 1
    fi
    
    sleep $POLL_INTERVAL
    WAITED=$((WAITED + POLL_INTERVAL))
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_error "Timeout waiting for instance to start"
    exit 1
fi

# Wait for benchmark to complete by checking logs
log_info "Waiting for benchmark to complete (running in startup script)..."
log_info "Monitoring logs for 'QUICKMARK_BENCHMARK_COMPLETE' message..."
log_info "This typically takes 5-10 minutes..."

MAX_WAIT=900  # 15 minutes max wait (benchmark can take a while)
WAITED=0
POLL_INTERVAL=10
BENCHMARK_OUTPUT=""

while [[ $WAITED -lt $MAX_WAIT ]]; do
    # Check logs for completion marker
    LOGS=$(vast logs "$INSTANCE_ID" 2>/dev/null || echo "")
    
    # Show the last non-empty line of logs
    LAST_LINE=$(echo "$LOGS" | grep -v '^$' | tail -1)
    if [[ -n "$LAST_LINE" ]]; then
        # Clear line and show last log (truncate if too long)
        DISPLAY_LINE="${LAST_LINE:0:80}"
        printf "\r\033[K  ${CYAN}[${WAITED}s]${NC} $DISPLAY_LINE"
    else
        printf "\r\033[K  ${YELLOW}Waiting for logs... (${WAITED}s / ${MAX_WAIT}s)${NC}"
    fi
    
    if echo "$LOGS" | grep -q "QUICKMARK_BENCHMARK_COMPLETE"; then
        echo ""
        log_success "Benchmark complete detected in logs!"
        BENCHMARK_OUTPUT="$LOGS"
        break
    fi
    
    sleep $POLL_INTERVAL
    WAITED=$((WAITED + POLL_INTERVAL))
done

echo ""

if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_error "Timeout waiting for benchmark to complete"
    log_info "Showing recent logs:"
    vast logs "$INSTANCE_ID" 2>/dev/null | tail -100 || true
    exit 1
fi

log_success "Benchmark completed!"

# ============================================================================
# Step 6: Parse and Save Results
# ============================================================================
log_step "Step 6: Parsing and Saving Results"

# Extract the JSON result from the output
# The final result is a multi-line pretty-printed JSON that starts with '{' alone on a line
# (unlike the log lines which are single-line JSON like {"time":"...","level":"INFO",...})
# Strategy: Find the standalone '{' that is followed by "benchmark_results" (the main result JSON)
RESULT_JSON=$(echo "$BENCHMARK_OUTPUT" | python3 -c '
import sys
lines = sys.stdin.readlines()

# Find the line with QUICKMARK_BENCHMARK_COMPLETE to know where to stop
marker_idx = None
for i, line in enumerate(lines):
    if "QUICKMARK_BENCHMARK_COMPLETE" in line:
        marker_idx = i
        break

# Find the standalone { that is followed by "benchmark_results" (the main result JSON)
json_start = None
for i in range(len(lines)):
    stripped = lines[i].strip()
    # Check if this is a standalone { (not part of single-line JSON)
    if stripped == "{":
        # Check if the next few lines contain "benchmark_results"
        # Look ahead up to 3 lines
        for j in range(i + 1, min(i + 4, len(lines))):
            if 'benchmark_results' in lines[j]:
                json_start = i
                break
        if json_start is not None:
            break

if json_start is not None and marker_idx is not None:
    # Extract from json_start to marker_idx (exclusive)
    print("".join(lines[json_start:marker_idx]), end="")
elif json_start is not None:
    # No marker found, extract to end
    print("".join(lines[json_start:]), end="")
else:
    # Fallback: find first standalone { before marker
    if marker_idx is not None:
        for i in range(marker_idx - 1, -1, -1):
            stripped = lines[i].strip()
            if stripped == "{":
                print("".join(lines[i:marker_idx]), end="")
                break
    else:
        sys.exit(1)
')

if [[ -z "$RESULT_JSON" ]] || ! echo "$RESULT_JSON" | jq . > /dev/null 2>&1; then
    log_error "Could not parse benchmark results"
    log_info "Raw output saved for debugging"
    echo "$BENCHMARK_OUTPUT" > "${SCRIPT_DIR}/siliconmark_raw_output.txt"
    
    # Show what we tried to extract for debugging
    log_info "Attempted to extract JSON starting with standalone '{'"
    log_info "If this fails, the output format may have changed"
    exit 1
fi

# Save raw result
echo "$RESULT_JSON" > "${SCRIPT_DIR}/siliconmark_output.json"
log_info "Raw result saved to siliconmark_output.json"

# Extract key metrics
BF16_TFLOPS=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.bf16_tflops // 0')
FP16_TFLOPS=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.fp16_tflops // 0')
FP32_TFLOPS=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.fp32_tflops // 0')
MIXED_TFLOPS=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.mixed_precision_tflops // 0')
MEM_BW=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.memory_bandwidth_gbs // 0')
POWER=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.power_consumption_watts // 0')
TEMP=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.results.aggregate_results.temperature_centigrade // 0')
TIMESTAMP=$(echo "$RESULT_JSON" | jq -r '.benchmark_results.quick_mark.ended_at // empty')
SM_GPU_MODEL=$(echo "$RESULT_JSON" | jq -r '.gpu_model // empty')
SM_GPU_COUNT=$(echo "$RESULT_JSON" | jq -r '.gpu_count // 1')

log_success "Benchmark Results:"
echo -e "  ${CYAN}GPU:${NC}               $SM_GPU_MODEL (x$SM_GPU_COUNT)"
echo -e "  ${CYAN}BF16 TFLOPS:${NC}       $BF16_TFLOPS"
echo -e "  ${CYAN}FP16 TFLOPS:${NC}       $FP16_TFLOPS"
echo -e "  ${CYAN}FP32 TFLOPS:${NC}       $FP32_TFLOPS"
echo -e "  ${CYAN}Mixed Precision:${NC}   $MIXED_TFLOPS TFLOPS"
echo -e "  ${CYAN}Memory BW:${NC}         $MEM_BW GB/s"
echo -e "  ${CYAN}Power:${NC}             $POWER W"
echo -e "  ${CYAN}Temperature:${NC}       $TEMP °C"

# Build the entry for quickmark_results.json
NEW_ENTRY=$(jq -n \
    --argjson machine_id "$MACHINE_ID" \
    --argjson quickmark_score "$BF16_TFLOPS" \
    --arg score_metric "bf16_tflops" \
    --arg measured_at "$TIMESTAMP" \
    --arg gpu_model "$SM_GPU_MODEL" \
    --argjson gpu_count "$SM_GPU_COUNT" \
    --arg notes "Automated benchmark via run_quickmark_startup.sh (no SSH)" \
    --arg siliconmark_job_id "$JOB_ID" \
    --argjson host_id "${HOST_ID:-null}" \
    --argjson dlperf "$DLPERF" \
    --argjson bf16_tflops "$BF16_TFLOPS" \
    --argjson fp16_tflops "$FP16_TFLOPS" \
    --argjson fp32_tflops "$FP32_TFLOPS" \
    --argjson mixed_precision_tflops "$MIXED_TFLOPS" \
    --argjson memory_bandwidth_gbs "$MEM_BW" \
    --argjson power_consumption_watts "$POWER" \
    --argjson temperature_centigrade "$TEMP" \
    '{
        machine_id: $machine_id,
        host_id: $host_id,
        quickmark_score: $quickmark_score,
        score_metric: $score_metric,
        measured_at: $measured_at,
        gpu_model: $gpu_model,
        gpu_count: $gpu_count,
        dlperf_at_benchmark: $dlperf,
        notes: $notes,
        siliconmark_job_id: $siliconmark_job_id,
        aggregate_results: {
            bf16_tflops: $bf16_tflops,
            fp16_tflops: $fp16_tflops,
            fp32_tflops: $fp32_tflops,
            mixed_precision_tflops: $mixed_precision_tflops,
            memory_bandwidth_gbs: $memory_bandwidth_gbs,
            power_consumption_watts: $power_consumption_watts,
            temperature_centigrade: $temperature_centigrade
        }
    }')

# Append to results file
if [[ -f "$RESULTS_FILE" ]]; then
    # Read existing, append new entry
    EXISTING=$(cat "$RESULTS_FILE")
    echo "$EXISTING" | jq --argjson new "$NEW_ENTRY" '. + [$new]' > "$RESULTS_FILE"
else
    # Create new file with array
    echo "[$NEW_ENTRY]" | jq . > "$RESULTS_FILE"
fi

log_success "Results appended to $RESULTS_FILE"

# ============================================================================
# Step 7: Cleanup
# ============================================================================
log_step "Step 7: Destroying Instance"

log_info "Destroying instance $INSTANCE_ID..."
vast destroy instance "$INSTANCE_ID" --raw || {
    log_warn "Failed to destroy instance automatically. Please destroy manually!"
    log_warn "Run: vast destroy instance $INSTANCE_ID"
}
INSTANCE_ID=""  # Clear so trap doesn't try again

log_success "Instance destroyed"

# Cleanup temp files
rm -f "${SCRIPT_DIR}/job.json" "${SCRIPT_DIR}/siliconmark_output.json"

# ============================================================================
# Done!
# ============================================================================
log_step "Benchmark Complete!"

echo -e "${GREEN}Summary:${NC}"
echo -e "  Machine ID:      $MACHINE_ID"
echo -e "  GPU:             $SM_GPU_MODEL"
echo -e "  QuickMark Score: ${GREEN}$BF16_TFLOPS${NC} BF16 TFLOPS"
echo -e "  DLPerf:          $DLPERF"
echo -e "  Results saved:   $RESULTS_FILE"
echo ""
echo -e "${CYAN}Tip:${NC} Refresh your dashboard to see the new data point!"

