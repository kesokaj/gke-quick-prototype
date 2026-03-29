#!/usr/bin/env bash
#
# Sandbox Warmpool Detach & Lifecycle Test
#
# Verifies the complete sandbox lifecycle end-to-end:
#
#   1. Controller health & readiness
#   2. Pool status (idle sandboxes available)
#   3. Provision / detach via API (warmpool=true → false)
#   4. Deployment self-heals (creates replacement pod)
#   5. Provisioned pod transitions: idle → provisioning → active
#   6. Sandbox pod detects detach (label file) and starts workload
#   7. Delete provisioned sandbox via API
#   8. Pool returns to target size
#
# This test is deterministic — no random behavior. It exercises exactly
# one provision + detach + delete cycle and asserts at each step.
#
# Usage:
#   ./test-sandbox-lifecycle.sh                Run against live cluster
#   ./test-sandbox-lifecycle.sh --namespace X  Override namespace
#   ./test-sandbox-lifecycle.sh --help         Show options
#

set -uo pipefail

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*" >&2; }
fail()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ FAIL:${NC} $*" >&2; FAILURES=$((FAILURES + 1)); }
fatal() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ FATAL:${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}━━━ STEP $1: $2 ━━━${NC}"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-sandbox}"
CONTROL_NAMESPACE="${CONTROL_NAMESPACE:-sandbox-control}"
CONTROLLER_SVC="${CONTROLLER_SVC:-sandbox-controller}"
DEPLOYMENT="${DEPLOYMENT:-sandbox-pool}"
LABEL_SELECTOR="managed-by=warmpool,warmpool=true"

# Timeouts
WAIT_TIMEOUT=120        # Max seconds to wait for a condition
POLL_INTERVAL=3         # Seconds between polls
RECONCILE_WAIT=10       # Seconds to wait for reconciler sync

FAILURES=0
TESTS=0
PROVISIONED_NAME=""     # Filled after provision
BASELINE_ACTIVE=0       # Active count before provisioning

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)       NAMESPACE="$2"; shift 2 ;;
        --control-ns)      CONTROL_NAMESPACE="$2"; shift 2 ;;
        --deployment)      DEPLOYMENT="$2"; shift 2 ;;
        --timeout)         WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            head -25 "$0" | tail -23
            echo ""
            echo "Flags:"
            echo "  --namespace NS     Sandbox namespace (default: sandbox)"
            echo "  --control-ns NS    Controller namespace (default: sandbox-control)"
            echo "  --deployment NAME  Pool deployment name (default: sandbox-pool)"
            echo "  --timeout SECS     Wait timeout per step (default: 120)"
            exit 0
            ;;
        *) fatal "Unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        ok "ASSERT: ${label} == ${expected}"
    else
        fail "ASSERT: ${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_ge() {
    local label="$1" min="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$actual" -ge "$min" ]]; then
        ok "ASSERT: ${label} >= ${min} (got ${actual})"
    else
        fail "ASSERT: ${label}: expected >= ${min}, got '${actual}'"
    fi
}

assert_not_empty() {
    local label="$1" value="$2"
    TESTS=$((TESTS + 1))
    if [[ -n "$value" ]]; then
        ok "ASSERT: ${label} is not empty (${value})"
    else
        fail "ASSERT: ${label} is empty"
    fi
}

# Get controller ClusterIP for curl
controller_url() {
    local ip
    ip=$(kubectl get svc "${CONTROLLER_SVC}" -n "${CONTROL_NAMESPACE}" \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    echo "http://${ip}:8080"
}

# Call controller API from inside the cluster using a curl pod
api_call() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local url
    url="$(controller_url)${path}"

    local -a curl_cmd=(curl -s -X "${method}" -H "Content-Type: application/json")
    [[ -n "$body" ]] && curl_cmd+=(-d "$body")
    curl_cmd+=("${url}")

    kubectl run --rm -i --restart=Never --image=curlimages/curl:latest \
        "test-curl-$(date +%s)" -n "${CONTROL_NAMESPACE}" \
        --command -- "${curl_cmd[@]}" 2>/dev/null | grep -v "^pod "
}

# Wait for a condition with timeout
wait_for() {
    local label="$1"
    local check_cmd="$2"
    local timeout="${3:-$WAIT_TIMEOUT}"

    log "Waiting for: ${label} (timeout: ${timeout}s)"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$check_cmd" >/dev/null 2>&1; then
            ok "Condition met: ${label} (${elapsed}s)"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    fail "Timeout waiting for: ${label} after ${timeout}s"
    return 1
}

