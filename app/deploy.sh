#!/usr/bin/env bash
#
# Sandbox App — Build, Push & Deploy
#
# Usage:
#   ./deploy.sh build                Build container images locally (ARM Mac → AMD64)
#   ./deploy.sh push                 Push to Google Artifact Registry
#   ./deploy.sh deploy [REPLICAS]    Apply K8s manifests (default: 5)
#   ./deploy.sh all [REPLICAS]       Build + push + deploy
#   ./deploy.sh teardown             Delete all resources
#
# Configuration is read from the project .env file.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Load shared .env
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
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
readonly NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*" >&2; }
fail()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west4}"
REPO_NAME="sandbox"
SANDBOX_IMAGE_NAME="sandbox-sim"
CONTROLLER_IMAGE_NAME="sandbox-controller"
WS_SERVER_IMAGE_NAME="ws-server"
WS_SERVER_SERVICE_NAME="sandbox-ws-server"
SANDBOX_SA="sandbox-sa"
SANDBOX_NAMESPACE="sandbox"

REGISTRY="${REGION}-docker.pkg.dev/${PROJECT}/${REPO_NAME}"
WS_SERVER_HTTPS_URL=""


TAG_FILE="${SCRIPT_DIR}/.current-tag"

# ---------------------------------------------------------------------------
# Tag generation — git-hash + unix timestamp
# ---------------------------------------------------------------------------
generate_tag() {
    local git_hash
    git_hash=$(git -C "${REPO_DIR}" rev-parse --short=7 HEAD 2>/dev/null || echo "nogit")
    echo "${git_hash}-$(date +%s)"
}

# Read stored tag or generate new one.
current_tag() {
    if [[ -f "${TAG_FILE}" ]]; then
        cat "${TAG_FILE}"
    else
        fail "No tag found. Run './deploy.sh build' first."
    fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate() {
    [[ -n "${PROJECT}" ]] || fail "PROJECT not set. Run: gcloud config set project <project-id>"
    command -v docker >/dev/null 2>&1 || fail "docker not found"
    command -v gcloud >/dev/null 2>&1 || fail "gcloud not found"
    command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

    # Sanity check: warn if kubectl context doesn't match the expected cluster.
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || echo "")
    if [[ -n "${ctx}" ]] && [[ "${ctx}" != *"${CLUSTER_NAME}"* ]]; then
        warn "kubectl context '${ctx}' may not match CLUSTER_NAME='${CLUSTER_NAME}'"
        warn "Run: gcloud container clusters get-credentials ${CLUSTER_NAME} --region=${REGION} --project=${PROJECT}"
    fi

    log "Project:    ${PROJECT}"
    log "Region:     ${REGION}"
    log "Registry:   ${REGISTRY}"
}

# ---------------------------------------------------------------------------
# Ensure Artifact Registry repo exists
# ---------------------------------------------------------------------------
ensure_repo() {
    log "Ensuring Artifact Registry repo '${REPO_NAME}' exists..."
    if ! gcloud artifacts repositories describe "${REPO_NAME}" \
        --project="${PROJECT}" \
        --location="${REGION}" \
        --format="value(name)" 2>/dev/null; then
        log "Creating Artifact Registry repo..."
        gcloud artifacts repositories create "${REPO_NAME}" \
            --project="${PROJECT}" \
            --location="${REGION}" \
            --repository-format=docker \
            --description="Sandbox container images" \
            --quiet
        ok "Artifact Registry repo created: ${REPO_NAME}"
    else
        ok "Artifact Registry repo already exists: ${REPO_NAME}"
    fi
}

