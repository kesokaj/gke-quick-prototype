#!/usr/bin/env bash
#
# Sandbox Controller Benchmark — User Churn Simulator
#
# Simulates users claiming sandboxes from a pre-configured warmpool.
# Sets the pool to --baseline once, then creates traffic using either
# random or deterministic phase patterns.
#
# Traffic patterns:
#   steady   — ~10 claims/tick (5-15), 1-3s interval. Normal user traffic.
#   surge    — claim rand(surge-min, surge-max). Retries until fulfilled (max 120s).
#   spike    — fire surge-max claims at once (flash crowd, no retry).
#   quiet    — near-zero traffic (0-2/tick). Observes pool recovery.
#   drip     — background 1-3 claims every 2-5s, always running.
#
# Claimed sandboxes get a random TTL (2m to --lifetime), then the controller
# GCs them and the Deployment auto-creates replacements. This tests:
#   - Claim throughput under load
#   - Pool recovery speed after surges
#   - K8s scheduling + node autoscaling under churn
#   - Controller stability at scale
#
# Duration is enforced by time checks in every phase loop, so the benchmark
# reliably stops when --duration is reached even during heavy surges.
#
# Usage:
#   ./benchmark.sh --baseline 500 --surge-min 10 --surge-max 150 --duration 30
#   ./benchmark.sh --deterministic --baseline 1000 --surge-min 10 --surge-max 150
#   ./benchmark.sh --baseline 1000 --surge-min 200 --surge-max 1000 --lifetime 5m
#   ./benchmark.sh --dry-run --baseline 50 --surge-min 10 --surge-max 30
#   ./benchmark.sh --help
#
# Ctrl+C cleanly stops and prints summary.
# Logs saved to: app/tests/logs/benchmark_<start>_<end>.log
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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
# Configuration
# ---------------------------------------------------------------------------
CONTROL_NAMESPACE="${CONTROL_NAMESPACE:-sandbox-control}"
CONTROLLER_SVC="${CONTROLLER_SVC:-sandbox-controller}"

BASELINE="${BASELINE:-100}"           # Warmpool size (set once at start)
SURGE_MIN="${SURGE_MIN:-20}"          # Min claims per surge phase
SURGE_MAX="${SURGE_MAX:-100}"         # Max claims per surge phase
LIFETIME="${LIFETIME:-5m}"            # Max TTL per claimed sandbox (random 2m to this)
DURATION_MIN="${DURATION_MIN:-60}"    # Benchmark duration in minutes
CONCURRENCY="${CONCURRENCY:-50}"     # Max parallel HTTP requests
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
        --lifetime)       LIFETIME="$2"; shift 2 ;;
        --concurrency)    CONCURRENCY="$2"; shift 2 ;;
        --deterministic)  DETERMINISTIC=true; shift ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --control-ns)     CONTROL_NAMESPACE="$2"; shift 2 ;;
        -h|--help)
            head -28 "$0" | tail -26
            echo ""
            echo "Flags:"
            echo "  --duration N       Benchmark duration in minutes (default: 60)"
            echo "  --baseline N       Warmpool size, set once at start (default: 100)"
            echo "  --surge-min N      Min claims per surge phase (default: 20)"
            echo "  --surge-max N      Max claims per surge phase (default: 100)"
            echo "  --lifetime DUR     Max TTL per sandbox, random 2m to this (default: 5m)"
            echo "  --concurrency N    Max parallel HTTP requests (default: 50)"
            echo "  --deterministic    Fixed repeating cycles"
            echo "  --dry-run          Print plan without API calls"
            echo "  --control-ns NS    Controller namespace (default: sandbox-control)"
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

DURATION_SEC=$((DURATION_MIN * 60))

# ---------------------------------------------------------------------------
# Atomic counters (file-based for subshell safety)
# ---------------------------------------------------------------------------
COUNT_DIR=$(mktemp -d "${SCRIPT_DIR}/logs/.bench_counts_XXXXXX")
echo 0 > "${COUNT_DIR}/claims"
echo 0 > "${COUNT_DIR}/errors"
echo 0 > "${COUNT_DIR}/exhausted"

