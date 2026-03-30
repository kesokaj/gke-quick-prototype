#!/usr/bin/env bash
# =============================================================================
# apply-cilium-identity-labels.sh
# =============================================================================
#
# Applies or reverts the Cilium identity-relevant label exclusion patch.
# Excludes the 'warmpool' label from Cilium identity computation to prevent
# identity churn when sandbox pods are claimed (warmpool=true → false).
#
# Procedure follows GKE docs:
#   https://docs.cloud.google.com/kubernetes-engine/docs/how-to/dataplane-v2
#   #identity-relevant-label-filtering-issue
#
# Steps (from GKE docs for v1.34/1.35):
#   1. Remove 'labels' key from cilium-config-emergency-override (if present)
#   2. Patch cilium-config.data.labels with exclusion rule
#   3. Restart anet-operator via same-version control plane upgrade
#   4. Restart anetd DaemonSet
#
# Usage:
#   ./apply-cilium-identity-labels.sh apply     Apply the label exclusion patch
#   ./apply-cilium-identity-labels.sh revert    Remove label exclusions (restore default)
#   ./apply-cilium-identity-labels.sh status    Show current config and identity state
#   ./apply-cilium-identity-labels.sh --help    Show this help
#
# Flags:
#   --skip-restart      Skip anetd DaemonSet rollout restart
#   --skip-master       Skip the control plane upgrade (anet-operator reload)
#   --labels "..."      Override the label exclusion string (default: !warmpool)
#   --dry-run           Print commands without executing
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source .env for cluster variables
if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    source "${REPO_DIR}/.env"
    set +a
fi

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*" >&2; }
fail() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; exit 1; }
sep()  { echo -e "${DIM}$(printf '%.0s─' {1..72})${NC}"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT="${PROJECT:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
REGION="${REGION:-}"

# Default: exclude warmpool label from identity computation
DEFAULT_LABELS='!warmpool'
EXCLUDE_LABELS="${DEFAULT_LABELS}"

SKIP_RESTART=false
SKIP_MASTER=false
DRY_RUN=false
ACTION=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        apply|revert|status)
            ACTION="$1"; shift ;;
        --skip-restart)
            SKIP_RESTART=true; shift ;;
        --skip-master)
            SKIP_MASTER=true; shift ;;
        --labels)
            EXCLUDE_LABELS="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        -h|--help)
            head -20 "$0" | tail -18
            echo ""
            echo "Environment variables (from .env):"
            echo "  PROJECT=${PROJECT:-<not set>}"
            echo "  CLUSTER_NAME=${CLUSTER_NAME:-<not set>}"
            echo "  REGION=${REGION:-<not set>}"
            exit 0
            ;;
        *)
            fail "Unknown argument: $1. Use --help for usage." ;;
    esac
done

[[ -z "${ACTION}" ]] && fail "No action specified. Usage: $0 {apply|revert|status}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
    command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
    command -v jq >/dev/null 2>&1 || fail "jq not found (brew install jq)"

    # Verify we can reach the cluster
    kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach Kubernetes cluster"

    # Verify cilium-config exists
    kubectl get configmap cilium-config -n kube-system >/dev/null 2>&1 || \
        fail "ConfigMap 'cilium-config' not found in kube-system"

    if [[ "${SKIP_MASTER}" == "false" ]]; then
        command -v gcloud >/dev/null 2>&1 || fail "gcloud not found (needed for master upgrade)"
        [[ -z "${PROJECT}" ]] && fail "PROJECT not set — needed for gcloud commands"
        [[ -z "${CLUSTER_NAME}" ]] && fail "CLUSTER_NAME not set — needed for gcloud commands"
        [[ -z "${REGION}" ]] && fail "REGION not set — needed for gcloud commands"
    fi

    ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Run or print a command
