#!/usr/bin/env bash
#
# Sandbox Controller Benchmark
#
# Benchmarks the sandbox controller end-to-end via its HTTP API.
# Instead of manipulating K8s directly (kubectl label, kubectl scale),
# this script talks to the controller which owns the full lifecycle.
#
# Modes:
#   random         — Organic load: random phases (steady, surge, cool)
#   deterministic  — Fixed 15-min repeating cycles for reproducible results
#
# Usage:
#   ./benchmark.sh                                    60min, random mode
#   ./benchmark.sh --duration 30                      30 minutes
#   ./benchmark.sh --deterministic                    Deterministic cycles
#   ./benchmark.sh --baseline 50 --surge-max 500      Custom load targets
#   ./benchmark.sh --lifetime 2m                      Custom TTL per claim
#   ./benchmark.sh --dry-run                          Print plan, no API calls
#   ./benchmark.sh --help                             Show all options
#
# The controller handles:
#   - Pool scaling (Deployment replicas)
#   - Sandbox claiming (detach pod from Deployment, set TTL)
#   - TTL-based garbage collection (expired pods deleted automatically)
#   - Replacement pod creation (Deployment self-heals)
#
# Ctrl+C cleanly stops — scales pool to 0 and exits.
# Logs saved to: app/tests/logs/benchmark_<start>_<end>.log
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source .env if available
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    source "${REPO_DIR}/.env"
    set +a
fi

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*" >&2; }
fail()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; exit 1; }
phase_banner() { echo -e "\n${BOLD}${MAGENTA}━━━ $* ━━━${NC}"; }
sep()   { echo -e "${DIM}$(printf '%.0s─' {1..72})${NC}"; }

# ---------------------------------------------------------------------------
# Configuration (all overridable via flags or env vars)
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-sandbox}"
CONTROL_NAMESPACE="${CONTROL_NAMESPACE:-sandbox-control}"
CONTROLLER_SVC="${CONTROLLER_SVC:-sandbox-controller}"

BASELINE="${BASELINE:-10}"
SURGE_MIN="${SURGE_MIN:-30}"
SURGE_MAX="${SURGE_MAX:-80}"
SMALL_PEAK="${SMALL_PEAK:-40}"
LARGE_PEAK="${LARGE_PEAK:-80}"
LIFETIME="${LIFETIME:-3m}"            # Default TTL per claimed sandbox
DURATION_MIN="${DURATION_MIN:-60}"    # Benchmark duration in minutes
CONCURRENCY="${CONCURRENCY:-5}"      # Max parallel provisions
DETERMINISTIC=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"

START_TS="$(date '+%Y%m%d-%H%M%S')"
LOG_TMP="${LOG_DIR}/benchmark_${START_TS}_running.log"

exec > >(tee >(sed $'s/\033\\[[0-9;]*[a-zA-Z]//g' >> "${LOG_TMP}")) 2>&1

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)       DURATION_MIN="$2"; shift 2 ;;
        --baseline)       BASELINE="$2"; shift 2 ;;
        --surge-min)      SURGE_MIN="$2"; shift 2 ;;
        --surge-max)      SURGE_MAX="$2"; shift 2 ;;
        --small-peak)     SMALL_PEAK="$2"; shift 2 ;;
        --large-peak)     LARGE_PEAK="$2"; shift 2 ;;
        --lifetime)       LIFETIME="$2"; shift 2 ;;
        --concurrency)    CONCURRENCY="$2"; shift 2 ;;
        --deterministic)  DETERMINISTIC=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --namespace)      NAMESPACE="$2"; shift 2 ;;
        --control-ns)     CONTROL_NAMESPACE="$2"; shift 2 ;;
        -h|--help)
            head -33 "$0" | tail -31
            echo ""
            echo "Flags:"
            echo "  --duration N       Benchmark duration in minutes (default: 60)"
            echo "  --baseline N       Steady-state pool size (default: 10)"
            echo "  --surge-min N      Min pool during surge (default: 30)"
            echo "  --surge-max N      Max pool during surge (default: 80)"
            echo "  --small-peak N     Deterministic small peak (default: 40)"
            echo "  --large-peak N     Deterministic large peak (default: 80)"
            echo "  --lifetime DUR     TTL per claimed sandbox (default: 3m)"
            echo "  --concurrency N    Max parallel provisions (default: 5)"
            echo "  --deterministic    Fixed 15-min repeating cycles"
            echo "  --dry-run          Print plan without API calls"
            echo "  --namespace NS     Sandbox namespace (default: sandbox)"
            echo "  --control-ns NS    Controller namespace (default: sandbox-control)"
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

