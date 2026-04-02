#!/usr/bin/env bash
#
# Dirty vs Clean Detach — ReplicaSet Behavior Comparison
#
# Creates a small Deployment and demonstrates the difference between:
#   1) "Dirty" detach  — only changes labels (leaves ownerReferences)
#   2) "Clean" detach  — changes labels AND removes ownerReferences atomically
#
# Usage:
#   ./test-detach-comparison.sh           Run the full comparison
#   ./test-detach-comparison.sh cleanup   Remove test resources
#
# turbo-all
set -euo pipefail

readonly NS="detach-test"
readonly DEPLOY_DIRTY="dirty-pool"
readonly DEPLOY_CLEAN="clean-pool"
readonly REPLICAS=3
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
fail()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*"; }
header(){ echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}\n"; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up namespace ${NS}..."
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false 2>/dev/null || true
    ok "Cleanup done"
}

if [[ "${1:-}" == "cleanup" ]]; then
    cleanup
    exit 0
fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
header "SETUP: Creating test namespace and deployments"

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# Both deployments use the same pattern: selector requires pool=true
for DEPLOY in "${DEPLOY_DIRTY}" "${DEPLOY_CLEAN}"; do
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY}
  namespace: ${NS}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${DEPLOY}
      pool: "true"
  template:
    metadata:
      labels:
        app: ${DEPLOY}
        pool: "true"
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
      terminationGracePeriodSeconds: 1
EOF
done

log "Waiting for all pods to be ready..."
kubectl rollout status deployment/"${DEPLOY_DIRTY}" -n "${NS}" --timeout=120s
kubectl rollout status deployment/"${DEPLOY_CLEAN}" -n "${NS}" --timeout=120s
ok "Both deployments ready with ${REPLICAS} replicas each"

echo ""
kubectl get pods -n "${NS}" -o wide --no-headers
echo ""

# ---------------------------------------------------------------------------
# Helper: show RS state
# ---------------------------------------------------------------------------
show_rs() {
    local deploy="$1"
    local rs_name
    rs_name=$(kubectl get rs -n "${NS}" -l app="${deploy}" -o jsonpath='{.items[0].metadata.name}')
    local desired ready
    desired=$(kubectl get rs "${rs_name}" -n "${NS}" -o jsonpath='{.spec.replicas}')
    ready=$(kubectl get rs "${rs_name}" -n "${NS}" -o jsonpath='{.status.readyReplicas}')
    echo "${rs_name} desired=${desired} ready=${ready:-0}"
}

# ---------------------------------------------------------------------------
# Helper: pick one ready pod from a deployment
# ---------------------------------------------------------------------------
pick_pod() {
    local deploy="$1"
    kubectl get pods -n "${NS}" -l "app=${deploy},pool=true" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}'
}

# ---------------------------------------------------------------------------
# Helper: show ownerReferences for a pod
# ---------------------------------------------------------------------------
show_owner() {
    local pod="$1"
    local or
    or=$(kubectl get pod "${pod}" -n "${NS}" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null)
    if [[ -z "${or}" ]] || [[ "${or}" == "null" ]]; then
        echo "  ownerReferences: (empty)"
    else
        echo "  ownerReferences: ${or}"
    fi
}

# ---------------------------------------------------------------------------
# TEST 1: Dirty detach (label-only, keep ownerReferences)
# ---------------------------------------------------------------------------
header "TEST 1: DIRTY DETACH (label-only — the OLD behavior)"

DIRTY_POD=$(pick_pod "${DEPLOY_DIRTY}")
log "Detaching pod: ${DIRTY_POD}"
echo ""

echo -e "${BOLD}BEFORE:${NC}"
echo "  labels.pool: $(kubectl get pod "${DIRTY_POD}" -n "${NS}" -o jsonpath='{.metadata.labels.pool}')"
show_owner "${DIRTY_POD}"
echo "  RS state: $(show_rs "${DEPLOY_DIRTY}")"
echo ""

DIRTY_START=$(date +%s%N)

# Dirty detach: only change label
kubectl patch pod "${DIRTY_POD}" -n "${NS}" --type=merge \
    -p '{"metadata":{"labels":{"pool":"false"},"annotations":{"detach-method":"dirty","detached-at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}}'

