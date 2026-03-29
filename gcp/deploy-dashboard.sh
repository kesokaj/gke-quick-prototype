#!/usr/bin/env bash
#
# deploy-dashboard.sh — Deploy the GCP Monitoring dashboard.
#
# Usage:
#   ./gcp/deploy-dashboard.sh           Deploy (create or update)
#   ./gcp/deploy-dashboard.sh delete    Delete the dashboard
#   ./gcp/deploy-dashboard.sh list      List dashboards in the project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
DASHBOARD_FILE="${SCRIPT_DIR}/dashboard.json.tpl"

DASHBOARD_DISPLAY_NAME="gVisor Sandbox Platform — Operations"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
pass() { echo -e "\033[0;32m[$(date +%H:%M:%S)] ✓\033[0m $*"; }
fail() { echo -e "\033[0;31m[$(date +%H:%M:%S)] ✗\033[0m $*"; exit 1; }

get_project() {
    if [[ -z "${PROJECT:-}" ]]; then
        [[ -f "${ENV_FILE}" ]] || fail ".env not found at ${ENV_FILE}"
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi
    [[ -z "${PROJECT:-}" ]] && fail "PROJECT is not set (check .env)"
    echo "${PROJECT}"
}

get_cluster_name() {
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        [[ -f "${ENV_FILE}" ]] || fail ".env not found at ${ENV_FILE}"
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    fi
    [[ -z "${CLUSTER_NAME:-}" ]] && fail "CLUSTER_NAME is not set (check .env)"
    echo "${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# Find existing dashboard ID
# ---------------------------------------------------------------------------

find_dashboard_id() {
    local project="$1"
    gcloud monitoring dashboards list \
        --project="${project}" \
        --format="value(name)" \
        --filter="displayName='${DASHBOARD_DISPLAY_NAME}'" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

deploy() {
    local project dashboard_id cluster_name tmp_dashboard
    project=$(get_project)
    cluster_name=$(get_cluster_name)

    # Validate JSON (template, before substitution)
    python3 -c "import json; json.load(open('${DASHBOARD_FILE}'))" 2>/dev/null || \
        fail "Dashboard file is not valid JSON"

    # Substitute cluster name placeholder.
    tmp_dashboard=$(mktemp)
    sed "s/__CLUSTER_NAME__/${cluster_name}/g" "${DASHBOARD_FILE}" > "${tmp_dashboard}"

    log "Project: ${project}"
    log "Cluster: ${cluster_name}"
    log "Dashboard: ${DASHBOARD_FILE}"

    dashboard_id=$(find_dashboard_id "${project}")

    if [[ -n "${dashboard_id}" ]]; then
        log "Deleting existing dashboard: ${dashboard_id}"
        gcloud monitoring dashboards delete "${dashboard_id}" \
            --project="${project}" \
            --quiet
        pass "Old dashboard deleted"
    fi

    log "Creating dashboard..."
    gcloud monitoring dashboards create \
        --project="${project}" \
        --config-from-file="${tmp_dashboard}" \
        --quiet
    pass "Dashboard created"
    rm -f "${tmp_dashboard}"
}

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------

delete_dashboard() {
    local project dashboard_id
    project=$(get_project)
    dashboard_id=$(find_dashboard_id "${project}")

    if [[ -z "${dashboard_id}" ]]; then
        log "No dashboard found with name '${DASHBOARD_DISPLAY_NAME}'"
        return
    fi

    log "Deleting dashboard: ${dashboard_id}"
    gcloud monitoring dashboards delete "${dashboard_id}" \
        --project="${project}" \
        --quiet
    pass "Dashboard deleted"
}

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------

list_dashboards() {
    local project
    project=$(get_project)
    log "Dashboards in project: ${project}"
    gcloud monitoring dashboards list \
        --project="${project}" \
        --format="table(name.basename(), displayName)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-deploy}" in
    deploy)  deploy ;;
    delete)  delete_dashboard ;;
    list)    list_dashboards ;;
    *)       echo "Usage: $0 {deploy|delete|list}"; exit 1 ;;
esac