DURATION_SEC=$((DURATION_MIN * 60))

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL_PROVISIONS=0
TOTAL_PROVISION_ERRORS=0
TOTAL_DELETES=0

# ---------------------------------------------------------------------------
# Random helpers
# ---------------------------------------------------------------------------
rand_between() {
    local min="$1" max="$2"
    echo $(( min + RANDOM % (max - min + 1) ))
}

# ---------------------------------------------------------------------------
# Controller API
# ---------------------------------------------------------------------------
CONTROLLER_URL=""

resolve_controller() {
    if [[ -n "$CONTROLLER_URL" ]]; then return 0; fi
    local ip
    ip=$(kubectl get svc "${CONTROLLER_SVC}" -n "${CONTROL_NAMESPACE}" \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [[ -z "$ip" ]]; then
        fail "Cannot resolve controller service '${CONTROLLER_SVC}' in '${CONTROL_NAMESPACE}'"
    fi
    CONTROLLER_URL="http://${ip}:8080"
    ok "Controller URL: ${CONTROLLER_URL}"
}

# Run a curl command from inside the cluster via an ephemeral pod.
# This approach works regardless of local network access to the cluster.
api_call() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    if $DRY_RUN; then
        log "[DRY-RUN] ${method} ${path} ${body}"
        # Return plausible mock data for dry-run
        case "$path" in
            /api/status)   echo '{"idle":5,"pending":0,"active":0,"failed":0,"total":5,"poolSize":10}' ;;
            /api/provision) echo '{"name":"sandbox-dry-run","node":"node-1","podIP":"10.0.0.1","state":"provisioning"}' ;;
            /healthz)      echo '{"status":"ok"}' ;;
            *)             echo '{}' ;;
        esac
        return 0
    fi

    local url="${CONTROLLER_URL}${path}"
    local -a curl_cmd=(curl -s -w '\n%{http_code}' -X "${method}" -H "Content-Type: application/json")
    [[ -n "$body" ]] && curl_cmd+=(-d "$body")
    curl_cmd+=("${url}")

    local raw
    raw=$(kubectl run --rm -i --restart=Never --image=curlimages/curl:latest \
        "bench-curl-$(date +%s%N | tail -c 10)" -n "${CONTROL_NAMESPACE}" \
        --command -- "${curl_cmd[@]}" 2>/dev/null | grep -v "^pod ")

    # curl -w appends HTTP status code as the last line.
    # Extract only the JSON body (everything except the last line).
    # Use sed (macOS-compatible) instead of head -n -1 (GNU-only).
    local body_only
    body_only=$(echo "$raw" | sed '$d')

    # If body_only is empty (single-line response), use raw as-is.
    if [[ -z "$body_only" ]]; then
        body_only="$raw"
    fi

    echo "$body_only"
}

# Convenience: extract JSON field
json_field() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('${field}',''))" 2>/dev/null
}

json_int() {
    local json="$1" field="$2"
    echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('${field}',0))" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Controller API wrappers
# ---------------------------------------------------------------------------

# Set pool size via controller (controller patches Deployment replicas)
set_pool_size() {
    local target="$1"
    local reason="${2:-}"

    log "Pool size → ${BOLD}${target}${NC} ${reason}"
    api_call PUT "/api/pool-size" "{\"size\":${target}}" > /dev/null
}

# Provision (claim) a sandbox via the controller.
# The controller atomically claims an idle pod, detaches it from the Deployment,
# and sets the TTL. Replacement pods are created by the Deployment controller.
provision_sandbox() {
    local lifetime="${1:-$LIFETIME}"
    local response
    response=$(api_call POST "/api/provision" "{\"lifetime\":\"${lifetime}\"}")

    local name state
    name=$(json_field "$response" "name")
    state=$(json_field "$response" "state")

    if [[ -z "$name" || "$name" == "None" ]]; then
        TOTAL_PROVISION_ERRORS=$((TOTAL_PROVISION_ERRORS + 1))
        local err
        err=$(json_field "$response" "error")
        echo -e "  ${RED}✗ provision failed: ${err:-unknown}${NC}"
        return 1
    fi

    TOTAL_PROVISIONS=$((TOTAL_PROVISIONS + 1))
    echo "$name"
    return 0
}