# Get JSON field from controller API
api_field() {
    local path="$1" field="$2"
    api_call GET "$path" | python3 -c "import json,sys; print(json.load(sys.stdin).get('${field}',''))" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    command -v kubectl >/dev/null 2>&1 || fatal "kubectl not found"
    command -v python3 >/dev/null 2>&1 || fatal "python3 not found"

    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || \
        fatal "Namespace '${NAMESPACE}' not found"
    kubectl get namespace "${CONTROL_NAMESPACE}" >/dev/null 2>&1 || \
        fatal "Namespace '${CONTROL_NAMESPACE}' not found"
    kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1 || \
        fatal "Deployment '${DEPLOYMENT}' not found in '${NAMESPACE}'"
    kubectl get svc "${CONTROLLER_SVC}" -n "${CONTROL_NAMESPACE}" >/dev/null 2>&1 || \
        fatal "Service '${CONTROLLER_SVC}' not found in '${CONTROL_NAMESPACE}'"

    ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# STEP 1: Controller Health
# ---------------------------------------------------------------------------
test_controller_health() {
    step 1 "Controller Health"

    # Check controller pods are running
    local ready
    ready=$(kubectl get pods -n "${CONTROL_NAMESPACE}" -l app=sandbox-controller \
        --no-headers 2>/dev/null | grep -c "Running")
    assert_ge "Controller pods running" 1 "$ready"

    # Check /healthz
    local health
    health=$(api_call GET "/healthz")
    local status
    status=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    assert_eq "Controller /healthz" "ok" "$status"
}

# ---------------------------------------------------------------------------
# STEP 2: Pool Status (pre-provision)
# ---------------------------------------------------------------------------
test_pool_status() {
    step 2 "Pool Status (pre-provision)"

    local status_json
    status_json=$(api_call GET "/api/status")
    log "Status: ${status_json}"

    local idle total pool_size
    idle=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('idle',0))" 2>/dev/null)
    total=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" 2>/dev/null)
    pool_size=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('poolSize',0))" 2>/dev/null)

    assert_ge "Pool size" 1 "$pool_size"
    assert_ge "Total sandboxes" 1 "$total"
    assert_ge "Idle sandboxes" 1 "$idle"

    # Verify pod labels: all warmpool pods should have warmpool=true
    local warmpool_true
    warmpool_true=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    assert_ge "Pods with warmpool=true" 1 "$warmpool_true"

    # Capture baseline active count
    BASELINE_ACTIVE=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',0))" 2>/dev/null)
    log "Baseline active: ${BASELINE_ACTIVE}"
}

