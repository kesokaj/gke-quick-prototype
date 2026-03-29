#!/usr/bin/env bash
# =============================================================================
# monitor-cilium-identity.sh — Watch Cilium identity churn on sandbox pods
# =============================================================================
#
# Monitors:
#   1. Pod label changes (warmpool=true → false) in the sandbox namespace
#   2. CiliumIdentity count over time
#   3. CiliumEndpoint identity changes and regeneration events
#
# Usage:
#   ./monitor-cilium-identity.sh              # Run all monitors
#   ./monitor-cilium-identity.sh identities   # Just watch identity count
#   ./monitor-cilium-identity.sh labels       # Just watch label changes
#   ./monitor-cilium-identity.sh endpoints    # Just watch endpoint regeneration
#   ./monitor-cilium-identity.sh snapshot     # One-time snapshot
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

NAMESPACE="sandbox"

log()  { echo -e "${DIM}$(date '+%H:%M:%S')${RESET} $*"; }
info() { log "${CYAN}ℹ${RESET} $*"; }
warn() { log "${YELLOW}⚠${RESET} $*"; }
ok()   { log "${GREEN}✔${RESET} $*"; }
err()  { log "${RED}✘${RESET} $*"; }

# ---------------------------------------------------------------------------
# Snapshot: one-time view of current state
# ---------------------------------------------------------------------------
snapshot() {
    echo ""
    echo -e "${BOLD}━━━ Cilium Identity Snapshot ━━━${RESET}"
    echo ""

    # Total identity count.
    local total
    total=$(kubectl get ciliumidentity --no-headers 2>/dev/null | wc -l | tr -d ' ')
    info "Total CiliumIdentities: ${BOLD}${total}${RESET}"

    # Sandbox-specific identities.
    echo ""
    echo -e "${BOLD}Sandbox identities:${RESET}"
    kubectl get ciliumidentity -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.security-labels}{"\n"}{end}' 2>/dev/null \
        | grep -E 'warmpool|is-sandbox' \
        | while IFS=$'\t' read -r id labels; do
            # Extract warmpool value.
            local wp
            wp=$(echo "${labels}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('k8s:warmpool','?'))" 2>/dev/null || echo "?")
            if [[ "${wp}" == "true" ]]; then
                echo -e "  ${GREEN}●${RESET} Identity ${BOLD}${id}${RESET} → warmpool=${GREEN}true${RESET}  (idle pool)"
            else
                echo -e "  ${YELLOW}●${RESET} Identity ${BOLD}${id}${RESET} → warmpool=${YELLOW}false${RESET} (claimed)"
            fi
        done

    # Count sandbox pods by warmpool label.
    echo ""
    local idle claimed
    idle=$(kubectl get pods -n "${NAMESPACE}" -l warmpool=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
    claimed=$(kubectl get pods -n "${NAMESPACE}" -l warmpool=false --no-headers 2>/dev/null | wc -l | tr -d ' ')
    info "Sandbox pods: ${GREEN}${idle} idle${RESET}, ${YELLOW}${claimed} claimed${RESET}"

    # CiliumEndpoint count in sandbox namespace.
    local cep_count
    cep_count=$(kubectl get ciliumendpoints -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    info "CiliumEndpoints in ${NAMESPACE}: ${BOLD}${cep_count}${RESET}"

    # Check current labels config.
    echo ""
    echo -e "${BOLD}Cilium config (labels field):${RESET}"
    local labels_config
    labels_config=$(kubectl get configmap cilium-config -n kube-system -o jsonpath='{.data.labels}' 2>/dev/null || echo "<not set>")
    if [[ -z "${labels_config}" ]]; then
        labels_config="<not set — all labels used for identity>"
    fi
    info "cilium-config.data.labels = ${BOLD}${labels_config}${RESET}"

    local override_labels
    override_labels=$(kubectl get configmap cilium-config-emergency-override -n kube-system -o jsonpath='{.data.labels}' 2>/dev/null || echo "<not set>")
    if [[ -z "${override_labels}" ]]; then
        override_labels="<not set>"
    fi
    info "cilium-config-emergency-override.data.labels = ${BOLD}${override_labels}${RESET}"

    echo ""
}

# ---------------------------------------------------------------------------
# Watch: pod label changes in sandbox namespace
# ---------------------------------------------------------------------------
watch_labels() {
    info "Watching pod label changes in namespace '${NAMESPACE}'..."
    info "Press Ctrl+C to stop."
    echo ""

    kubectl get pods -n "${NAMESPACE}" -l managed-by=warmpool -w -o json 2>/dev/null \
        | python3 -u -c "
import json, sys, datetime

seen = {}  # pod_name -> last_warmpool_value

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue

    name = obj.get('metadata', {}).get('name', '?')
    labels = obj.get('metadata', {}).get('labels', {})
    wp = labels.get('warmpool', '?')
    ts = datetime.datetime.now().strftime('%H:%M:%S')

    prev = seen.get(name)
    seen[name] = wp

    if prev is not None and prev != wp:
        # Identity-changing label transition detected!
        print(f'\033[1;33m⚡ {ts}\033[0m {name}: warmpool={prev} → \033[1m{wp}\033[0m  ← IDENTITY CHANGE', flush=True)
    elif prev is None:
        print(f'\033[2m{ts}\033[0m {name}: warmpool={wp} (initial)', flush=True)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Watch: CiliumIdentity count changes
# ---------------------------------------------------------------------------
watch_identities() {
    info "Polling CiliumIdentity count every 5s..."
    info "Press Ctrl+C to stop."
    echo ""

    local prev_total=0
    local prev_sandbox=0

    while true; do
        local total sandbox_ids
        total=$(kubectl get ciliumidentity --no-headers 2>/dev/null | wc -l | tr -d ' ')

        sandbox_ids=$(kubectl get ciliumidentity -o jsonpath='{range .items[*]}{.security-labels}{"\n"}{end}' 2>/dev/null \
            | grep -c 'is-sandbox' || echo 0)

        local ts
        ts=$(date '+%H:%M:%S')

        if [[ "${total}" -ne "${prev_total}" ]] || [[ "${sandbox_ids}" -ne "${prev_sandbox}" ]]; then
            local delta=$((total - prev_total))
            local sdelta=$((sandbox_ids - prev_sandbox))
            local delta_str=""
            local sdelta_str=""

            if [[ "${prev_total}" -gt 0 ]]; then
                if [[ "${delta}" -gt 0 ]]; then
                    delta_str=" ${RED}(+${delta})${RESET}"
                elif [[ "${delta}" -lt 0 ]]; then
                    delta_str=" ${GREEN}(${delta})${RESET}"
                fi
            fi
            if [[ "${prev_sandbox}" -gt 0 ]]; then
                if [[ "${sdelta}" -gt 0 ]]; then
                    sdelta_str=" ${RED}(+${sdelta})${RESET}"
                elif [[ "${sdelta}" -lt 0 ]]; then
                    sdelta_str=" ${GREEN}(${sdelta})${RESET}"
                fi
            fi

            echo -e "${YELLOW}${ts}${RESET} Identities: total=${BOLD}${total}${RESET}${delta_str}  sandbox=${BOLD}${sandbox_ids}${RESET}${sdelta_str}"
            prev_total="${total}"
            prev_sandbox="${sandbox_ids}"
        else
            echo -e "${DIM}${ts} Identities: total=${total}  sandbox=${sandbox_ids} (no change)${RESET}"
        fi

        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Watch: CiliumEndpoint regeneration events
# ---------------------------------------------------------------------------
watch_endpoints() {
    info "Watching CiliumEndpoint changes in namespace '${NAMESPACE}'..."
    info "Press Ctrl+C to stop."
    echo ""

    kubectl get ciliumendpoints -n "${NAMESPACE}" -w -o json 2>/dev/null \
        | python3 -u -c "
import json, sys, datetime

seen = {}  # ep_name -> last identity_id

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue

    name = obj.get('metadata', {}).get('name', '?')
    status = obj.get('status', {})
    identity = status.get('identity', {})
    identity_id = identity.get('id', '?')
    ts = datetime.datetime.now().strftime('%H:%M:%S')

    prev = seen.get(name)
    seen[name] = identity_id

    if prev is not None and prev != identity_id:
        print(f'\033[1;33m⚡ {ts}\033[0m {name}: identity {prev} → \033[1m{identity_id}\033[0m  ← REGENERATED', flush=True)
    elif prev is None:
        print(f'\033[2m{ts}\033[0m {name}: identity={identity_id} (initial)', flush=True)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-all}" in
    snapshot)
        snapshot
        ;;
    labels)
        watch_labels
        ;;
    identities)
        watch_identities
        ;;
    endpoints)
        watch_endpoints
        ;;
    all)
        snapshot
        echo -e "${BOLD}━━━ Starting Live Monitors ━━━${RESET}"
        echo ""
        info "Starting 3 monitors in parallel. Press Ctrl+C to stop all."
        echo ""

        watch_labels &
        PID_LABELS=$!
        watch_endpoints &
        PID_ENDPOINTS=$!
        watch_identities &
        PID_IDENTITIES=$!

        trap 'kill ${PID_LABELS} ${PID_ENDPOINTS} ${PID_IDENTITIES} 2>/dev/null; exit 0' INT TERM
        wait
        ;;
    *)
        echo "Usage: $0 {snapshot|labels|identities|endpoints|all}"
        exit 1
        ;;
esac