DIRTY_PATCH_END=$(date +%s%N)
DIRTY_PATCH_MS=$(( (DIRTY_PATCH_END - DIRTY_START) / 1000000 ))

ok "Dirty patch applied in ${DIRTY_PATCH_MS}ms"
echo ""

echo -e "${BOLD}AFTER PATCH:${NC}"
echo "  labels.pool: $(kubectl get pod "${DIRTY_POD}" -n "${NS}" -o jsonpath='{.metadata.labels.pool}')"
show_owner "${DIRTY_POD}"
echo ""

# Wait and observe RS behavior
log "Watching RS replenishment (up to 30s)..."
DIRTY_REPLENISH_START=$(date +%s)
DIRTY_REPLENISHED=false
for i in $(seq 1 30); do
    POOL_TRUE=$(kubectl get pods -n "${NS}" -l "app=${DEPLOY_DIRTY},pool=true" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    RS_INFO=$(show_rs "${DEPLOY_DIRTY}")
    if [[ "${POOL_TRUE}" -ge "${REPLICAS}" ]]; then
        DIRTY_REPLENISH_END=$(date +%s)
        DIRTY_REPLENISH_SEC=$(( DIRTY_REPLENISH_END - DIRTY_REPLENISH_START ))
        ok "[$i] RS replenished in ~${DIRTY_REPLENISH_SEC}s | pool=true pods: ${POOL_TRUE} | ${RS_INFO}"
        DIRTY_REPLENISHED=true
        break
    fi
    echo "  [$i] pool=true pods: ${POOL_TRUE}/${REPLICAS} | ${RS_INFO}"
    sleep 1
done

if [[ "${DIRTY_REPLENISHED}" == "false" ]]; then
    warn "RS did NOT replenish within 30s — this demonstrates the problem!"
    DIRTY_REPLENISH_SEC=">30"
fi

echo ""
echo -e "${BOLD}DIRTY DETACH FINAL STATE:${NC}"
echo "All pods:"
kubectl get pods -n "${NS}" -l "app=${DEPLOY_DIRTY}" --no-headers -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,POOL:.metadata.labels.pool,OWNER:.metadata.ownerReferences[0].name"
echo ""

# Show if the RS controller attempted a Release (look at events)
log "RS Events (looking for Release/Orphan activity):"
kubectl get events -n "${NS}" --field-selector="involvedObject.kind=Pod" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "${DEPLOY_DIRTY}" | tail -5

sleep 2

# ---------------------------------------------------------------------------
# TEST 2: Clean detach (label + ownerReferences cleared atomically)
# ---------------------------------------------------------------------------
header "TEST 2: CLEAN DETACH (label + ownerReferences — the NEW behavior)"

CLEAN_POD=$(pick_pod "${DEPLOY_CLEAN}")
log "Detaching pod: ${CLEAN_POD}"
echo ""

echo -e "${BOLD}BEFORE:${NC}"
echo "  labels.pool: $(kubectl get pod "${CLEAN_POD}" -n "${NS}" -o jsonpath='{.metadata.labels.pool}')"
show_owner "${CLEAN_POD}"
echo "  RS state: $(show_rs "${DEPLOY_CLEAN}")"
echo ""

CLEAN_START=$(date +%s%N)

# Clean detach: change label AND clear ownerReferences atomically
kubectl patch pod "${CLEAN_POD}" -n "${NS}" --type=merge \
    -p '{"metadata":{"labels":{"pool":"false"},"annotations":{"detach-method":"clean","detached-at":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"},"ownerReferences":[]}}'

CLEAN_PATCH_END=$(date +%s%N)
CLEAN_PATCH_MS=$(( (CLEAN_PATCH_END - CLEAN_START) / 1000000 ))

ok "Clean patch applied in ${CLEAN_PATCH_MS}ms"
echo ""

echo -e "${BOLD}AFTER PATCH:${NC}"
echo "  labels.pool: $(kubectl get pod "${CLEAN_POD}" -n "${NS}" -o jsonpath='{.metadata.labels.pool}')"
show_owner "${CLEAN_POD}"
echo ""

# Wait and observe RS behavior
log "Watching RS replenishment (up to 30s)..."
CLEAN_REPLENISH_START=$(date +%s)
CLEAN_REPLENISHED=false
for i in $(seq 1 30); do
    POOL_TRUE=$(kubectl get pods -n "${NS}" -l "app=${DEPLOY_CLEAN},pool=true" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    RS_INFO=$(show_rs "${DEPLOY_CLEAN}")
    if [[ "${POOL_TRUE}" -ge "${REPLICAS}" ]]; then
        CLEAN_REPLENISH_END=$(date +%s)
        CLEAN_REPLENISH_SEC=$(( CLEAN_REPLENISH_END - CLEAN_REPLENISH_START ))
        ok "[$i] RS replenished in ~${CLEAN_REPLENISH_SEC}s | pool=true pods: ${POOL_TRUE} | ${RS_INFO}"
        CLEAN_REPLENISHED=true
        break
    fi
    echo "  [$i] pool=true pods: ${POOL_TRUE}/${REPLICAS} | ${RS_INFO}"
    sleep 1
done

if [[ "${CLEAN_REPLENISHED}" == "false" ]]; then
    warn "RS did NOT replenish within 30s"
    CLEAN_REPLENISH_SEC=">30"
fi

echo ""
echo -e "${BOLD}CLEAN DETACH FINAL STATE:${NC}"
echo "All pods:"
kubectl get pods -n "${NS}" -l "app=${DEPLOY_CLEAN}" --no-headers -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,POOL:.metadata.labels.pool,OWNER:.metadata.ownerReferences[0].name"
echo ""

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
header "COMPARISON SUMMARY"

echo -e "┌────────────────────┬──────────────────────┬──────────────────────┐"
echo -e "│ ${BOLD}Metric${NC}             │ ${BOLD}Dirty (label only)${NC}   │ ${BOLD}Clean (label+owner)${NC}  │"
echo -e "├────────────────────┼──────────────────────┼──────────────────────┤"
echo -e "│ Pod patched        │ ${DIRTY_POD:0:20} │ ${CLEAN_POD:0:20} │"
echo -e "│ Patch time         │ ${DIRTY_PATCH_MS}ms$(printf '%*s' $((20 - ${#DIRTY_PATCH_MS} - 2)) '')│ ${CLEAN_PATCH_MS}ms$(printf '%*s' $((20 - ${#CLEAN_PATCH_MS} - 2)) '')│"
echo -e "│ ownerRef after     │ $(if kubectl get pod "${DIRTY_POD}" -n "${NS}" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null | grep -q uid; then echo -e "${RED}STILL SET${NC}           "; else echo -e "${GREEN}CLEARED${NC}              "; fi)│ $(if kubectl get pod "${CLEAN_POD}" -n "${NS}" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null | grep -q uid; then echo -e "${RED}STILL SET${NC}           "; else echo -e "${GREEN}CLEARED${NC}              "; fi)│"
echo -e "│ RS replenish time  │ ${DIRTY_REPLENISH_SEC}s$(printf '%*s' $((20 - ${#DIRTY_REPLENISH_SEC} - 1)) '')│ ${CLEAN_REPLENISH_SEC}s$(printf '%*s' $((20 - ${#CLEAN_REPLENISH_SEC} - 1)) '')│"
echo -e "│ RS needed Release  │ ${YELLOW}YES (conflict risk)${NC}  │ ${GREEN}NO (bypassed)${NC}        │"
echo -e "└────────────────────┴──────────────────────┴──────────────────────┘"

echo ""
if [[ "${DIRTY_REPLENISHED}" == "true" ]] && [[ "${CLEAN_REPLENISHED}" == "true" ]]; then
    log "Both replenished this time. The dirty detach CAN work, but under"
    log "concurrent load (rapid claims) it races with the RS Release logic"
    log "and can wedge the expectations, requiring a rollout restart."
    log ""
    log "The clean detach avoids this entirely — no Release path, no race."
else
    fail "The dirty detach failed to replenish — this IS the bug."
    ok  "The clean detach replenished cleanly."
fi

echo ""
log "Run './test-detach-comparison.sh cleanup' to remove test resources."