# ---------------------------------------------------------------------------
# STEP 3: Provision (Detach) via API
# ---------------------------------------------------------------------------
test_provision() {
    step 3 "Provision (Detach via API)"

    # Record pre-provision state
    local pre_idle pre_active
    pre_idle=$(api_call GET "/api/status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('idle',0))" 2>/dev/null)
    pre_active=$(api_call GET "/api/status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',0))" 2>/dev/null)
    log "Pre-provision: idle=${pre_idle}, active=${pre_active}"

    # Provision a sandbox
    local provision_response
    provision_response=$(api_call POST "/api/provision" '{"lifetime":"5m"}')
    log "Provision response: ${provision_response}"

    PROVISIONED_NAME=$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
    local prov_state prov_ip prov_node
    prov_state=$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
    prov_ip=$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('podIP',''))" 2>/dev/null || echo "")
    prov_node=$(echo "$provision_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('node',''))" 2>/dev/null || echo "")

    assert_not_empty "Provisioned pod name" "$PROVISIONED_NAME"
    assert_eq "Provision state" "provisioning" "$prov_state"
    assert_not_empty "Provisioned pod IP" "$prov_ip"
    assert_not_empty "Provisioned pod node" "$prov_node"

    # Verify label changed
    log "Verifying warmpool label on ${PROVISIONED_NAME}..."
    local label_val
    label_val=$(kubectl get pod "${PROVISIONED_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.labels.warmpool}' 2>/dev/null)
    assert_eq "Pod label warmpool" "false" "$label_val"

    # Verify annotation
    local state_annotation
    state_annotation=$(kubectl get pod "${PROVISIONED_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.annotations.sandbox\.gvisor/state}' 2>/dev/null)
    assert_eq "Pod annotation state" "claimed" "$state_annotation"
}

# ---------------------------------------------------------------------------
# STEP 4: Verify Detach — Deployment Self-Heals
# ---------------------------------------------------------------------------
test_deployment_self_heal() {
    step 4 "Deployment Self-Heals (replacement pod created)"

    # The provisioned pod is no longer matched by the Deployment selector,
    # so K8s should create a replacement. Wait for it.
    local target_replicas
    target_replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)
    log "Deployment target: ${target_replicas} replicas"

    wait_for "Deployment has ${target_replicas} selector-matching pods" \
        "[[ \$(kubectl get pods -n '${NAMESPACE}' -l '${LABEL_SELECTOR}' --no-headers 2>/dev/null | grep -c Running) -ge ${target_replicas} ]]" \
        "$WAIT_TIMEOUT"

    # Count total pods: should be target + 1 orphan
    local total_pods
    total_pods=$(kubectl get pods -n "${NAMESPACE}" -l "managed-by=warmpool" \
        --no-headers 2>/dev/null | grep -c "Running")
    assert_ge "Total running pods (target + orphan)" $((target_replicas + 1)) "$total_pods"

    # The orphan should still be running (detached but alive)
    local orphan_phase
    orphan_phase=$(kubectl get pod "${PROVISIONED_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    assert_eq "Orphaned pod still Running" "Running" "$orphan_phase"
}

# ---------------------------------------------------------------------------
# STEP 5: Controller Reconciler Tracks Active State
# ---------------------------------------------------------------------------
test_reconciler_state() {
    step 5 "Reconciler Tracks Active State"

    # Wait for reconciler to pick up the change
    log "Waiting ${RECONCILE_WAIT}s for reconciler sync..."
    sleep "$RECONCILE_WAIT"

    # Check via API that the provisioned sandbox is active
    local sb_json sb_state
    sb_json=$(api_call GET "/api/sandboxes/${PROVISIONED_NAME}")
    log "Sandbox detail: ${sb_json}"

    sb_state=$(echo "$sb_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || echo "")
    assert_eq "Sandbox state in controller" "active" "$sb_state"

    # Verify status counts changed
    local post_status post_active
    post_status=$(api_call GET "/api/status")
    post_active=$(echo "$post_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',0))" 2>/dev/null)
    assert_ge "Active count after provision" 1 "$post_active"
}

# ---------------------------------------------------------------------------
# STEP 6: Sandbox Pod Detects Detach & Activates Workload
# ---------------------------------------------------------------------------
test_sandbox_detach_detection() {
    step 6 "Sandbox Pod Detects Detach"

    # The sandbox pod watches /etc/podinfo/labels for warmpool=false.
    # When it sees the change, it logs "detached from warm pool" and starts the workload.
    # Wait for the pod logs to show it got the detach signal.
    log "Checking pod logs for detach signal..."

    wait_for "Sandbox pod detects detach" \
        "kubectl logs '${PROVISIONED_NAME}' -n '${NAMESPACE}' 2>/dev/null | grep -q 'detached from warm pool\|controller owns lifetime\|PHASE 1\|PHASE 2\|PHASE 3'" \
        60

    # Verify the pod started its workload phases
    local has_scenario
    has_scenario=$(kubectl logs "${PROVISIONED_NAME}" -n "${NAMESPACE}" --tail=100 2>/dev/null \
        | grep -c "SCENARIO\|PHASE\|download\|disk\|load" || echo "0")
    assert_ge "Sandbox workload phase logs found" 1 "$has_scenario"
}

# ---------------------------------------------------------------------------
# STEP 7: Delete Provisioned Sandbox
# ---------------------------------------------------------------------------
test_delete_sandbox() {
    step 7 "Delete Provisioned Sandbox"

    local delete_response
    delete_response=$(api_call DELETE "/api/sandboxes/${PROVISIONED_NAME}")
    log "Delete response: ${delete_response}"

    local deleted
    deleted=$(echo "$delete_response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('deleted',False))" 2>/dev/null || echo "")
    assert_eq "Sandbox deleted" "True" "$deleted"

    # Wait for pod to be gone
    wait_for "Pod ${PROVISIONED_NAME} terminated" \
        "! kubectl get pod '${PROVISIONED_NAME}' -n '${NAMESPACE}' >/dev/null 2>&1" \
        30
}

# ---------------------------------------------------------------------------
# STEP 8: Pool Recovery — Returns to Target Size
# ---------------------------------------------------------------------------
test_pool_recovery() {
    step 8 "Pool Recovery"

    local target_replicas
    target_replicas=$(kubectl get deployment "${DEPLOYMENT}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)

    # Wait for the pool to return to target size with all pods Ready
    wait_for "Pool back at target (${target_replicas} Ready)" \
        "[[ \$(kubectl get pods -n '${NAMESPACE}' -l '${LABEL_SELECTOR}' --no-headers 2>/dev/null | grep -c Running) -ge ${target_replicas} ]]" \
        "$WAIT_TIMEOUT"

    # Verify controller status
    log "Waiting ${RECONCILE_WAIT}s for reconciler sync..."
    sleep "$RECONCILE_WAIT"

    local final_status idle active
    final_status=$(api_call GET "/api/status")
    log "Final status: ${final_status}"

    idle=$(echo "$final_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('idle',0))" 2>/dev/null)
    active=$(echo "$final_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active',0))" 2>/dev/null)

    assert_ge "Pool idle count" 1 "$idle"
    assert_eq "Active count back to baseline" "${BASELINE_ACTIVE}" "$active"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  Sandbox Warmpool Lifecycle Test                          ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "  Namespace:    ${BOLD}${NAMESPACE}${NC}"
    echo -e "  Controller:   ${BOLD}${CONTROL_NAMESPACE}/${CONTROLLER_SVC}${NC}"
    echo -e "  Deployment:   ${BOLD}${DEPLOYMENT}${NC}"
    echo -e "  Timeout:      ${WAIT_TIMEOUT}s per step"
    echo ""

    preflight

    test_controller_health
    test_pool_status
    test_provision
    test_deployment_self_heal
    test_reconciler_state
    test_sandbox_detach_detection
    test_delete_sandbox
    test_pool_recovery

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}  ALL ${TESTS} TESTS PASSED${NC}"
    else
        echo -e "${BOLD}${RED}  ${FAILURES}/${TESTS} TESTS FAILED${NC}"
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    exit "$FAILURES"
}

main "$@"