# ---------------------------------------------------------------------------
# Ensure GCP Service Account + Workload Identity binding
# ---------------------------------------------------------------------------
ensure_workload_identity() {
    local gcp_sa="${SANDBOX_SA}@${PROJECT}.iam.gserviceaccount.com"
    local member="serviceAccount:${PROJECT}.svc.id.goog[${SANDBOX_NAMESPACE}/${SANDBOX_SA}]"

    log "Ensuring GCP service account '${SANDBOX_SA}' exists..."
    if ! gcloud iam service-accounts describe "${gcp_sa}" \
        --project="${PROJECT}" &>/dev/null; then
        gcloud iam service-accounts create "${SANDBOX_SA}" \
            --project="${PROJECT}" \
            --display-name="Sandbox Workload Identity SA" \
            --quiet
        ok "GCP service account created: ${gcp_sa}"
    else
        ok "GCP service account already exists: ${gcp_sa}"
    fi

    # Bind KSA → GCP SA for Workload Identity
    log "Ensuring Workload Identity binding..."
    local existing_binding
    existing_binding=$(gcloud iam service-accounts get-iam-policy "${gcp_sa}" \
        --project="${PROJECT}" --format=json 2>/dev/null)
    if echo "${existing_binding}" | grep -qF "${member}"; then
        ok "Workload Identity binding already exists"
    else
        gcloud iam service-accounts add-iam-policy-binding "${gcp_sa}" \
            --project="${PROJECT}" \
            --role=roles/iam.workloadIdentityUser \
            --member="${member}" \
            --quiet
        ok "Workload Identity binding created: ${SANDBOX_NAMESPACE}/${SANDBOX_SA} → ${gcp_sa}"
    fi

    # Grant monitoring.metricWriter so sandbox pods can write metrics
    log "Ensuring monitoring.metricWriter role..."
    gcloud projects add-iam-policy-binding "${PROJECT}" \
        --member="serviceAccount:${gcp_sa}" \
        --role=roles/monitoring.metricWriter \
        --quiet &>/dev/null
    ok "Role monitoring.metricWriter bound to ${gcp_sa}"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
cmd_build() {
    validate

    local tag
    tag="$(generate_tag)"
    log "Tag: ${tag}"

    local sandbox_image="${REGISTRY}/${SANDBOX_IMAGE_NAME}:${tag}"
    local controller_image="${REGISTRY}/${CONTROLLER_IMAGE_NAME}:${tag}"

    # Build sandbox simulation image
    log "Building sandbox simulation image (linux/amd64)..."
    if docker buildx version &>/dev/null; then
        docker buildx build \
            --platform linux/amd64 \
            --provenance=false \
            -t "${sandbox_image}" \
            --load \
            "${SCRIPT_DIR}/sandbox"
        ok "Sandbox image built: ${sandbox_image}"
    else
        warn "docker buildx not available — falling back to Cloud Build"
        ensure_repo
        gcloud builds submit \
            --tag "${sandbox_image}" \
            --project="${PROJECT}" \
            --quiet \
            "${SCRIPT_DIR}/sandbox"
        ok "Sandbox image built via Cloud Build: ${sandbox_image}"
    fi

    # Build controller image
    log "Building controller image (linux/amd64)..."
    if docker buildx version &>/dev/null; then
        docker buildx build \
            --platform linux/amd64 \
            --provenance=false \
            -t "${controller_image}" \
            --load \
            "${SCRIPT_DIR}/controller"
        ok "Controller image built: ${controller_image}"
    else
        gcloud builds submit \
            --tag "${controller_image}" \
            --project="${PROJECT}" \
            --quiet \
            "${SCRIPT_DIR}/controller"
        ok "Controller image built via Cloud Build: ${controller_image}"
    fi

    # Build ws-server image
    local ws_image="${REGISTRY}/${WS_SERVER_IMAGE_NAME}:${tag}"
    log "Building ws-server image (linux/amd64)..."
    if docker buildx version &>/dev/null; then
        docker buildx build \
            --platform linux/amd64 \
            --provenance=false \
            -t "${ws_image}" \
            --load \
            "${SCRIPT_DIR}/ws-server"
        ok "WS server image built: ${ws_image}"
    else
        gcloud builds submit \
            --tag "${ws_image}" \
            --project="${PROJECT}" \
            --quiet \
            "${SCRIPT_DIR}/ws-server"
        ok "WS server image built via Cloud Build: ${ws_image}"
    fi

    # Store tag
    echo "${tag}" > "${TAG_FILE}"
    ok "Tag saved to ${TAG_FILE}: ${tag}"
}

# ---------------------------------------------------------------------------
# Push
# ---------------------------------------------------------------------------
cmd_push() {
    validate
    ensure_repo

    local tag
    tag="$(current_tag)"

    local sandbox_image="${REGISTRY}/${SANDBOX_IMAGE_NAME}:${tag}"
    local controller_image="${REGISTRY}/${CONTROLLER_IMAGE_NAME}:${tag}"

    log "Configuring docker for Artifact Registry..."
    gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

    log "Pushing sandbox image..."
    docker push "${sandbox_image}"
    ok "Sandbox image pushed: ${sandbox_image}"

    log "Pushing controller image..."
    docker push "${controller_image}"
    ok "Controller image pushed: ${controller_image}"

    local ws_image="${REGISTRY}/${WS_SERVER_IMAGE_NAME}:${tag}"
    log "Pushing ws-server image..."
    docker push "${ws_image}"
    ok "WS server image pushed: ${ws_image}"
}

# ---------------------------------------------------------------------------
# Ensure namespaces exist
# ---------------------------------------------------------------------------
ensure_namespaces() {
    log "Ensuring namespaces..."
    kubectl apply -f "${SCRIPT_DIR}/manifests/namespaces.yaml"
    ok "Namespaces applied (sandbox, sandbox-control)"
}

# ---------------------------------------------------------------------------
# Ensure controller deployed (RBAC + Deployment + Service)
# ---------------------------------------------------------------------------
ensure_controller() {
    local controller_image="$1"

    log "Ensuring controller deployment..."
    sed "s|IMAGE_PLACEHOLDER|${controller_image}|g" "${SCRIPT_DIR}/manifests/controller.yaml" \
        | kubectl apply -f -
    ok "Controller deployed to sandbox-control"
}

# ---------------------------------------------------------------------------
# Ensure controller service is reachable, return its ClusterIP URL
# ---------------------------------------------------------------------------
ensure_controller_service() {
    log "Waiting for controller ClusterIP..." >&2
    local controller_svc=""
    for _ in $(seq 1 10); do
        controller_svc=$(kubectl get svc sandbox-controller -n sandbox-control \
            -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
        [[ -n "${controller_svc}" ]] && break
        sleep 2
    done
    if [[ -z "${controller_svc}" ]]; then
        fail "Controller service not found after 20s"
    fi
    ok "Controller ClusterIP: ${controller_svc}" >&2
    # Return the URL via stdout (only this line goes to stdout)
    echo "http://${controller_svc}:8080"
}

# ---------------------------------------------------------------------------
# Ensure K8s ServiceAccount for sandbox pods (Workload Identity)
# ---------------------------------------------------------------------------
ensure_sandbox_sa() {
    log "Ensuring K8s ServiceAccount sandbox-sa..."
    sed "s|PROJECT_ID|${PROJECT}|g" "${SCRIPT_DIR}/manifests/sandbox-sa.yaml" \
        | kubectl apply -f -
    ok "ServiceAccount sandbox-sa applied (Workload Identity → ${PROJECT})"
}

# ---------------------------------------------------------------------------
# Ensure NetworkPolicy
# ---------------------------------------------------------------------------
ensure_network_policy() {
    if [[ -f "${SCRIPT_DIR}/manifests/sandbox-isolation.yaml" ]]; then
        log "Ensuring NetworkPolicy..."
        kubectl apply -f "${SCRIPT_DIR}/manifests/sandbox-isolation.yaml"
        ok "NetworkPolicy applied"
    fi
}

# ---------------------------------------------------------------------------
# Ensure ws-server deployed to Cloud Run
# ---------------------------------------------------------------------------
ensure_ws_server() {
    local ws_image="$1"
    local gcp_sa="${SANDBOX_SA}@${PROJECT}.iam.gserviceaccount.com"

    log "Deploying ws-server to Cloud Run..."
    local deploy_output
    deploy_output=$(gcloud run deploy "${WS_SERVER_SERVICE_NAME}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --image="${ws_image}" \
        --platform=managed \
        --no-allow-unauthenticated \
        --port=8080 \
        --concurrency=300 \
        --min-instances=0 \
        --max-instances=100 \
        --timeout=3600 \
        --session-affinity \
        --cpu=1 \
        --memory=256Mi \
        --quiet 2>&1)

    ok "WS server deployed to Cloud Run: ${WS_SERVER_SERVICE_NAME}"

    # Extract the service URL from deploy output (e.g. "Service URL: https://...").
    WS_SERVER_HTTPS_URL=$(echo "${deploy_output}" | grep -oE 'https://[^ ]+' | head -1)
    if [[ -z "${WS_SERVER_HTTPS_URL}" ]]; then
        # Fallback: use gcloud describe.
        WS_SERVER_HTTPS_URL=$(gcloud run services describe "${WS_SERVER_SERVICE_NAME}" \
            --project="${PROJECT}" \
            --region="${REGION}" \
            --format="value(status.url)" 2>/dev/null)
    fi
    log "Cloud Run URL: ${WS_SERVER_HTTPS_URL}"

    # Grant sandbox SA permission to invoke the Cloud Run service.
    log "Ensuring sandbox-sa can invoke ws-server..."
    gcloud run services add-iam-policy-binding "${WS_SERVER_SERVICE_NAME}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --member="serviceAccount:${gcp_sa}" \
        --role=roles/run.invoker \
        --quiet &>/dev/null
    ok "IAM binding: ${SANDBOX_SA} → roles/run.invoker on ${WS_SERVER_SERVICE_NAME}"
}

# Get Cloud Run ws-server URL (uses cached value from ensure_ws_server if available)
get_ws_server_url() {
    local url="${WS_SERVER_HTTPS_URL}"
    if [[ -z "${url}" ]]; then
        url=$(gcloud run services describe "${WS_SERVER_SERVICE_NAME}" \
            --project="${PROJECT}" \
            --region="${REGION}" \
            --format="value(status.url)" 2>/dev/null)
    fi
    if [[ -z "${url}" ]]; then
        fail "Could not retrieve ws-server Cloud Run URL"
    fi
    # Convert https://... to wss://.../ws
    echo "${url/https:/wss:}/ws"
}

# ---------------------------------------------------------------------------
# Ensure GKE Managed Prometheus monitoring resources
# ---------------------------------------------------------------------------
ensure_monitoring() {
    local shared_dir="${REPO_DIR}/gke/shared"
    log "Applying GKE monitoring resources..."
    kubectl apply -f "${shared_dir}/controller-pod-monitoring.yaml"
    kubectl apply -f "${shared_dir}/kubelet-extra-monitoring.yaml"
    ok "GKE monitoring resources applied"
}

# ---------------------------------------------------------------------------
# Deploy — orchestrates all ensure_* functions
# ---------------------------------------------------------------------------
cmd_deploy() {
    local replicas="${1:-5}"
    validate

    local tag
    tag="$(current_tag)"

    local sandbox_image="${REGISTRY}/${SANDBOX_IMAGE_NAME}:${tag}"
    local controller_image="${REGISTRY}/${CONTROLLER_IMAGE_NAME}:${tag}"
    local ws_image="${REGISTRY}/${WS_SERVER_IMAGE_NAME}:${tag}"

    log "Deploying with tag: ${tag}"
    log "Sandbox:    ${sandbox_image}"
    log "Controller: ${controller_image}"
    log "WS Server:  ${ws_image}"

    ensure_namespaces
    ensure_controller "${controller_image}"

    ensure_controller_service

    ensure_workload_identity
    ensure_sandbox_sa

    # Deploy ws-server to Cloud Run and get its URL.
    ensure_ws_server "${ws_image}"
    local ws_url
    ws_url=$(get_ws_server_url)
    log "WS Server URL: ${ws_url}"

    # Deploy sandbox pool with the WS server URL injected.
    log "Ensuring sandbox pool deployment (${replicas} replicas)..."
    sed "s|IMAGE_PLACEHOLDER|${sandbox_image}|g" "${SCRIPT_DIR}/manifests/deployment.yaml" \
        | sed "s|replicas: 0|replicas: ${replicas}|g" \
        | sed "s|WS_SERVER_URL_PLACEHOLDER|${ws_url}|g" \
        | kubectl apply -f -
    ok "Sandbox pool deployed: ${replicas} replicas (WS → ${ws_url})"

    ensure_network_policy
    ensure_monitoring

    echo ""
    log "Watch pods:      kubectl get pods -n sandbox -l warmpool=true -w"
    log "Controller logs: kubectl logs -n sandbox-control deploy/sandbox-controller -f"
    log "Controller UI:   kubectl port-forward -n sandbox-control svc/sandbox-controller 8080:8080"
    log "WS Server logs:  gcloud run services logs read ${WS_SERVER_SERVICE_NAME} --region=${REGION} --limit=50"
    log "Teardown:        ./deploy.sh teardown"
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
cmd_teardown() {
    validate
    warn "Deleting all sandbox resources..."
    kubectl delete deployment sandbox-pool -n sandbox --ignore-not-found
    kubectl delete deployment sandbox-controller -n sandbox-control --ignore-not-found
    kubectl delete service sandbox-controller -n sandbox-control --ignore-not-found
    kubectl delete clusterrolebinding sandbox-controller --ignore-not-found
    kubectl delete clusterrole sandbox-controller --ignore-not-found
    kubectl delete serviceaccount sandbox-controller -n sandbox-control --ignore-not-found
    kubectl delete serviceaccount sandbox-sa -n sandbox --ignore-not-found
    kubectl delete networkpolicy sandbox-isolation -n sandbox --ignore-not-found
    kubectl delete namespace sandbox-control --ignore-not-found
    kubectl delete namespace sandbox --ignore-not-found

    # Clean up cluster-scoped monitoring resources (survive namespace deletion).
    log "Cleaning up cluster-scoped monitoring resources..."
    kubectl delete clusternodemonitoring sandbox-kubelet-extra --ignore-not-found 2>/dev/null || true
    kubectl delete daemonset conntrack-reporter -n gmp-public --ignore-not-found 2>/dev/null || true
    kubectl delete daemonset gvisor-metrics-reporter -n gmp-public --ignore-not-found 2>/dev/null || true
    ok "Cluster-scoped monitoring resources cleaned"

    # Delete Cloud Run ws-server
    log "Deleting Cloud Run ws-server..."
    gcloud run services delete "${WS_SERVER_SERVICE_NAME}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --quiet 2>/dev/null || true
    ok "Cloud Run ws-server deleted"

    ok "All sandbox resources deleted"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Sandbox App — Build, Push & Deploy

Usage:
  ./deploy.sh build                Build container images locally (ARM Mac → AMD64)
  ./deploy.sh push                 Push to Google Artifact Registry
  ./deploy.sh deploy [REPLICAS]    Apply K8s manifests (default: 5)
  ./deploy.sh all [REPLICAS]       Build + push + deploy
  ./deploy.sh teardown             Delete all resources

Configuration is read from the project .env file.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local action="${1:-}"
    local arg="${2:-}"

    case "${action}" in
        build)    cmd_build ;;
        push)     cmd_push ;;
        deploy)   cmd_deploy "${arg:-5}" ;;
        all)      cmd_build; cmd_push; cmd_deploy "${arg:-5}" ;;
        teardown) cmd_teardown ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"