# ---------------------------------------------------------------------------
run_cmd() {
    if ${DRY_RUN}; then
        echo -e "  ${DIM}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Show current state
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo -e "${BOLD}━━━ Cilium Identity Label Config ━━━${NC}"
    echo ""

    # Current labels field
    local current_labels
    current_labels=$(kubectl get configmap cilium-config -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ -z "${current_labels}" ]]; then
        log "cilium-config.data.labels = ${YELLOW}<not set — all labels used for identity>${NC}"
    else
        log "cilium-config.data.labels = ${BOLD}${current_labels}${NC}"
    fi

    # Emergency override
    local override_labels
    override_labels=$(kubectl get configmap cilium-config-emergency-override -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ -z "${override_labels}" ]]; then
        log "cilium-config-emergency-override.data.labels = ${DIM}<not set>${NC}"
    else
        log "cilium-config-emergency-override.data.labels = ${BOLD}${override_labels}${NC}"
    fi

    # Identity count
    echo ""
    local total_ids
    total_ids=$(kubectl get ciliumidentity --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log "Total CiliumIdentities: ${BOLD}${total_ids}${NC}"

    # Sandbox identities
    local sandbox_ids
    sandbox_ids=$(kubectl get ciliumidentity -o json 2>/dev/null \
        | jq '[.items[] | select(.["security-labels"] | to_entries | any(.key | test("is-sandbox")))] | length')
    log "Sandbox-related identities: ${BOLD}${sandbox_ids}${NC}"

    # Pod counts
    local idle claimed
    idle=$(kubectl get pods -n sandbox -l warmpool=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
    claimed=$(kubectl get pods -n sandbox -l warmpool=false --no-headers 2>/dev/null | wc -l | tr -d ' ')
    log "Sandbox pods: ${GREEN}${idle} idle${NC}, ${YELLOW}${claimed} claimed${NC}"

    # anetd status
    echo ""
    log "anetd DaemonSet status:"
    kubectl get daemonset anetd -n kube-system -o wide --no-headers 2>/dev/null \
        | while read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done

    echo ""
}

# ---------------------------------------------------------------------------
# Apply: patch cilium-config with label exclusions
# ---------------------------------------------------------------------------
do_apply() {
    echo ""
    echo -e "${BOLD}━━━ Applying Cilium Identity Label Exclusions ━━━${NC}"
    echo ""
    log "Labels to exclude: ${BOLD}${EXCLUDE_LABELS}${NC}"
    log "Procedure: GKE docs — identity-relevant-label-filtering-issue workaround"
    sep

    # Step 1: Backup current config
    log "Step 1: Backing up current cilium-config..."
    local backup_file="${SCRIPT_DIR}/cilium-config-backup-$(date '+%Y%m%d-%H%M%S').json"
    if ! ${DRY_RUN}; then
        kubectl get configmap cilium-config -n kube-system -o json > "${backup_file}"
        ok "Backup saved: ${backup_file}"
    else
        echo -e "  ${DIM}[DRY-RUN] kubectl get configmap cilium-config -n kube-system -o json > ${backup_file}${NC}"
    fi
    sep

    # Step 2: Remove 'labels' from cilium-config-emergency-override (if present)
    # Per GKE docs: on v1.34/1.35, emergency-override does NOT work for identity
    # label filtering. The labels key must be removed from the override and set
    # only in the main cilium-config.
    log "Step 2: Cleaning up cilium-config-emergency-override..."
    local override_labels
    override_labels=$(kubectl get configmap cilium-config-emergency-override -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ -n "${override_labels}" ]]; then
        warn "Found 'labels' in emergency-override: ${override_labels}"
        warn "Removing — emergency-override does not work for identity filtering on GKE 1.34/1.35"
        run_cmd kubectl patch configmap cilium-config-emergency-override -n kube-system \
            --type json -p '[{"op": "remove", "path": "/data/labels"}]'
        ok "Removed 'labels' from cilium-config-emergency-override"
    else
        ok "cilium-config-emergency-override has no 'labels' key (clean)"
    fi
    sep

    # Step 3: Patch the main cilium-config configmap
    log "Step 3: Patching cilium-config.data.labels..."
    local patch_json
    patch_json=$(jq -n --arg labels "${EXCLUDE_LABELS}" '{"data": {"labels": $labels}}')
    log "Patch payload: ${DIM}${patch_json}${NC}"

    run_cmd kubectl patch configmap cilium-config -n kube-system \
        --type merge -p "${patch_json}"
    ok "ConfigMap patched"
    sep

    # Step 4: Verify patch was applied
    log "Step 4: Verifying patch..."
    local applied_labels
    applied_labels=$(kubectl get configmap cilium-config -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ "${applied_labels}" == "${EXCLUDE_LABELS}" ]] || ${DRY_RUN}; then
        ok "Verified: labels = ${BOLD}${applied_labels}${NC}"
    else
        warn "Expected '${EXCLUDE_LABELS}' but got '${applied_labels}'"
    fi
    sep

    # Step 5: Restart anet-operator via same-version control plane upgrade
    # Per GKE docs: this forces the operator to restart and reload its config.
    if [[ "${SKIP_MASTER}" == "false" ]]; then
        log "Step 5: Restarting anet-operator via control plane upgrade..."
        warn "This triggers a same-version master upgrade to reload the anet-operator config."
        warn "The cluster will remain available but the control plane will briefly restart."
        echo ""

        local cluster_version
        if ! ${DRY_RUN}; then
            cluster_version=$(gcloud container clusters describe "${CLUSTER_NAME}" \
                --location "${REGION}" --project "${PROJECT}" \
                --format="value(currentMasterVersion)")
            log "Current master version: ${BOLD}${cluster_version}${NC}"
        else
            cluster_version="<version>"
        fi

        run_cmd gcloud container clusters upgrade "${CLUSTER_NAME}" \
            --location "${REGION}" \
            --project "${PROJECT}" \
            --cluster-version "${cluster_version}" \
            --master --quiet

        ok "Control plane upgrade complete"
    else
        log "Step 5: Skipping master upgrade (--skip-master)"
        warn "GKE docs recommend the master upgrade to reload anet-operator config."
        warn "Without it, label filtering may not take full effect until next upgrade."
    fi
    sep

    # Step 6: Restart anetd DaemonSet
    # Per GKE docs: ensures node agents also pick up the config changes.
    if [[ "${SKIP_RESTART}" == "false" ]]; then
        log "Step 6: Rolling restart anetd DaemonSet..."
        run_cmd kubectl rollout restart daemonset anetd -n kube-system

        if ! ${DRY_RUN}; then
            log "Waiting for rollout to complete..."
            kubectl rollout status daemonset anetd -n kube-system --timeout=300s || \
                warn "Rollout did not complete within 300s — check manually"
        fi
        ok "anetd restarted"
    else
        log "Step 6: Skipping anetd restart (--skip-restart)"
    fi
    sep

    # Final status
    log "Step 7: Final verification..."
    show_status

    echo -e "${GREEN}${BOLD}✓ Label exclusion patch applied successfully${NC}"
    echo ""
    echo -e "${DIM}To monitor identity churn:${NC}"
    echo -e "  ${CYAN}./app/tests/monitor-cilium-identity.sh${NC}"
    echo ""
    echo -e "${DIM}To revert:${NC}"
    echo -e "  ${CYAN}$0 revert${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Revert: remove label exclusions from cilium-config