# Delete a specific sandbox via the controller.
delete_sandbox() {
    local name="$1"
    api_call DELETE "/api/sandboxes/${name}" > /dev/null
    TOTAL_DELETES=$((TOTAL_DELETES + 1))
}

# Get pool status
get_status() {
    api_call GET "/api/status"
}

# Get metrics summary
get_metrics() {
    api_call GET "/api/metrics/summary"
}

# Reset metrics
reset_metrics() {
    api_call POST "/api/metrics/reset" > /dev/null
}

# ---------------------------------------------------------------------------
# Status line (queries controller, not kubectl)
# ---------------------------------------------------------------------------
status_line() {
    local status_json
    status_json=$(get_status)
    local idle pending active failed total pool_size
    idle=$(json_int "$status_json" "idle")
    pending=$(json_int "$status_json" "pending")
    active=$(json_int "$status_json" "active")
    failed=$(json_int "$status_json" "failed")
    total=$(json_int "$status_json" "total")
    pool_size=$(json_int "$status_json" "poolSize")
    echo -e "  ${DIM}pool:${NC} ${GREEN}${idle}${NC} idle  ${YELLOW}${pending}${NC} pending  ${CYAN}${active}${NC} active  ${RED}${failed}${NC} failed  ${DIM}total:${NC} ${total}  ${DIM}target:${NC} ${pool_size}"
}

# Metrics summary
metrics_summary() {
    local metrics_json
    metrics_json=$(get_metrics)

    echo -e "\n${BOLD}${BLUE}▸ Metrics Summary${NC}"

    local sched_count sched_avg sched_p50 sched_p95 sched_p99
    sched_count=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('count',0))" 2>/dev/null)
    sched_avg=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('avg',0))" 2>/dev/null)
    sched_p50=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p50',0))" 2>/dev/null)
    sched_p95=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p95',0))" 2>/dev/null)
    sched_p99=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p99',0))" 2>/dev/null)

    echo -e "  ${MAGENTA}Schedule Duration${NC} (pod create → Running):"
    echo -e "    count: ${BOLD}${sched_count}${NC}  avg: ${BOLD}${sched_avg}s${NC}  p50: ${sched_p50}s  p95: ${sched_p95}s  p99: ${sched_p99}s"

    local claim_count claim_avg claim_p50 claim_p95 claim_p99
    claim_count=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('count',0))" 2>/dev/null)
    claim_avg=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('avg',0))" 2>/dev/null)
    claim_p50=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p50',0))" 2>/dev/null)
    claim_p95=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p95',0))" 2>/dev/null)
    claim_p99=$(echo "$metrics_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p99',0))" 2>/dev/null)

    echo -e "  ${MAGENTA}Claim-to-Ready${NC} (provision → pod Ready):"
    echo -e "    count: ${BOLD}${claim_count}${NC}  avg: ${BOLD}${claim_avg}s${NC}  p50: ${claim_p50}s  p95: ${claim_p95}s  p99: ${claim_p99}s"
}

# Node overview
node_summary() {
    if $DRY_RUN; then return 0; fi
    echo -e "  ${DIM}Nodes:${NC}"
    kubectl get nodes --no-headers \
        -o custom-columns='POOL:.metadata.labels.cloud\.google\.com/gke-nodepool' 2>/dev/null \
        | sort | uniq -c | sort -rn | while read -r cnt pool; do
            echo -e "    ${pool}: ${BOLD}${cnt}${NC}"
        done
}

