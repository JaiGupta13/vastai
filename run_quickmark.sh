#!/usr/bin/env bash
#
# run_quickmark.sh - Automated SiliconMark QuickMark benchmark on Vast.ai instances
#
# Usage: ./run_quickmark.sh [machine_id]
#
# This script:
# 1. Prompts for a Vast.ai machine ID (or takes it as argument)
# 2. Creates a SiliconMark job to get an API key
# 3. Finds and rents the Vast.ai instance
# 4. Installs dependencies and runs the QuickMark benchmark
# 5. Saves results to quickmark_results.json
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
for cmd in curl jq vast ssh; do
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

# Create the onstart script that will run the benchmark
ONSTART_SCRIPT=$(cat <<'ONSTART_EOF'
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

echo "=== Setup Complete, Agent Ready ==="
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

# Wait for onstart script to complete by checking logs
log_info "Waiting for onstart script to complete..."
log_info "Monitoring logs for 'Setup Complete' message..."

MAX_WAIT=300  # 5 minutes max wait
WAITED=0
POLL_INTERVAL=5

while [[ $WAITED -lt $MAX_WAIT ]]; do
    # Check logs for "Setup Complete"
    LOGS=$(vast logs "$INSTANCE_ID" 2>/dev/null || echo "")
    
    # Show the last line of logs
    LAST_LINE=$(echo "$LOGS" | tail -1)
    if [[ -n "$LAST_LINE" ]]; then
        # Clear line and show last log
        printf "\r\033[K  ${CYAN}Last log:${NC} $LAST_LINE${NC}    "
    else
        printf "\r\033[K  ${YELLOW}Waiting for logs... (${WAITED}s / ${MAX_WAIT}s)${NC}    "
    fi
    
    if echo "$LOGS" | grep -q "Setup Complete"; then
        echo ""
        log_success "Setup complete detected in logs!"
        break
    fi
    
    sleep $POLL_INTERVAL
    WAITED=$((WAITED + POLL_INTERVAL))
done

echo ""

if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_warn "Timeout waiting for 'Setup Complete' in logs"
    log_info "Showing recent logs:"
    vast logs "$INSTANCE_ID" 2>/dev/null | tail -50 || true
    log_warn "Proceeding anyway - setup may still be in progress"
else
    log_success "Setup completed successfully"
fi

# ============================================================================
# Step 6: Get SSH Connection Details
# ============================================================================
log_step "Step 6: Getting SSH Connection Details"

INSTANCE_INFO=$(vast show instance "$INSTANCE_ID" --raw)
SSH_HOST=$(echo "$INSTANCE_INFO" | jq -r '.ssh_host // .public_ipaddr // empty')
SSH_PORT=$(echo "$INSTANCE_INFO" | jq -r '.ssh_port // 22')

if [[ -z "$SSH_HOST" ]]; then
    log_error "Could not get SSH host from instance info"
    echo "$INSTANCE_INFO" | jq .
    exit 1
fi

log_success "SSH connection: root@$SSH_HOST:$SSH_PORT"

# ============================================================================
# Step 7: Run SiliconMark Benchmark
# ============================================================================
log_step "Step 7: Running SiliconMark QuickMark Benchmark"

log_info "Connecting via SSH and running benchmark..."
log_info "This typically takes 2-5 minutes..."

# Run the benchmark via SSH
SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -p $SSH_PORT root@$SSH_HOST"

# First, check if agent is ready
$SSH_CMD "ls -la /workspace/agent" || {
    log_warn "Agent not found, downloading..."
    $SSH_CMD "cd /workspace && wget -q -O ./agent https://downloads.silicondata.com/agent && chmod +x ./agent"
}

# Run the benchmark and capture output
log_info "Executing SiliconMark agent with API key..."
BENCHMARK_OUTPUT=$($SSH_CMD "cd /workspace && ./agent -api-key '$JOB_TOKEN' 2>&1" | tee /dev/tty) || {
    log_error "Benchmark execution failed"
    exit 1
}

log_success "Benchmark completed!"

# ============================================================================
# Step 8: Parse and Save Results
# ============================================================================
log_step "Step 8: Parsing and Saving Results"

# Extract the JSON result from the output
# The final result is a multi-line pretty-printed JSON that starts with '{' alone on a line
# (unlike the log lines which are single-line JSON like {"time":"...","level":"INFO",...})
RESULT_JSON=$(echo "$BENCHMARK_OUTPUT" | awk '
/^{$/ { found=1; json="" }
found { json = json $0 "\n" }
END { printf "%s", json }
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
    --arg notes "Automated benchmark via run_quickmark.sh" \
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
# Step 9: Cleanup
# ============================================================================
log_step "Step 9: Destroying Instance"

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

