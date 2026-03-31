# GKE Sandbox Infrastructure

Idempotent, `.env`-driven GKE cluster lifecycle management with gVisor sandboxing, warm pool controller, and full observability.

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **gcloud CLI** | GCP resource management | [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install) |
| **kubectl** | Kubernetes cluster access | `gcloud components install kubectl` |
| **Docker** | Container image builds (ARM Mac → AMD64) | Docker Desktop or [Colima](https://github.com/abiosoft/colima) |
| **Go 1.24+** | Local builds and `go vet` | [go.dev/dl](https://go.dev/dl/) |
| **python3** | Cilium config JSON extraction (used by cluster.sh) | System default or Homebrew |

> **Note:** `gcloud auth login` and `gcloud auth configure-docker ${REGION}-docker.pkg.dev` must be run before first use.

## Quick Start — Zero to Running

```bash
# 1. Configure
cp .env.example .env
vim .env                            # Set PROJECT, CLUSTER_NAME, VPC, etc.

# 2. Create cluster (VPC + subnet + GKE + node pools + monitoring)
./cluster.sh create

# 3. Build, push, and deploy app (controller + sandbox pods + ws-server)
cd app && ./deploy.sh all 5         # 5 = sandbox pool size

# 4. (Optional) Deploy GCP monitoring dashboard
cd ../gcp && ./deploy-dashboard.sh

# 5. Verify
./cluster.sh status
kubectl get pods -n sandbox -l warmpool=true
kubectl get pods -n sandbox-control
```

### What Gets Created

| Stage | Script | Resources |
|-------|--------|-----------|
| **Infrastructure** | `cluster.sh create` | VPC, subnet, firewall rules, Cloud NAT, GKE cluster, 2 node pools, service accounts, Cilium config, monitoring DaemonSets |
| **Application** | `deploy.sh all` | Sandbox controller (1 replica), sandbox pool (N replicas), ws-server on Cloud Run, Workload Identity bindings, NetworkPolicy |
| **Observability** | `deploy-dashboard.sh` | GCP Monitoring dashboard with sandbox lifecycle, kubelet, Cilium, and API server metrics |

## Configuration

All settings are in **`.env`**. Copy from `.env.example` and customize.

### Key Sections

| Section | What it controls |
|---------|------------------|
| **Project & Region** | GCP project, cluster name, region, release channel |
| **Network** | VPC, subnet, CIDR ranges, Cloud NAT toggle |
| **Default Pool** | Machine type, disk, node count, shielded, auto-repair/upgrade |
| **Secondary Pool** | Machine type, disk, image, autoscaling, spot, gVisor, GCFS, shielded, tags, labels, taints |
| **Cluster Features** | Autoscaling profile, VPA, HPA, Cloud DNS, DNS cache, ILB subsetting, Filestore CSI, image streaming, cost allocation, Secret Manager, fleet |

### Optional Flags Pattern

Leave a value **empty** in `.env` to skip the flag entirely (gcloud defaults apply):

```bash
SECONDARY_GVNIC=""              # Flag not used — gcloud default
SECONDARY_GVNIC="true"          # --enable-gvnic added
```

### Dependent Settings

```bash
# Autoscaling requires MIN/MAX when enabled
SECONDARY_AUTOSCALING="true"
SECONDARY_MIN_NODES="0"        # Required when AUTOSCALING=true
SECONDARY_MAX_NODES="100"      # Required when AUTOSCALING=true

# Nested virtualization requires threads-per-core
SECONDARY_NESTED_VIRT="true"
SECONDARY_THREADS_PER_CORE="2"  # Required when NESTED_VIRT=true
```

> **Note:** `AUTO_UPGRADE` must be `true` when using a release channel (RAPID/REGULAR/STABLE).

## Commands

### Infrastructure (`cluster.sh`)

```bash
./cluster.sh create  [--dry-run]   # VPC + subnet + cluster + secondary pool + shared configs
./cluster.sh apply   [--dry-run]   # Apply gke/secondary/ manifests (optional per-pool configs)
./cluster.sh delete  [--dry-run]   # Delete cluster (preserves VPC)
./cluster.sh status                # Show cluster + node pool info
```

### Application (`app/deploy.sh`)

```bash
./deploy.sh build                  # Build container images locally (ARM Mac → AMD64)
./deploy.sh push                   # Push to Google Artifact Registry
./deploy.sh deploy [REPLICAS]      # Apply K8s manifests (default: 5)
./deploy.sh all [REPLICAS]         # Build + push + deploy
./deploy.sh teardown               # Delete all app resources + Cloud Run + monitoring
```

Use `--dry-run` to preview gcloud commands without executing them.

## Operations

```bash
# Watch sandbox pods
kubectl get pods -n sandbox -l warmpool=true -w

# Controller logs
kubectl logs -n sandbox-control deploy/sandbox-controller -f

# Controller UI (port-forward)
kubectl port-forward -n sandbox-control svc/sandbox-controller 8080:8080

# WS Server logs (Cloud Run)
gcloud run services logs read sandbox-ws-server --region=${REGION} --limit=50

# Teardown everything
cd app && ./deploy.sh teardown
```

## Shared K8s Configs

Applied automatically during `./cluster.sh create`:

| File | Purpose |
|------|---------|
| `gke/shared/cilium-config-override.yaml` | DPv2 scale-optimized tuning (monitor aggregation, eBPF map sizes, rate limits) |
| `gke/shared/cilium-pod-monitoring.yaml` | GMP `ClusterPodMonitoring` for anetd (port 9990, 10s) |
| `gke/shared/netd-conntrack-monitoring.yaml` | `prometheus-to-sd` DaemonSet pushing conntrack/socket metrics to Cloud Monitoring (all nodes) |
| `gke/shared/runsc-pod-monitoring.yaml` | `prometheus-to-sd` DaemonSet pushing gVisor runtime metrics to Cloud Monitoring (gVisor nodes only) |
| `gke/shared/controller-pod-monitoring.yaml` | GMP `PodMonitoring` for sandbox-controller (port 8080, 10s) |
| `gke/shared/kubelet-extra-monitoring.yaml` | GMP `ClusterNodeMonitoring` for kubelet metrics (10s) |

## Project Structure

```
.
├── .env                                # All configuration
├── cluster.sh                          # Infrastructure lifecycle
├── app/
│   ├── controller/                     # Warm pool controller (Go)
│   ├── sandbox/                        # Simulation pod binary (Go)
│   ├── ws-server/                      # WebSocket session server (Go, Cloud Run)
│   ├── manifests/                      # K8s manifests (namespaces, controller, deployment, netpol)
│   ├── tests/                          # Benchmark + monitoring scripts
│   └── deploy.sh                       # Build, push, and deploy script
├── gke/
│   ├── shared/                         # Applied during cluster create
│   │   ├── cilium-config-override.yaml
│   │   ├── cilium-identity-labels-patch.yaml  # Identity label exclusion (warmpool, agent, pool)
│   │   ├── cilium-pod-monitoring.yaml
│   │   ├── netd-conntrack-monitoring.yaml     # prometheus-to-sd → Cloud Monitoring (conntrack)
│   │   ├── runsc-pod-monitoring.yaml           # prometheus-to-sd → Cloud Monitoring (gVisor)
│   │   ├── controller-pod-monitoring.yaml
│   │   └── kubelet-extra-monitoring.yaml
│   └── secondary/                      # Secondary pool configs (optional)
├── gcp/
│   ├── dashboard.json.tpl              # GCP Monitoring dashboard template (__CLUSTER_NAME__ placeholder)
│   └── deploy-dashboard.sh             # Dashboard deploy script (delete + create)
├── docs/
│   ├── changes/                        # Change logs
│   ├── architecture/                   # ADRs
│   └── specs/                          # Integration specs
└── README.md
```