# ---------------------------------------------------------------------------
# Provision N sandboxes (with concurrency throttle)
# ---------------------------------------------------------------------------
provision_batch() {
    local count="$1"
    local lifetime="${2:-$LIFETIME}"

    if $DRY_RUN; then
        log "[DRY-RUN] Provision ${count} sandboxes (lifetime: ${lifetime})"
        return 0
    fi

    echo -e "  ${CYAN}↳ provisioning ${count} sandboxes${NC} ${DIM}(lifetime: ${lifetime}, concurrency: ${CONCURRENCY})${NC}"

    local provisioned=0
    local pids=()

    for ((i = 0; i < count; i++)); do
        (
            provision_sandbox "$lifetime" > /dev/null 2>&1
        ) &
        pids+=($!)

        # Throttle: wait when we hit concurrency limit
        if (( ${#pids[@]} >= CONCURRENCY )); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done

    # Wait for remaining
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Phase: STEADY — baseline pool, light provision drip
# ---------------------------------------------------------------------------
phase_steady() {
    local duration_sec="${1:-60}"
    local label="${2:-STEADY}"

    phase_banner "${label}  (${duration_sec}s, pool=${BASELINE})"
    set_pool_size "${BASELINE}" "(${label,,})"

    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        # Light provision: 1-10% of pool per tick
        local pct batch
        pct=$(rand_between 1 10)
        batch=$(( BASELINE * pct / 100 ))
        [[ $batch -lt 1 ]] && batch=1

        # 15% chance of a larger burst
        local roll
        roll=$(rand_between 1 100)
        if [[ $roll -le 15 ]]; then
            pct=$(rand_between 20 40)
            batch=$(( BASELINE * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            log "${YELLOW}⚡ Burst: provisioning ${batch} sandboxes${NC}"
        fi

        provision_batch "$batch"

        local wait_secs
        wait_secs=$(rand_between 1 3)
        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs))

        if (( elapsed % 15 < 5 )); then
            status_line
        fi
    done
    status_line
}

# ---------------------------------------------------------------------------
# Phase: SURGE — scale up, aggressive provisioning
# ---------------------------------------------------------------------------
phase_surge() {
    local target
    target=$(rand_between "$SURGE_MIN" "$SURGE_MAX")

    phase_banner "SURGE  (scaling to ${target}, blast provision)"
    set_pool_size "${target}" "(surge pre-fill)"

    # Wait for pool to fill
    log "Waiting for pool to fill..."
    local fill_wait=0
    while [[ $fill_wait -lt 90 ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        local status_json idle
        status_json=$(get_status)
        idle=$(json_int "$status_json" "idle")
        if (( idle >= target * 30 / 100 )); then
            ok "Pool reached ${idle} idle (target: ${target})"
            break
        fi
        if (( fill_wait % 10 == 0 )); then
            log "Pool filling: ${idle} idle / ${target} target"
        fi
        sleep 2
        fill_wait=$((fill_wait + 2))
    done

    status_line

    # BLAST: rapid-fire provisioning
    local blast_duration
    blast_duration=$(rand_between 30 90)
    log "${YELLOW}⚡ BLAST: provisioning for ${blast_duration}s${NC}"

    local elapsed=0
    while [[ $elapsed -lt $blast_duration ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        local batch roll pct
        roll=$(rand_between 1 100)

        if [[ $roll -le 25 ]]; then
            # 25% chance: massive provision (30-50% of pool)
            pct=$(rand_between 30 50)
            batch=$(( target * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            log "${YELLOW}🔥 Massive provision: ${pct}% (${batch} sandboxes)${NC}"
        else
            # Normal: 5-20% of pool
            pct=$(rand_between 5 20)
            batch=$(( target * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
        fi

        provision_batch "$batch"
        elapsed=$((elapsed + 1))

        if (( elapsed % 10 < 3 )); then
            status_line
        fi
    done

    status_line

    # 35% chance of double-peak
    local double_roll
    double_roll=$(rand_between 1 100)
    if [[ $double_roll -le 35 ]]; then
        local peak2
        peak2=$(rand_between "$SURGE_MIN" "$SURGE_MAX")
        phase_banner "DOUBLE PEAK  (pool=${peak2})"
        set_pool_size "${peak2}" "(second wave)"
        sleep $(rand_between 5 15)

        local blast2_duration
        blast2_duration=$(rand_between 15 45)
        log "${YELLOW}⚡ SECOND BLAST: ${blast2_duration}s${NC}"

        elapsed=0
        while [[ $elapsed -lt $blast2_duration ]]; do
            [[ "$INTERRUPTED" == "true" ]] && return
            pct=$(rand_between 10 30)
            batch=$(( peak2 * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            provision_batch "$batch"
            elapsed=$((elapsed + 1))
        done
        status_line
    fi

    node_summary
}

# ---------------------------------------------------------------------------
# Phase: COOL DOWN — step-down pool, light provision
# ---------------------------------------------------------------------------
phase_cool() {
    local duration_sec
    duration_sec=$(rand_between 20 90)

    phase_banner "COOL DOWN  (${duration_sec}s → pool=${BASELINE})"

    # Get current pool size from status
    local status_json current
    status_json=$(get_status)
    current=$(json_int "$status_json" "poolSize")

    # Step down in random jumps
    local steps step_size
    steps=$(rand_between 2 4)
    step_size=$(( (current - BASELINE) / steps ))

    if [[ $step_size -lt 1 ]]; then
        set_pool_size "${BASELINE}" "(cool)"
    else
        for step_n in $(seq 1 "$steps"); do
            [[ "$INTERRUPTED" == "true" ]] && return
            current=$((current - step_size))
            [[ $current -lt $BASELINE ]] && current=$BASELINE
            set_pool_size "$current" "(cooling step ${step_n}/${steps})"
            sleep $(rand_between 3 8)
            status_line

            # Light provision during cool-down (1-5%)
            local batch pct
            pct=$(rand_between 1 5)
            batch=$(( current * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            provision_batch "$batch"
        done
        set_pool_size "${BASELINE}" "(baseline)"
    fi

    # Light drip for remaining time
    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        local batch pct
        pct=$(rand_between 1 5)
        batch=$(( BASELINE * pct / 100 ))
        [[ $batch -lt 1 ]] && batch=1
        provision_batch "$batch"

        local wait_secs
        wait_secs=$(rand_between 2 5)
        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs))
    done

    status_line
    node_summary
}

# ---------------------------------------------------------------------------
# Deterministic phases (fixed timing, same as old cycles)
# ---------------------------------------------------------------------------
run_det_baseline() {
    local duration_sec="$1"
    local label="${2:-BASELINE}"

    phase_banner "${label}  (${duration_sec}s, pool=${BASELINE})"
    set_pool_size "${BASELINE}" "(${label,,})"

    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        local pct batch
        pct=$(rand_between 1 10)
        batch=$(( BASELINE * pct / 100 ))
        [[ $batch -lt 1 ]] && batch=1
        provision_batch "$batch"

        local wait_secs
        wait_secs=$(rand_between 1 3)
        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs))

        if (( elapsed % 15 < 5 )); then
            status_line
        fi
    done
    status_line
}

run_det_small_peak() {
    local duration_sec="$1"

    phase_banner "SMALL PEAK  (${duration_sec}s, pool=${SMALL_PEAK})"
    set_pool_size "${SMALL_PEAK}" "(small peak)"

    # Wait for fill
    log "Waiting for pool to fill..."
    local fill_wait=0
    while [[ $fill_wait -lt 30 ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        local status_json idle
        status_json=$(get_status)
        idle=$(json_int "$status_json" "idle")
        if (( idle >= SMALL_PEAK * 40 / 100 )); then
            ok "Pool reached ${idle}/${SMALL_PEAK}"
            break
        fi
        sleep 2
        fill_wait=$((fill_wait + 2))
    done

    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        local pct batch
        pct=$(rand_between 5 15)
        batch=$(( SMALL_PEAK * pct / 100 ))
        [[ $batch -lt 1 ]] && batch=1
        provision_batch "$batch"

        local wait_secs
        wait_secs=$(rand_between 0 2)
        sleep "$wait_secs"
        elapsed=$((elapsed + wait_secs + 1))

        if (( elapsed % 10 < 3 )); then
            status_line
        fi
    done
    status_line
}

run_det_large_peak() {
    local duration_sec="$1"

    phase_banner "LARGE PEAK  (${duration_sec}s, pool=${LARGE_PEAK})"
    set_pool_size "${LARGE_PEAK}" "(large peak)"

    # Wait for fill
    log "Waiting for pool to fill..."
    local fill_wait=0
    while [[ $fill_wait -lt 60 ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        local status_json idle
        status_json=$(get_status)
        idle=$(json_int "$status_json" "idle")
        if (( idle >= LARGE_PEAK * 30 / 100 )); then
            ok "Pool reached ${idle}/${LARGE_PEAK}"
            break
        fi
        if (( fill_wait % 10 == 0 )); then
            log "Pool filling: ${idle}/${LARGE_PEAK}"
        fi
        sleep 2
        fill_wait=$((fill_wait + 2))
    done

    log "${YELLOW}⚡ BLAST: aggressive provision for ${duration_sec}s${NC}"
    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return

        local batch roll pct
        roll=$(rand_between 1 100)

        if [[ $roll -le 25 ]]; then
            pct=$(rand_between 40 60)
            batch=$(( LARGE_PEAK * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            log "${YELLOW}🔥 Massive provision: ${pct}% (${batch} sandboxes)${NC}"
        else
            pct=$(rand_between 10 30)
            batch=$(( LARGE_PEAK * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
        fi

        provision_batch "$batch"
        elapsed=$((elapsed + 1))

        if (( elapsed % 10 < 3 )); then
            status_line
        fi
    done
    status_line
    node_summary
}

run_det_cool_down() {
    local duration_sec="$1"

    phase_banner "COOL DOWN  (${duration_sec}s → pool=${BASELINE})"

    local status_json current
    status_json=$(get_status)
    current=$(json_int "$status_json" "poolSize")
    local step_size=$(( (current - BASELINE) / 3 ))

    if [[ $step_size -lt 1 ]]; then
        set_pool_size "${BASELINE}" "(cool)"
    else
        for step in 1 2 3; do
            [[ "$INTERRUPTED" == "true" ]] && return
            current=$((current - step_size))
            [[ $current -lt $BASELINE ]] && current=$BASELINE
            set_pool_size "$current" "(cooling step ${step}/3)"
            sleep $((duration_sec / 3))
            status_line

            local batch pct
            pct=$(rand_between 1 5)
            batch=$(( current * pct / 100 ))
            [[ $batch -lt 1 ]] && batch=1
            provision_batch "$batch"
        done
        set_pool_size "${BASELINE}" "(cool → baseline)"
    fi
    status_line
}

# One deterministic 15-minute cycle
run_cycle() {
    local cycle_num="$1"
    local total_cycles="$2"

    sep
    echo -e "${BOLD}${CYAN} CYCLE ${cycle_num}/${total_cycles}${NC}"
    sep

    run_det_baseline   120 "BASELINE 1"       #  0:00 -  2:00  (2 min)
    run_det_small_peak 120                     #  2:00 -  4:00  (2 min)
    run_det_baseline    60 "BASELINE 2"        #  4:00 -  5:00  (1 min)
    run_det_large_peak 240                     #  5:00 -  9:00  (4 min)
    run_det_cool_down  120                     #  9:00 - 11:00  (2 min)
    run_det_baseline   120 "BASELINE 3"        # 11:00 - 13:00  (2 min)
    run_det_baseline   120 "BUFFER"            # 13:00 - 15:00  (2 min)

    echo -e "\n${BOLD}${GREEN}  ✓ Cycle ${cycle_num}/${total_cycles} complete${NC}"
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
INTERRUPTED=false
TIMER_PID=""

cleanup() {
    [[ "$INTERRUPTED" == "true" ]] && return
    INTERRUPTED=true
    echo ""
    warn "Interrupt received"
    phase_banner "SHUTDOWN"

    [[ -n "$TIMER_PID" ]] && kill "$TIMER_PID" 2>/dev/null

    # Print final metrics before shutdown
    metrics_summary

    # Print benchmark stats
    echo ""
    echo -e "${BOLD}${BLUE}▸ Benchmark Stats${NC}"
    echo -e "  Total provisions:       ${BOLD}${TOTAL_PROVISIONS}${NC}"
    echo -e "  Provision errors:       ${BOLD}${TOTAL_PROVISION_ERRORS}${NC}"
    echo -e "  Total deletes:          ${BOLD}${TOTAL_DELETES}${NC}"
    local error_rate=0
    if [[ $TOTAL_PROVISIONS -gt 0 ]]; then
        error_rate=$(python3 -c "print(round(${TOTAL_PROVISION_ERRORS}/${TOTAL_PROVISIONS}*100, 1))" 2>/dev/null || echo "0")
    fi
    echo -e "  Error rate:             ${BOLD}${error_rate}%${NC}"

    # Scale pool to 0
    set_pool_size 0 "(shutdown)"

    # Kill background processes
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null

    # Finalize log
    local end_ts
    end_ts="$(date '+%Y%m%d-%H%M%S')"
    local log_final="${LOG_DIR}/benchmark_${START_TS}_${end_ts}.log"

    cat <<FOOTER

════════════════════════════════════════════════════════════════════════════
 BENCHMARK COMPLETE
 Ended:        $(date '+%Y-%m-%d %H:%M:%S %Z')
 Provisions:   ${TOTAL_PROVISIONS} (${TOTAL_PROVISION_ERRORS} errors)
 Deletes:      ${TOTAL_DELETES}
 Error rate:   ${error_rate}%
════════════════════════════════════════════════════════════════════════════
FOOTER

    mv "${LOG_TMP}" "${log_final}" 2>/dev/null || true
    echo "Log saved: ${log_final}" >&2

    echo "Done."
    exit 0
}

trap cleanup SIGINT SIGTERM

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    if $DRY_RUN; then
        log "[DRY-RUN] Skipping preflight"
        return 0
    fi

    command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found"

    # Verify namespaces
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        fail "Namespace '${NAMESPACE}' not found"
    kubectl get namespace "${CONTROL_NAMESPACE}" >/dev/null 2>&1 || \
        fail "Namespace '${CONTROL_NAMESPACE}' not found"

    # Resolve controller
    resolve_controller

    # Health check
    local health
    health=$(api_call GET "/healthz")
    local status
    status=$(json_field "$health" "status")
    if [[ "$status" != "ok" ]]; then
        fail "Controller health check failed: ${health}"
    fi
    ok "Controller healthy"

    # Check pool status
    local pool_status
    pool_status=$(get_status)
    log "Current pool status: ${pool_status}"

    local pool_size
    pool_size=$(json_int "$pool_status" "poolSize")
    if [[ "$pool_size" -lt 1 ]]; then
        warn "Pool size is 0, benchmark will set it to ${BASELINE}"
    fi

    ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode_label="random"
    $DETERMINISTIC && mode_label="deterministic (15-min cycles)"

    cat <<EOF
════════════════════════════════════════════════════════════════════════════
 SANDBOX CONTROLLER BENCHMARK
 Started:    $(date '+%Y-%m-%d %H:%M:%S %Z')
 Duration:   ${DURATION_MIN} min
 Mode:       ${mode_label}
 Baseline:   ${BASELINE} pods
 Surge:      ${SURGE_MIN}–${SURGE_MAX} pods
 Lifetime:   ${LIFETIME} (TTL per claimed sandbox)
 Concurrency: ${CONCURRENCY} parallel provisions
════════════════════════════════════════════════════════════════════════════

EOF

    preflight

    # Reset metrics at benchmark start for clean data
    log "Resetting controller metrics..."
    reset_metrics

    # Start at baseline
    phase_banner "WARMUP"
    set_pool_size "${BASELINE}" "(initial baseline)"
    log "Waiting for baseline pool to stabilize..."
    sleep 10

    if $DETERMINISTIC; then
        # Timer to stop after duration
        local cycle=0
        (
            sleep "${DURATION_SEC}"
            kill -TERM $$ 2>/dev/null
        ) &
        TIMER_PID=$!
        log "Timer set: ${DURATION_MIN} minutes (PID ${TIMER_PID})"

        while true; do
            [[ "$INTERRUPTED" == "true" ]] && break
            cycle=$((cycle + 1))
            run_cycle "$cycle" "∞"
        done
    else
        # Timer to stop after duration
        (
            sleep "${DURATION_SEC}"
            kill -TERM $$ 2>/dev/null
        ) &
        TIMER_PID=$!
        log "Simulator started — will stop in ${DURATION_MIN} minutes (mode: ${mode_label})"

        local cycle=0
        while true; do
            [[ "$INTERRUPTED" == "true" ]] && break
            cycle=$((cycle + 1))

            # Weighted random: 20% steady, 60% surge, 20% cool
            local roll
            roll=$(rand_between 1 100)

            if [[ $roll -le 20 ]]; then
                phase_steady $(rand_between 30 120)
            elif [[ $roll -le 80 ]]; then
                phase_surge
            else
                phase_cool
            fi

            # Micro-pause
            sleep $(rand_between 2 10)
        done
    fi

    # Normal exit — print summary and cleanup
    cleanup
}

main "$@"