# Use mkdir as a portable atomic lock (works on macOS + Linux)
inc_counter() {
    local file="${COUNT_DIR}/$1"
    local lock="${file}.lock"
    while ! mkdir "$lock" 2>/dev/null; do :; done
    local v; v=$(cat "$file"); echo $((v + 1)) > "$file"
    rmdir "$lock"
}

inc_claims()    { inc_counter "claims"; }
inc_errors()    { inc_counter "errors"; }
inc_exhausted() { inc_counter "exhausted"; }
get_claims()    { cat "${COUNT_DIR}/claims" 2>/dev/null || echo 0; }
get_errors()    { cat "${COUNT_DIR}/errors" 2>/dev/null || echo 0; }
get_exhausted() { cat "${COUNT_DIR}/exhausted" 2>/dev/null || echo 0; }

# Print actual API error once per type per phase
log_error() {
    local err="$1"
    local hash; hash=$(echo "$err" | md5sum | cut -d' ' -f1)
    if [[ ! -f "${COUNT_DIR}/err_${hash}" ]]; then
        warn "API Error: ${err}"
        touch "${COUNT_DIR}/err_${hash}"
    fi
}

rand_between() {
    local min="$1" max="$2"
    echo $(( min + RANDOM % (max - min + 1) ))
}

# Check if the benchmark duration has been exceeded.
is_expired() {
    local now; now=$(date +%s)
    (( now - BENCH_START_EPOCH >= DURATION_SEC ))
}

# Parse a duration string (e.g. "5m", "3m", "300s") to seconds.
duration_to_sec() {
    local d="$1"
    if [[ "$d" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$d" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$d" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    else
        echo "$d"
    fi
}

# Random TTL between 2m and --lifetime for each sandbox.
rand_lifetime() {
    local max_sec
    max_sec=$(duration_to_sec "$LIFETIME")
    local min_sec=120  # 2 minutes minimum
    [[ $max_sec -lt $min_sec ]] && max_sec=$min_sec
    local rand_sec
    rand_sec=$(rand_between "$min_sec" "$max_sec")
    echo "${rand_sec}s"
}

# ---------------------------------------------------------------------------
# Controller API — public LoadBalancer IP
# ---------------------------------------------------------------------------
CONTROLLER_URL=""
PORT_FORWARD_PID=""

resolve_controller() {
    if [[ -n "$CONTROLLER_URL" ]]; then return 0; fi

    local external_ip
    external_ip=$(kubectl get svc "${CONTROLLER_SVC}" -n "${CONTROL_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

    if [[ -n "$external_ip" ]]; then
        CONTROLLER_URL="http://${external_ip}:8080"
        ok "Controller: ${CONTROLLER_URL} (LoadBalancer)"
        return 0
    fi

    warn "No LoadBalancer IP, falling back to port-forward"
    local local_port
    local_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')
    kubectl port-forward -n "${CONTROL_NAMESPACE}" \
        "svc/${CONTROLLER_SVC}" "${local_port}:8080" >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!

    local retries=0
    while ! curl -s -o /dev/null "http://127.0.0.1:${local_port}/healthz" 2>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -gt 20 ]]; then
            kill "$PORT_FORWARD_PID" 2>/dev/null || true
            fail "Port-forward failed after 10s"
        fi
        sleep 0.5
    done
    CONTROLLER_URL="http://127.0.0.1:${local_port}"
    ok "Controller: ${CONTROLLER_URL} (port-forward)"
}

api_call() {
    local method="$1" path="$2" body="${3:-}"

    if $DRY_RUN; then
        log "[DRY-RUN] ${method} ${path} ${body}"
        case "$path" in
            /api/status)    echo "{\"idle\":${BASELINE},\"pending\":0,\"active\":0,\"failed\":0,\"total\":${BASELINE},\"poolSize\":${BASELINE}}" ;;
            /api/provision) echo '{"name":"sandbox-dry-run","node":"node-1","podIP":"10.0.0.1","state":"provisioning"}' ;;
            /healthz)       echo '{"status":"ok"}' ;;
            *)              echo '{}' ;;
        esac
        return 0
    fi

    local url="${CONTROLLER_URL}${path}"
    local -a args=(-s --max-time 10 -X "${method}" -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(-d "$body")
    args+=("${url}")
    curl "${args[@]}" 2>/dev/null
}

