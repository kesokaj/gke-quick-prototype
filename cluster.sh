#!/usr/bin/env bash
#
# GKE Cluster Lifecycle Script
#
# Usage:
#   ./cluster.sh create  [--dry-run]   VPC + subnet + cluster + shared k8s configs
#   ./cluster.sh apply   [--dry-run]   Apply gke/secondary/ configs (CCC, etc.)
#   ./cluster.sh delete  [--dry-run]   Delete cluster (preserves VPC)
#   ./cluster.sh status                Show cluster + node pool info
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Load .env from script directory
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
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
readonly NC='\033[0m'

log()   { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*" >&2; }
fail()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $*" >&2; exit 1; }
header() { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

# ---------------------------------------------------------------------------
# Configuration (sourced from .env, with fallbacks)
# ---------------------------------------------------------------------------
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
CLUSTER_NAME="${CLUSTER_NAME:-my-cluster}"
REGION="${REGION:-europe-west4}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-REGULAR}"
RELEASE_CHANNEL="${RELEASE_CHANNEL,,}"  # gcloud requires lowercase
CLUSTER_VERSION="${CLUSTER_VERSION:-}"

# Network
VPC="${VPC:-my-network}"
VPC_MTU="${VPC_MTU:-1460}"
SUBNET="${SUBNET:-my-subnet-${REGION}}"
SUBNET_RANGE="${SUBNET_RANGE:-10.10.0.0/20}"
SUBNET_SECONDARY_PODS="${SUBNET_SECONDARY_PODS:-10.100.0.0/16}"
SUBNET_SECONDARY_SERVICE="${SUBNET_SECONDARY_SERVICE:-10.200.0.0/20}"
PODS_RANGE_NAME="${PODS_RANGE_NAME:-pods}"
SECONDARY_PODS_RANGE_NAME="${SECONDARY_PODS_RANGE_NAME:-secondary-pods}"
SECONDARY_PODS_RANGE="${SECONDARY_PODS_RANGE:-10.50.0.0/16}"
SERVICES_RANGE_NAME="${SERVICES_RANGE_NAME:-services}"
ENABLE_CLOUD_NAT="${ENABLE_CLOUD_NAT:-true}"

# Default pool
MACHINE_TYPE="${MACHINE_TYPE:-n2d-standard-4}"
DISK_TYPE="${DISK_TYPE:-pd-ssd}"
DISK_SIZE="${DISK_SIZE:-300}"
NUM_NODES="${NUM_NODES:-2}"
MAX_PODS_PER_NODE="${MAX_PODS_PER_NODE:-64}"
DEFAULT_GVNIC="${DEFAULT_GVNIC:-}"
DEFAULT_SHIELDED_SECURE_BOOT="${DEFAULT_SHIELDED_SECURE_BOOT:-}"
DEFAULT_SHIELDED_INTEGRITY="${DEFAULT_SHIELDED_INTEGRITY:-}"
DEFAULT_AUTO_REPAIR="${DEFAULT_AUTO_REPAIR:-true}"
DEFAULT_AUTO_UPGRADE="${DEFAULT_AUTO_UPGRADE:-true}"

# Secondary pool
SECONDARY_MACHINE_TYPE="${SECONDARY_MACHINE_TYPE:-n2-standard-8}"
SECONDARY_DISK_TYPE="${SECONDARY_DISK_TYPE:-pd-ssd}"
SECONDARY_DISK_SIZE="${SECONDARY_DISK_SIZE:-300}"
SECONDARY_IMAGE_TYPE="${SECONDARY_IMAGE_TYPE:-COS_CONTAINERD}"
SECONDARY_AUTOSCALING="${SECONDARY_AUTOSCALING:-false}"
SECONDARY_NUM_NODES="${SECONDARY_NUM_NODES:-0}"
SECONDARY_MIN_NODES="${SECONDARY_MIN_NODES:-0}"
SECONDARY_MAX_NODES="${SECONDARY_MAX_NODES:-100}"
SECONDARY_MAX_PODS_PER_NODE="${SECONDARY_MAX_PODS_PER_NODE:-64}"
SECONDARY_MAX_SURGE="${SECONDARY_MAX_SURGE:-}"
SECONDARY_MAX_UNAVAILABLE="${SECONDARY_MAX_UNAVAILABLE:-}"
SECONDARY_SPOT="${SECONDARY_SPOT:-}"
SECONDARY_LOCATION_POLICY="${SECONDARY_LOCATION_POLICY:-ANY}"
SECONDARY_GVNIC="${SECONDARY_GVNIC:-}"
SECONDARY_SHIELDED_SECURE_BOOT="${SECONDARY_SHIELDED_SECURE_BOOT:-}"
SECONDARY_SHIELDED_INTEGRITY="${SECONDARY_SHIELDED_INTEGRITY:-}"
SECONDARY_NESTED_VIRT="${SECONDARY_NESTED_VIRT:-}"
SECONDARY_THREADS_PER_CORE="${SECONDARY_THREADS_PER_CORE:-}"
SECONDARY_AUTO_REPAIR="${SECONDARY_AUTO_REPAIR:-true}"
SECONDARY_AUTO_UPGRADE="${SECONDARY_AUTO_UPGRADE:-true}"
SECONDARY_TAGS="${SECONDARY_TAGS:-}"
SECONDARY_LABELS="${SECONDARY_LABELS:-}"
SECONDARY_TAINTS="${SECONDARY_TAINTS:-}"
SECONDARY_SANDBOX_TYPE="${SECONDARY_SANDBOX_TYPE:-gvisor}"
SECONDARY_GCFS="${SECONDARY_GCFS:-true}"
SECONDARY_SYSTEM_CONFIG="${SECONDARY_SYSTEM_CONFIG:-}"

# Cluster features
AUTOSCALING_PROFILE="${AUTOSCALING_PROFILE:-balanced}"
ENABLE_VPA="${ENABLE_VPA:-false}"
HPA_PROFILE="${HPA_PROFILE:-}"
CLUSTER_DNS="${CLUSTER_DNS:-clouddns}"
CLUSTER_DNS_SCOPE="${CLUSTER_DNS_SCOPE:-cluster}"
ENABLE_DNS_CACHE="${ENABLE_DNS_CACHE:-true}"
ENABLE_FILESTORE_CSI="${ENABLE_FILESTORE_CSI:-false}"
ENABLE_IMAGE_STREAMING="${ENABLE_IMAGE_STREAMING:-false}"
ENABLE_COST_ALLOCATION="${ENABLE_COST_ALLOCATION:-true}"
ENABLE_SECRET_MANAGER="${ENABLE_SECRET_MANAGER:-true}"
ENABLE_L4_ILB_SUBSETTING="${ENABLE_L4_ILB_SUBSETTING:-false}"
FLEET_PROJECT="${FLEET_PROJECT:-${PROJECT}}"

# ---------------------------------------------------------------------------
# Ensure required GCP APIs are enabled
# ---------------------------------------------------------------------------
ensure_apis() {
    local -a required_apis=(
        # Core compute & containers
        compute.googleapis.com
        container.googleapis.com

        # IAM
        iam.googleapis.com
        iap.googleapis.com

        # Networking
        dns.googleapis.com
        networkmanagement.googleapis.com
        networkservices.googleapis.com
        networksecurity.googleapis.com
        firewallinsights.googleapis.com

        # Observability & monitoring
        logging.googleapis.com
        monitoring.googleapis.com
        opsconfigmonitoring.googleapis.com
        clouderrorreporting.googleapis.com
        cloudtrace.googleapis.com

        # Security
        containersecurity.googleapis.com
        secretmanager.googleapis.com

        # Artifact & build
        artifactregistry.googleapis.com
        cloudbuild.googleapis.com

        # Cloud Run (ws-server)
        run.googleapis.com

        # Storage
        storage.googleapis.com
        storage-component.googleapis.com

        # GKE ecosystem & fleet
        gkehub.googleapis.com
        anthos.googleapis.com

        # Resource management
        cloudresourcemanager.googleapis.com
        serviceusage.googleapis.com
        cloudquotas.googleapis.com
        recommender.googleapis.com
    )

    header "Ensuring GCP APIs"
    local apis_to_enable=()
    local enabled_apis
    enabled_apis=$(gcloud services list --project="${PROJECT}" --enabled --format="value(config.name)" 2>/dev/null)

    for api in "${required_apis[@]}"; do
        if echo "${enabled_apis}" | grep -q "^${api}$"; then
            ok "API already enabled: ${api}"
        else
            apis_to_enable+=("${api}")
        fi
    done

    if [[ ${#apis_to_enable[@]} -gt 0 ]]; then
        log "Enabling ${#apis_to_enable[@]} APIs (this may take a minute)..."
        gcloud services enable "${apis_to_enable[@]}" --project="${PROJECT}" --quiet
        ok "APIs enabled: ${apis_to_enable[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate() {
    command -v gcloud >/dev/null 2>&1 || fail "gcloud CLI not found"
    [[ -n "${PROJECT}" ]] || fail "PROJECT not set. Run: gcloud config set project <id>"
    log "Project:  ${PROJECT}"
    log "Cluster:  ${CLUSTER_NAME}"
    log "Region:   ${REGION}"
    log "VPC:      ${VPC} / ${SUBNET}"
}

# ---------------------------------------------------------------------------
# Dry-run helper: prints command instead of executing
# ---------------------------------------------------------------------------
exec_or_dry() {
    local dry_run="$1"; shift
    if [[ "${dry_run}" == "--dry-run" ]]; then
        warn "DRY RUN — would execute:"
        echo ""
        printf '%s' "$1"
        local arg
        shift
        for arg in "$@"; do
            printf ' \\\n  %s' "${arg}"
        done
        echo ""
        echo ""
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# Stage 1: CREATE — VPC + Subnet + Cluster + Secondary pool + Shared configs
# ---------------------------------------------------------------------------
cmd_create() {
    local dry_run="${1:-}"
    validate
    ensure_apis

    # Service accounts
    header "Creating Service Accounts"
    local sa_default="gke-default"
    local sa_secondary="gke-secondary"
    for sa_name in "${sa_default}" "${sa_secondary}"; do
        local sa_email="${sa_name}@${PROJECT}.iam.gserviceaccount.com"
        if gcloud iam service-accounts describe "${sa_email}" --project="${PROJECT}" &>/dev/null; then
            ok "SA already exists: ${sa_email}"
        else
            log "Creating SA: ${sa_name}"
            exec_or_dry "${dry_run}" gcloud iam service-accounts create "${sa_name}" \
                --project="${PROJECT}" \
                --display-name="GKE ${sa_name}" \
                --quiet
            exec_or_dry "${dry_run}" gcloud projects add-iam-policy-binding "${PROJECT}" \
                --member="serviceAccount:${sa_email}" \
                --role="roles/owner" \
                --quiet
            ok "SA created: ${sa_email} (role: owner)"
        fi
    done

    header "Creating VPC: ${VPC}"
    local -a vpc_cmd=(
        gcloud compute networks create "${VPC}"
        --project="${PROJECT}"
        --subnet-mode=custom
        --mtu="${VPC_MTU}"
        --quiet
    )
    if gcloud compute networks describe "${VPC}" --project="${PROJECT}" &>/dev/null; then
        ok "VPC already exists: ${VPC}"
    else
        exec_or_dry "${dry_run}" "${vpc_cmd[@]}"
        ok "VPC created: ${VPC}"
    fi

    # Firewall rules (idempotent — skip if exists)
    header "Creating Firewall Rules"
    local -A rules=(
        ["allow-rdp"]="--allow=tcp:3389 --source-ranges=0.0.0.0/0 --target-tags=rdp"
        ["allow-ssh"]="--allow=tcp:22 --source-ranges=0.0.0.0/0 --target-tags=ssh"
        ["allow-lb-healthcheck"]="--allow=tcp,udp --source-ranges=130.211.0.0/22,35.191.0.0/16,209.85.152.0/22,209.85.204.0/22"
        ["allow-icmp"]="--allow=icmp --source-ranges=0.0.0.0/0"
        ["allow-internal"]="--allow=tcp,udp,icmp --source-ranges=10.0.0.0/8"
        ["allow-iap"]="--allow=tcp,udp --source-ranges=35.235.240.0/20"
    )
    for rule_name in "${!rules[@]}"; do
        local full_name="${VPC}-${rule_name}"
        if gcloud compute firewall-rules describe "${full_name}" --project="${PROJECT}" &>/dev/null; then
            ok "Firewall rule exists: ${full_name}"
        else
            log "Creating firewall rule: ${full_name}"
            # shellcheck disable=SC2086
            exec_or_dry "${dry_run}" gcloud compute firewall-rules create "${full_name}" \
                --project="${PROJECT}" \
                --network="${VPC}" \
                ${rules[${rule_name}]} \
                --quiet
            ok "Firewall rule created: ${full_name}"
        fi
    done

    header "Creating Subnet: ${SUBNET}"
    local -a subnet_cmd=(
        gcloud compute networks subnets create "${SUBNET}"
        --project="${PROJECT}"
        --network="${VPC}"
        --region="${REGION}"
        --range="${SUBNET_RANGE}"
        --secondary-range="${PODS_RANGE_NAME}=${SUBNET_SECONDARY_PODS}"
        --secondary-range="${SECONDARY_PODS_RANGE_NAME}=${SECONDARY_PODS_RANGE}"
        --secondary-range="${SERVICES_RANGE_NAME}=${SUBNET_SECONDARY_SERVICE}"
        --enable-private-ip-google-access
        --quiet
    )
    if gcloud compute networks subnets describe "${SUBNET}" --project="${PROJECT}" --region="${REGION}" &>/dev/null; then
        ok "Subnet already exists: ${SUBNET}"
    else
        exec_or_dry "${dry_run}" "${subnet_cmd[@]}"
        ok "Subnet created: ${SUBNET}"
    fi

    # Cloud NAT (optional)
    if [[ "${ENABLE_CLOUD_NAT}" == "true" ]]; then
        header "Creating Cloud NAT"
        local router_name="${VPC}-router"
        local nat_name="${VPC}-nat"

        # Cloud Router
        if gcloud compute routers describe "${router_name}" --project="${PROJECT}" --region="${REGION}" &>/dev/null; then
            ok "Cloud Router already exists: ${router_name}"
        else
            log "Creating Cloud Router: ${router_name}"
            exec_or_dry "${dry_run}" gcloud compute routers create "${router_name}" \
                --project="${PROJECT}" \
                --network="${VPC}" \
                --region="${REGION}" \
                --quiet
            ok "Cloud Router created: ${router_name}"
        fi

        # Cloud NAT
        if gcloud compute routers nats describe "${nat_name}" --router="${router_name}" --project="${PROJECT}" --region="${REGION}" &>/dev/null; then
            ok "Cloud NAT already exists: ${nat_name}"
        else
            log "Creating Cloud NAT: ${nat_name}"
            exec_or_dry "${dry_run}" gcloud compute routers nats create "${nat_name}" \
                --router="${router_name}" \
                --project="${PROJECT}" \
                --region="${REGION}" \
                --auto-allocate-nat-external-ips \
                --nat-all-subnet-ip-ranges \
                --enable-dynamic-port-allocation \
                --min-ports-per-vm=1024 \
                --no-enable-endpoint-independent-mapping \
                --udp-idle-timeout=120 \
                --tcp-established-idle-timeout=3600 \
                --tcp-transitory-idle-timeout=60 \
                --icmp-idle-timeout=60 \
                --tcp-time-wait-timeout=300 \
                --enable-logging \
                --log-filter=ERRORS_ONLY \
                --quiet
            ok "Cloud NAT created: ${nat_name}"
        fi
    fi

    header "Creating GKE Cluster: ${CLUSTER_NAME}"
    local cluster_exists=false
    if gcloud container clusters describe "${CLUSTER_NAME}" --project="${PROJECT}" --region="${REGION}" &>/dev/null; then
        cluster_exists=true
        ok "Cluster already exists: ${CLUSTER_NAME}"
        log "Skipping creation, will re-apply shared k8s configs"
    else
        local -a cluster_cmd=(
            gcloud beta container clusters create "${CLUSTER_NAME}"
            --project="${PROJECT}"
            --region="${REGION}"

            # Compute (default-pool)
            --machine-type="${MACHINE_TYPE}"
            --disk-type="${DISK_TYPE}"
            --disk-size="${DISK_SIZE}"
            --num-nodes="${NUM_NODES}"
            --no-enable-autoscaling
            --location-policy=ANY
            --autoscaling-profile="${AUTOSCALING_PROFILE}"
            --max-surge-upgrade=3
            --max-unavailable-upgrade=1
            --release-channel="${RELEASE_CHANNEL}"
            --scopes=https://www.googleapis.com/auth/cloud-platform
            --service-account="gke-default@${PROJECT}.iam.gserviceaccount.com"
            --logging-variant=MAX_THROUGHPUT
            --metadata=disable-legacy-endpoints=true

            # Workload Identity
            --workload-pool="${PROJECT}.svc.id.goog"

            # Network
            --enable-ip-alias
            --network="${VPC}"
            --subnetwork="${SUBNET}"
            --cluster-secondary-range-name="${PODS_RANGE_NAME}"
            --services-secondary-range-name="${SERVICES_RANGE_NAME}"
            --enable-dataplane-v2
            --default-max-pods-per-node="${MAX_PODS_PER_NODE}"

            # DPv2 Scale-Optimized: disable overhead
            --in-transit-encryption=none
            --disable-l4-lb-firewall-reconciliation

            # Private cluster
            --enable-private-nodes
            --enable-dns-access
            --no-enable-ip-access

            # Gateway API
            --gateway-api=standard

            # Observability
            --logging=SYSTEM,WORKLOAD,API_SERVER,CONTROLLER_MANAGER,SCHEDULER
            --monitoring=SYSTEM,API_SERVER,SCHEDULER,CONTROLLER_MANAGER,POD,DAEMONSET,DEPLOYMENT,STATEFULSET,HPA,STORAGE,CADVISOR,KUBELET,JOBSET
            --enable-managed-prometheus

            --quiet
        )
        # Default pool conditional flags
        [[ "${DEFAULT_GVNIC}" == "true" ]] && cluster_cmd+=(--enable-gvnic)
        [[ "${DEFAULT_SHIELDED_SECURE_BOOT}" == "true" ]] && cluster_cmd+=(--shielded-secure-boot)
        [[ "${DEFAULT_SHIELDED_INTEGRITY}" == "true" ]] && cluster_cmd+=(--shielded-integrity-monitoring)
        [[ "${DEFAULT_AUTO_REPAIR}" == "true" ]] && cluster_cmd+=(--enable-autorepair) || cluster_cmd+=(--no-enable-autorepair)
        [[ "${DEFAULT_AUTO_UPGRADE}" == "true" ]] && cluster_cmd+=(--enable-autoupgrade) || cluster_cmd+=(--no-enable-autoupgrade)

        # Cluster feature flags
        [[ -n "${CLUSTER_VERSION}" ]] && cluster_cmd+=(--cluster-version="${CLUSTER_VERSION}")
        [[ "${ENABLE_VPA}" == "true" ]] && cluster_cmd+=(--enable-vertical-pod-autoscaling)
        [[ -n "${HPA_PROFILE}" ]] && cluster_cmd+=(--hpa-profile="${HPA_PROFILE}")
        [[ "${ENABLE_IMAGE_STREAMING}" == "true" ]] && cluster_cmd+=(--enable-image-streaming)
        [[ "${ENABLE_COST_ALLOCATION}" == "true" ]] && cluster_cmd+=(--enable-cost-allocation)
        [[ "${ENABLE_SECRET_MANAGER}" == "true" ]] && cluster_cmd+=(--enable-secret-manager)
        [[ "${ENABLE_L4_ILB_SUBSETTING}" == "true" ]] && cluster_cmd+=(--enable-l4-ilb-subsetting)
        [[ -n "${CLUSTER_DNS}" ]] && cluster_cmd+=(--cluster-dns="${CLUSTER_DNS}" --cluster-dns-scope="${CLUSTER_DNS_SCOPE}")
        [[ -n "${FLEET_PROJECT}" ]] && cluster_cmd+=(--fleet-project="${FLEET_PROJECT}")

        # Build addons string (gcloud only accepts a single --addons flag)
        local addons="HttpLoadBalancing"
        [[ "${ENABLE_DNS_CACHE}" == "true" ]] && addons+=",NodeLocalDNS"
        [[ "${ENABLE_FILESTORE_CSI}" == "true" ]] && addons+=",GcpFilestoreCsiDriver"
        cluster_cmd+=(--addons="${addons}")

        exec_or_dry "${dry_run}" "${cluster_cmd[@]}"
        ok "Cluster created: ${CLUSTER_NAME}"
    fi

    # Fetch credentials (always, even if cluster already existed)
    if [[ "${dry_run}" != "--dry-run" ]]; then
        log "Fetching cluster credentials..."
        gcloud container clusters get-credentials "${CLUSTER_NAME}" \
            --project="${PROJECT}" \
            --region="${REGION}" \
            --dns-endpoint
        ok "kubectl configured (DNS endpoint)"
    fi

    # Apply shared k8s configs
    apply_shared "${dry_run}"

    # Create secondary pool (with sysctl config)
    header "Creating Secondary Pool"
    if gcloud container node-pools describe secondary-pool --cluster="${CLUSTER_NAME}" --project="${PROJECT}" --region="${REGION}" &>/dev/null; then
        ok "Secondary pool already exists"
    else
        local sysctl_config="${SECONDARY_SYSTEM_CONFIG:-}"
        local -a secondary_cmd=(
            gcloud beta container node-pools create secondary-pool
            --cluster="${CLUSTER_NAME}"
            --project="${PROJECT}"
            --region="${REGION}"
            --machine-type="${SECONDARY_MACHINE_TYPE}"
            --disk-type="${SECONDARY_DISK_TYPE}"
            --disk-size="${SECONDARY_DISK_SIZE}"
            --image-type="${SECONDARY_IMAGE_TYPE}"
            --num-nodes="${SECONDARY_NUM_NODES}"
            --max-pods-per-node="${SECONDARY_MAX_PODS_PER_NODE}"
            --location-policy="${SECONDARY_LOCATION_POLICY}"
            --logging-variant=MAX_THROUGHPUT
            --scopes=https://www.googleapis.com/auth/cloud-platform
            --service-account="gke-secondary@${PROJECT}.iam.gserviceaccount.com"
            --workload-metadata=GKE_METADATA
            --metadata=disable-legacy-endpoints=true
            --pod-ipv4-range="${SECONDARY_PODS_RANGE_NAME}"
        )
        # Autoscaling
        if [[ "${SECONDARY_AUTOSCALING}" == "true" ]]; then
            secondary_cmd+=(--enable-autoscaling)
            secondary_cmd+=(--total-min-nodes="${SECONDARY_MIN_NODES}")
            secondary_cmd+=(--total-max-nodes="${SECONDARY_MAX_NODES}")
        else
            secondary_cmd+=(--no-enable-autoscaling)
        fi
        # Upgrade strategy
        [[ -n "${SECONDARY_MAX_SURGE}" ]] && secondary_cmd+=(--max-surge-upgrade="${SECONDARY_MAX_SURGE}")
        [[ -n "${SECONDARY_MAX_UNAVAILABLE}" ]] && secondary_cmd+=(--max-unavailable-upgrade="${SECONDARY_MAX_UNAVAILABLE}")
        # Spot VMs
        [[ "${SECONDARY_SPOT}" == "true" ]] && secondary_cmd+=(--spot)
        # gVNIC
        [[ "${SECONDARY_GVNIC}" == "true" ]] && secondary_cmd+=(--enable-gvnic)
        # Shielded instance
        [[ "${SECONDARY_SHIELDED_SECURE_BOOT}" == "true" ]] && secondary_cmd+=(--shielded-secure-boot)
        [[ "${SECONDARY_SHIELDED_INTEGRITY}" == "true" ]] && secondary_cmd+=(--shielded-integrity-monitoring)
        # Nested virtualization
        if [[ "${SECONDARY_NESTED_VIRT}" == "true" ]]; then
            secondary_cmd+=(--enable-nested-virtualization)
        elif [[ "${SECONDARY_NESTED_VIRT}" == "false" ]]; then
            secondary_cmd+=(--no-enable-nested-virtualization)
        fi
        # Threads per core
        [[ -n "${SECONDARY_THREADS_PER_CORE}" ]] && secondary_cmd+=(--threads-per-core="${SECONDARY_THREADS_PER_CORE}")
        # Management
        [[ "${SECONDARY_AUTO_REPAIR}" == "true" ]] && secondary_cmd+=(--enable-autorepair) || secondary_cmd+=(--no-enable-autorepair)
        [[ "${SECONDARY_AUTO_UPGRADE}" == "true" ]] && secondary_cmd+=(--enable-autoupgrade) || secondary_cmd+=(--no-enable-autoupgrade)
        # Labels, tags, taints
        [[ -n "${SECONDARY_TAGS}" ]] && secondary_cmd+=(--tags="${SECONDARY_TAGS}")
        [[ -n "${SECONDARY_LABELS}" ]] && secondary_cmd+=(--node-labels="${SECONDARY_LABELS}")
        [[ -n "${SECONDARY_TAINTS}" ]] && secondary_cmd+=(--node-taints="${SECONDARY_TAINTS}")
        # Sysctl config
        if [[ -n "${sysctl_config}" ]] && [[ -f "${sysctl_config}" ]]; then
            secondary_cmd+=(--system-config-from-file="${sysctl_config}")
            log "Using sysctl config: ${sysctl_config}"
        fi
        # Sandbox runtime (gVisor)
        [[ -n "${SECONDARY_SANDBOX_TYPE}" ]] && secondary_cmd+=(--sandbox "type=${SECONDARY_SANDBOX_TYPE}")
        # GCFS (container image streaming at node level)
        [[ "${SECONDARY_GCFS}" == "true" ]] && secondary_cmd+=(--enable-gcfs)
        secondary_cmd+=(--quiet)

        exec_or_dry "${dry_run}" "${secondary_cmd[@]}"
        ok "Secondary pool created"
    fi

    echo ""
    ok "Cluster ready: ${CLUSTER_NAME} in ${REGION}"
    log "  Default pool:   ${MACHINE_TYPE} (${NUM_NODES} nodes per zone, static)"
    log "  Secondary pool: ${SECONDARY_MACHINE_TYPE} (${SECONDARY_MIN_NODES}-${SECONDARY_MAX_NODES} nodes)"
    log "  Dataplane:      DPv2 Scale-Optimized Mode"
    log ""
    log "  Next: ./cluster.sh apply  (applies gke/secondary/ manifests)"
}

# ---------------------------------------------------------------------------
# Shared k8s configs (applied during create)
# ---------------------------------------------------------------------------
apply_shared() {
    local dry_run="${1:-}"
    local shared_dir="${SCRIPT_DIR}/gke/shared"

    header "Applying Shared K8s Configs"

    # Cilium config override (requires field-manager patch)
    if [[ -f "${shared_dir}/cilium-config-override.yaml" ]]; then
        log "Patching Cilium config override..."
        if [[ "${dry_run}" == "--dry-run" ]]; then
            warn "DRY RUN — would patch cilium-config-emergency-override (field-manager)"
            warn "DRY RUN — would restart anetd DaemonSet"
        else
            local cilium_patch
            cilium_patch="$(kubectl create \
                -f "${shared_dir}/cilium-config-override.yaml" \
                --dry-run=client -o json \
                | python3 -c 'import json,sys; cm=json.load(sys.stdin); print(json.dumps({"data": cm["data"]}))')"
            kubectl patch -n kube-system cm/cilium-config-emergency-override \
                --field-manager="cilium-override" \
                --type=merge \
                -p "${cilium_patch}"
            ok "Cilium config override patched"

            log "Restarting anetd DaemonSet..."
            kubectl -n kube-system rollout restart daemonset/anetd
            kubectl -n kube-system rollout status daemonset/anetd --timeout=120s
            ok "anetd restarted"
        fi
    fi

    # Monitoring resources (ClusterPodMonitoring, PodMonitoring, ClusterNodeMonitoring)
    local monitoring_files=(
        "cilium-pod-monitoring.yaml"
        "controller-pod-monitoring.yaml"
        "kubelet-extra-monitoring.yaml"
    )
    for mf in "${monitoring_files[@]}"; do
        if [[ -f "${shared_dir}/${mf}" ]]; then
            log "Applying ${mf}..."
            if [[ "${dry_run}" == "--dry-run" ]]; then
                warn "DRY RUN — would kubectl apply ${mf}"
            else
                kubectl apply -f "${shared_dir}/${mf}"
                ok "${mf} applied"
            fi
        fi
    done

    # Conntrack reporter DaemonSet (prometheus-to-sd → Cloud Monitoring)
    # Requires Workload Identity binding for the conntrack-reporter KSA
    if [[ -f "${shared_dir}/netd-conntrack-monitoring.yaml" ]]; then
        log "Applying conntrack reporter..."
        if [[ "${dry_run}" == "--dry-run" ]]; then
            warn "DRY RUN — would create WI binding and apply conntrack reporter"
        else
            # Ensure WI binding exists (idempotent)
            gcloud iam service-accounts add-iam-policy-binding \
                "gke-default@${PROJECT}.iam.gserviceaccount.com" \
                --role=roles/iam.workloadIdentityUser \
                --member="serviceAccount:${PROJECT}.svc.id.goog[gmp-public/conntrack-reporter]" \
                --project="${PROJECT}" --quiet 2>/dev/null || true
            sed "s|PROJECT_ID|${PROJECT}|g" "${shared_dir}/netd-conntrack-monitoring.yaml" \
                | kubectl apply -f -
            ok "Conntrack reporter applied"
        fi
    fi

    # gVisor metrics reporter DaemonSet (prometheus-to-sd → Cloud Monitoring)
    # Reuses the conntrack-reporter KSA (same WI binding)
    if [[ -f "${shared_dir}/runsc-pod-monitoring.yaml" ]]; then
        log "Applying gVisor metrics reporter..."
        if [[ "${dry_run}" == "--dry-run" ]]; then
            warn "DRY RUN — would kubectl apply runsc-pod-monitoring"
        else
            kubectl apply -f "${shared_dir}/runsc-pod-monitoring.yaml"
            ok "gVisor metrics reporter applied"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Stage 2: APPLY — secondary pool k8s configs
# ---------------------------------------------------------------------------
cmd_apply() {
    local dry_run="${1:-}"
    validate

    local secondary_dir="${SCRIPT_DIR}/gke/secondary"
    header "Applying Secondary Pool K8s Configs"

    # Apply all YAML files in gke/secondary/ (skip node-system-config.yaml)
    local found=0
    for f in "${secondary_dir}"/*.yaml; do
        [[ -f "${f}" ]] || continue
        local basename
        basename="$(basename "${f}")"
        # Skip the node system config (used by gcloud, not kubectl)
        [[ "${basename}" == "node-system-config.yaml" ]] && continue
        found=1
        log "Applying ${basename}..."
        if [[ "${dry_run}" == "--dry-run" ]]; then
            warn "DRY RUN — would kubectl apply -f ${basename}"
        else
            kubectl apply -f "${f}"
            ok "${basename} applied"
        fi
    done

    if [[ "${found}" -eq 0 ]]; then
        warn "No applicable YAML files found in ${secondary_dir}/"
    fi

    ok "Secondary configs applied"
}

# ---------------------------------------------------------------------------
# DELETE — cluster only (VPC preserved)
# ---------------------------------------------------------------------------
cmd_delete() {
    local dry_run="${1:-}"
    validate

    header "Deleting Cluster: ${CLUSTER_NAME}"
    warn "VPC '${VPC}' and subnet '${SUBNET}' will be preserved"

    local -a cmd=(
        gcloud container clusters delete "${CLUSTER_NAME}"
        --project="${PROJECT}"
        --region="${REGION}"
        --quiet
    )

    exec_or_dry "${dry_run}" "${cmd[@]}"
    ok "Cluster deleted: ${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# STATUS
# ---------------------------------------------------------------------------
cmd_status() {
    validate

    header "Cluster: ${CLUSTER_NAME}"
    gcloud container clusters describe "${CLUSTER_NAME}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --format="table(
            name,
            status,
            location,
            currentMasterVersion,
            currentNodeCount,
            nodePools[].name.list():label='NODE_POOLS',
            nodePools[].config.machineType.list():label='MACHINE_TYPES'
        )" 2>/dev/null || warn "Cluster not found or not accessible"

    echo ""
    header "Node Pools"
    gcloud container node-pools list \
        --cluster="${CLUSTER_NAME}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --format="table(
            name,
            config.machineType,
            autoscaling.enabled,
            autoscaling.totalMinNodeCount,
            autoscaling.totalMaxNodeCount,
            status
        )" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
GKE Cluster Lifecycle Script

Usage:
  ./cluster.sh create  [--dry-run]   VPC + subnet + cluster + secondary pool + shared configs
  ./cluster.sh apply   [--dry-run]   Apply gke/secondary/ manifests
  ./cluster.sh delete  [--dry-run]   Delete cluster (preserves VPC)
  ./cluster.sh status                Show cluster + node pool info

Configuration: .env (same directory as this script)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local action="${1:-}"
    local flag="${2:-}"

    case "${action}" in
        create) cmd_create "${flag}" ;;
        apply)  cmd_apply "${flag}" ;;
        delete) cmd_delete "${flag}" ;;
        status) cmd_status ;;
        *)      usage; exit 1 ;;
    esac
}

main "$@"