# ---------------------------------------------------------------------------
do_revert() {
    echo ""
    echo -e "${BOLD}━━━ Reverting Cilium Identity Label Exclusions ━━━${NC}"
    echo ""

    # Show current state before revert
    local current_labels
    current_labels=$(kubectl get configmap cilium-config -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ -z "${current_labels}" ]]; then
        ok "Labels field is already empty — nothing to revert"
        return 0
    fi
    log "Current labels field: ${BOLD}${current_labels}${NC}"
    sep

    # Step 1: Backup
    log "Step 1: Backing up current cilium-config..."
    local backup_file="${SCRIPT_DIR}/cilium-config-backup-$(date '+%Y%m%d-%H%M%S').json"
    if ! ${DRY_RUN}; then
        kubectl get configmap cilium-config -n kube-system -o json > "${backup_file}"
        ok "Backup saved: ${backup_file}"
    else
        echo -e "  ${DIM}[DRY-RUN] kubectl get configmap cilium-config -n kube-system -o json > ${backup_file}${NC}"
    fi
    sep

    # Step 2: Remove the labels key from data using a JSON patch
    # Setting it to empty string effectively disables filtering (Cilium uses all labels).
    log "Step 2: Removing 'labels' from cilium-config data..."
    # Use JSON patch to remove the key entirely
    run_cmd kubectl patch configmap cilium-config -n kube-system \
        --type json -p '[{"op": "remove", "path": "/data/labels"}]'
    ok "Labels key removed"
    sep

    # Step 3: Verify
    log "Step 3: Verifying revert..."
    local reverted_labels
    reverted_labels=$(kubectl get configmap cilium-config -n kube-system \
        -o jsonpath='{.data.labels}' 2>/dev/null || echo "")
    if [[ -z "${reverted_labels}" ]] || ${DRY_RUN}; then
        ok "Verified: labels field is empty (all labels used for identity)"
    else
        warn "Labels field still set: ${reverted_labels}"
    fi
    sep

    # Step 4: Restart anet-operator
    if [[ "${SKIP_MASTER}" == "false" ]]; then
        log "Step 4: Restarting anet-operator via control plane upgrade..."

        local cluster_version
        if ! ${DRY_RUN}; then
            cluster_version=$(gcloud container clusters describe "${CLUSTER_NAME}" \
                --location "${REGION}" --project "${PROJECT}" \
                --format="value(currentMasterVersion)")
            log "Current master version: ${BOLD}${cluster_version}${NC}"
        else
            cluster_version="<version>"
        fi

        run_cmd gcloud container clusters upgrade "${CLUSTER_NAME}" \
            --location "${REGION}" \
            --project "${PROJECT}" \
            --cluster-version "${cluster_version}" \
            --master --quiet

        ok "Control plane upgrade triggered"
    else
        log "Step 4: Skipping master upgrade (--skip-master)"
    fi
    sep

    # Step 5: Restart anetd
    if [[ "${SKIP_RESTART}" == "false" ]]; then
        log "Step 5: Rolling restart anetd DaemonSet..."
        run_cmd kubectl rollout restart daemonset anetd -n kube-system

        if ! ${DRY_RUN}; then
            log "Waiting for rollout to complete..."
            kubectl rollout status daemonset anetd -n kube-system --timeout=120s || \
                warn "Rollout did not complete within 120s — check manually"
        fi
        ok "anetd restarted"
    else
        log "Step 5: Skipping anetd restart (--skip-restart)"
    fi
    sep

    # Final status
    log "Step 6: Final verification..."
    show_status

    echo -e "${GREEN}${BOLD}✓ Label exclusion patch reverted — all labels now used for identity${NC}"
    echo ""
    echo -e "${DIM}Note: Existing identities will be garbage-collected as endpoints regenerate.${NC}"
    echo -e "${DIM}Identity count may temporarily increase before settling.${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight

case "${ACTION}" in
    apply)  do_apply  ;;
    revert) do_revert ;;
    status) show_status ;;
esac