json_field() { echo "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" 2>/dev/null; }
json_int()   { echo "$1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',0))" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Pool setup (once)
# ---------------------------------------------------------------------------
set_pool_size() {
    local target="$1"
    log "Setting warmpool → ${BOLD}${target}${NC}"
    api_call PUT "/api/pool-size" "{\"size\":${target}}" > /dev/null
}

wait_for_pool() {
    if $DRY_RUN; then ok "Pool ready (dry-run)"; return 0; fi
    local target="$1" threshold=$(( $1 * 30 / 100 ))
    log "Waiting for pool to stabilize (${threshold}/${target} idle)..."

    local wait=0
    while [[ $wait -lt 120 ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        local status idle
        status=$(api_call GET "/api/status")
        idle=$(json_int "$status" "idle")
        if (( idle >= threshold )); then
            ok "Pool ready: ${idle} idle / ${target} target"
            return 0
        fi
        if (( wait % 10 == 0 )); then
            log "Pool filling: ${idle} idle / ${target} target"
        fi
        sleep 2
        wait=$((wait + 2))
    done
    warn "Pool did not fully stabilize within 120s — continuing anyway"
}

# ---------------------------------------------------------------------------
# Claim a sandbox (what a user does)
# ---------------------------------------------------------------------------
claim_sandbox() {
    local lifetime
    lifetime=$(rand_lifetime)
    local response
    response=$(api_call POST "/api/provision" "{\"lifetime\":\"${lifetime}\"}")

    local name
    name=$(json_field "$response" "name")

    if [[ -z "$name" || "$name" == "None" ]]; then
        local err
        err=$(json_field "$response" "error")
        if [[ "$err" == *"no idle"* ]]; then
            inc_exhausted
        else
            inc_errors
            log_error "$err"
        fi
        return 1
    fi

    inc_claims
    return 0
}

# ---------------------------------------------------------------------------
# Claim N sandboxes with concurrency throttle
# ---------------------------------------------------------------------------
claim_batch() {
    local count="$1"

    if $DRY_RUN; then
        log "[DRY-RUN] Claim ${count} sandboxes (ttl: 2m–${LIFETIME})"
        return 0
    fi

    echo -e "  ${CYAN}↳ claiming ${count} sandboxes${NC} ${DIM}(ttl: 2m–${LIFETIME}, concurrency: ${CONCURRENCY})${NC}"

    local pids=()
    for ((i = 0; i < count; i++)); do
        ( claim_sandbox ) &
        pids+=($!)

        if (( ${#pids[@]} >= CONCURRENCY )); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Status display
# ---------------------------------------------------------------------------
status_line() {
    local s; s=$(api_call GET "/api/status")
    local idle pending active failed total pool_size
    idle=$(json_int "$s" "idle"); pending=$(json_int "$s" "pending")
    active=$(json_int "$s" "active"); failed=$(json_int "$s" "failed")
    total=$(json_int "$s" "total"); pool_size=$(json_int "$s" "poolSize")
    local c e x; c=$(get_claims); e=$(get_errors); x=$(get_exhausted)
    echo -e "  ${DIM}pool:${NC} ${GREEN}${idle}${NC} idle  ${YELLOW}${pending}${NC} pending  ${CYAN}${active}${NC} active  ${RED}${failed}${NC} failed  ${DIM}total:${NC} ${total}/${pool_size}  ${DIM}|${NC}  ${BOLD}${c}${NC} claimed  ${RED}${x}${NC} exhausted  ${RED}${e}${NC} err"
}

metrics_summary() {
    local m; m=$(api_call GET "/api/metrics/summary")

    echo -e "\n${BOLD}${BLUE}▸ Controller Metrics${NC}"

    local sc sa s50 s95 s99
    sc=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('count',0))" 2>/dev/null)
    sa=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('avg',0))" 2>/dev/null)
    s50=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p50',0))" 2>/dev/null)
    s95=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p95',0))" 2>/dev/null)
    s99=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('scheduleDuration',{}).get('p99',0))" 2>/dev/null)
    echo -e "  ${MAGENTA}Schedule Duration${NC} (create → Running):  count=${BOLD}${sc}${NC}  avg=${BOLD}${sa}s${NC}  p50=${s50}s  p95=${s95}s  p99=${s99}s"

    local cc ca c50 c95 c99
    cc=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('count',0))" 2>/dev/null)
    ca=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('avg',0))" 2>/dev/null)
    c50=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p50',0))" 2>/dev/null)
    c95=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p95',0))" 2>/dev/null)
    c99=$(echo "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('claimToReady',{}).get('p99',0))" 2>/dev/null)
    echo -e "  ${MAGENTA}Claim-to-Ready${NC}:  count=${BOLD}${cc}${NC}  avg=${BOLD}${ca}s${NC}  p50=${c50}s  p95=${c95}s  p99=${c99}s"
}

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
# Phases — simulate different user traffic patterns
# ---------------------------------------------------------------------------

# STEADY: light claiming, ~10 pods per tick every 1-3s
phase_steady() {
    local duration_sec="${1:-60}"
    local label="${2:-STEADY}"

    phase_banner "${label}  (${duration_sec}s)"

    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        is_expired && return

        # Claim ~10 pods per tick (organic trickle)
        local batch
        batch=$(rand_between 5 15)

        claim_batch "$batch"

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

# SURGE: claim rand(surge-min, surge-max) sandboxes, retrying until fulfilled.
# Keeps claiming in waves until the full target is met. Next phase waits.
phase_surge() {
    local target
    target=$(rand_between "$SURGE_MIN" "$SURGE_MAX")

    phase_banner "SURGE  (target: ${target} claims)"

    local claimed_before
    claimed_before=$(get_claims)
    local goal=$((claimed_before + target))
    local start_ts
    start_ts=$(date +%s)

    local max_surge_sec=120

    while true; do
        [[ "$INTERRUPTED" == "true" ]] && return
        is_expired && return

        # Bail if this single surge has been running too long
        local surge_elapsed=$(( $(date +%s) - start_ts ))
        if (( surge_elapsed > max_surge_sec )); then
            warn "Surge timed out after ${surge_elapsed}s (max ${max_surge_sec}s)"
            break
        fi

        local claimed_now
        claimed_now=$(get_claims)
        local remaining=$((goal - claimed_now))
        [[ $remaining -le 0 ]] && break

        # Check how many are available
        local status idle
        status=$(api_call GET "/api/status")
        idle=$(json_int "$status" "idle")

        if [[ $idle -lt 1 ]]; then
            local elapsed=$(( $(date +%s) - start_ts ))
            log "Pool empty — waiting for replacements... (${remaining} left, ${elapsed}s)"
            sleep 1
            continue
        fi

        # Small delay between surge batches to let controller catch up
        sleep 0.2

        # Claim up to what's available
        local to_claim=$remaining
        [[ $to_claim -gt $idle ]] && to_claim=$idle

        claim_batch "$to_claim"
    done

    local claimed_total=$(( $(get_claims) - claimed_before ))
    local elapsed=$(( $(date +%s) - start_ts ))
    ok "Surge complete: ${claimed_total}/${target} claimed in ${elapsed}s"
    status_line
    node_summary
}

# SPIKE: claim surge-max all at once (flash crowd — fire and forget, no retry)
phase_spike() {
    local target="$SURGE_MAX"
    phase_banner "SPIKE  (${target} claims at once — no retry)"
    log "🔥 Flash crowd: ${target} simultaneous claims"
    claim_batch "$target"
    status_line
}

# QUIET: near-zero traffic, observe pool recovery
phase_quiet() {
    local duration_sec="${1:-30}"

    phase_banner "QUIET  (${duration_sec}s, pool recovery)"

    local elapsed=0
    while [[ $elapsed -lt $duration_sec ]]; do
        [[ "$INTERRUPTED" == "true" ]] && return
        is_expired && return

        # Occasional trickle (0-2 claims per tick)
        local trickle
        trickle=$(rand_between 0 2)
        if [[ $trickle -gt 0 ]]; then
            claim_batch "$trickle"
        fi

        sleep 1
        elapsed=$((elapsed + 1))

        if (( elapsed % 10 == 0 )); then
            status_line
        fi
    done
    status_line
    node_summary
}

# ---------------------------------------------------------------------------
# Deterministic cycle (10-minute repeating pattern)
# ---------------------------------------------------------------------------
run_deterministic_cycle() {
    local cycle_num="$1" total="$2"

    sep
    echo -e "${BOLD}${CYAN} CYCLE ${cycle_num}/${total}${NC}"
    sep

    phase_steady   60  "WARMUP"          #  0:00 -  1:00
    phase_surge                          #  ~1:00
    phase_quiet    30                    #  1:00 -  1:30  recovery
    phase_steady   60  "STEADY"          #  1:30 -  2:30
    phase_spike                          #  ~2:30  flash crowd
    phase_quiet    60                    #  2:30 -  3:30  recovery
    phase_surge                          #  ~3:30  another surge
    phase_surge                          #  ~3:30  back-to-back
    phase_quiet    30                    #  3:30 -  4:00  recovery
    phase_steady   120 "COOL DOWN"       #  4:00 -  6:00
    phase_quiet    60                    #  6:00 -  7:00
    phase_steady   120 "STEADY"          #  7:00 -  9:00
    phase_quiet    60                    #  9:00 - 10:00

    echo -e "\n${BOLD}${GREEN}  ✓ Cycle ${cycle_num} complete${NC}"
    echo -e "  Claims: ${BOLD}$(get_claims)${NC}  Exhausted: ${RED}$(get_exhausted)${NC}  Errors: ${RED}$(get_errors)${NC}"
}

# ---------------------------------------------------------------------------
# Random mode: organic traffic
# ---------------------------------------------------------------------------
run_random() {
    while true; do
        [[ "$INTERRUPTED" == "true" ]] && break
        is_expired && break

        local roll
        roll=$(rand_between 1 100)

        if [[ $roll -le 30 ]]; then
            # 30%: steady traffic
            phase_steady $(rand_between 30 90)
        elif [[ $roll -le 55 ]]; then
            # 25%: surge
            phase_surge
        elif [[ $roll -le 70 ]]; then
            # 15%: double surge (back-to-back)
            phase_surge
            phase_surge
        elif [[ $roll -le 80 ]]; then
            # 10%: spike
            phase_spike
        else
            # 20%: quiet (recovery)
            phase_quiet $(rand_between 15 60)
        fi

        sleep $(rand_between 1 5)
    done
}

# ---------------------------------------------------------------------------
# Background steady drip — 1-3 claims every 2-5s, always running
# ---------------------------------------------------------------------------
DRIP_PID=""

steady_drip() {
    local max_drip=3
    while true; do
        [[ "$INTERRUPTED" == "true" ]] && return
        is_expired && return
        local batch
        batch=$(rand_between 1 "$max_drip")
        claim_batch "$batch" > /dev/null 2>&1
        sleep $(rand_between 2 5)
    done
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
INTERRUPTED=false
TIMER_PID=""
BENCH_START_EPOCH=$(date +%s)

cleanup() {
    [[ "$INTERRUPTED" == "true" ]] && return
    INTERRUPTED=true
    echo ""
    warn "Interrupt received"
    phase_banner "SHUTDOWN"

    [[ -n "$TIMER_PID" ]] && kill "$TIMER_PID" 2>/dev/null
    [[ -n "$DRIP_PID" ]] && kill "$DRIP_PID" 2>/dev/null

    metrics_summary

    local claims errors exhausted
    claims=$(get_claims); errors=$(get_errors); exhausted=$(get_exhausted)
    local elapsed_sec=$(( $(date +%s) - BENCH_START_EPOCH ))
    local elapsed_min=$(( elapsed_sec / 60 ))
    local total_attempts=$((claims + errors + exhausted))
    local claims_per_min=0
    [[ $elapsed_min -gt 0 ]] && claims_per_min=$(( claims / elapsed_min ))

    local error_rate=0 exhaust_rate=0
    if [[ $total_attempts -gt 0 ]]; then
        error_rate=$(python3 -c "print(round(${errors}/${total_attempts}*100, 1))" 2>/dev/null || echo "0")
        exhaust_rate=$(python3 -c "print(round(${exhausted}/${total_attempts}*100, 1))" 2>/dev/null || echo "0")
    fi

    echo ""
    echo -e "${BOLD}${BLUE}▸ Benchmark Stats${NC}"
    echo -e "  Duration:             ${BOLD}${elapsed_min}m (${elapsed_sec}s)${NC}"
    echo -e "  Total claims:         ${BOLD}${claims}${NC} (${claims_per_min}/min)"
    echo -e "  Pool exhaustions:     ${BOLD}${exhausted}${NC} (${exhaust_rate}%)"
    echo -e "  Errors:               ${BOLD}${errors}${NC} (${error_rate}%)"

    # Scale pool to 0
    set_pool_size 0

    # Cleanup
    [[ -n "$PORT_FORWARD_PID" ]] && kill "$PORT_FORWARD_PID" 2>/dev/null || true
    pkill -P $$ 2>/dev/null; wait 2>/dev/null
    rm -rf "${COUNT_DIR}" 2>/dev/null

    local end_ts; end_ts="$(date '+%Y%m%d-%H%M%S')"
    local log_final="${LOG_DIR}/benchmark_${START_TS}_${end_ts}.log"

    cat <<FOOTER

════════════════════════════════════════════════════════════════════════════
 BENCHMARK COMPLETE
 Ended:        $(date '+%Y-%m-%d %H:%M:%S %Z')
 Duration:     ${elapsed_min}m
 Pool:         ${BASELINE} (baseline)
 Claims:       ${claims} (${claims_per_min}/min)
 Exhaustions:  ${exhausted} (${exhaust_rate}%)
 Errors:       ${errors} (${error_rate}%)
════════════════════════════════════════════════════════════════════════════
FOOTER

    mv "${LOG_TMP}" "${log_final}" 2>/dev/null || true
    echo "Log saved: ${log_final}" >&2
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
    command -v curl >/dev/null 2>&1    || fail "curl not found"

    kubectl get namespace "${CONTROL_NAMESPACE}" >/dev/null 2>&1 || \
        fail "Namespace '${CONTROL_NAMESPACE}' not found"

    resolve_controller

    local health status
    health=$(api_call GET "/healthz")
    status=$(json_field "$health" "status")
    if [[ "$status" != "ok" ]]; then
        fail "Controller health check failed: ${health}"
    fi
    ok "Controller healthy"

    local pool_status; pool_status=$(api_call GET "/api/status")
    log "Current pool: $(json_int "$pool_status" "idle") idle / $(json_int "$pool_status" "poolSize") target"

    ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode_label="random"
    $DETERMINISTIC && mode_label="deterministic (10-min cycles)"

    cat <<EOF
════════════════════════════════════════════════════════════════════════════
 SANDBOX CONTROLLER BENCHMARK
 Started:    $(date '+%Y-%m-%d %H:%M:%S %Z')
 Duration:   ${DURATION_MIN} min
 Mode:       ${mode_label}
 Baseline:   ${BASELINE} pods (warmpool size)
 Surge:      ${SURGE_MIN}–${SURGE_MAX} claims per phase
 Lifetime:   2m–${LIFETIME} (random TTL per sandbox)
 Concurrency: ${CONCURRENCY} parallel requests
════════════════════════════════════════════════════════════════════════════

EOF

    preflight

    log "Resetting controller metrics..."
    api_call POST "/api/metrics/reset" > /dev/null

    # Set warmpool to baseline (once)
    phase_banner "WARMUP"
    set_pool_size "${BASELINE}"
    wait_for_pool "${BASELINE}"

    # Start timer
    (
        sleep "${DURATION_SEC}"
        kill -TERM $$ 2>/dev/null
    ) &
    TIMER_PID=$!
    log "Benchmark started — will stop in ${DURATION_MIN} minutes (mode: ${mode_label})"

    # Start background steady drip (1-3 claims every 2-5s, always running)
    steady_drip &
    DRIP_PID=$!
    log "Steady drip started (1–3 claims every 2-5s, PID ${DRIP_PID})"

    if $DETERMINISTIC; then
        local cycle=0
        while true; do
            [[ "$INTERRUPTED" == "true" ]] && break
            is_expired && break
            cycle=$((cycle + 1))
            run_deterministic_cycle "$cycle" "∞"
        done
    else
        run_random
    fi

    cleanup
}

main "$@"
