# GKE Cluster Lifecycle

Idempotent, `.env`-driven GKE cluster lifecycle management with two node pools, network tuning, and DPv2 Scale-Optimized dataplane.

## Quick Start

```bash
# 1. Configure
cp .env.example .env   # or edit .env directly
vim .env

# 2. Create everything (idempotent — safe to re-run)
./cluster.sh create

# 3. Apply secondary pool k8s manifests
./cluster.sh apply

# 4. Check status
./cluster.sh status
```

## What `./cluster.sh create` Builds

All resources are created idempotently — the script detects existing resources and skips them.

| Stage | Resources |
|---|---|
| **Service Accounts** | `gke-default` + `gke-secondary` (role: owner) |
| **VPC** | Custom-mode VPC with subnet + secondary ranges (pods/services) |
| **Firewall Rules** | ICMP, SSH, RDP, Load Balancer healthcheck, IAP, internal |
| **Cloud NAT** | Dynamic port allocation, high-churn timeouts, 1024 min ports/VM |
| **GKE Cluster** | Private cluster, DPv2, Cloud DNS, Workload Identity, conditional addons |
| **Default Pool** | Static node count (1/zone), shielded instance |
| **Secondary Pool** | Fully configurable from `.env`, COS image, gVisor sandbox, GCFS |
| **Shared K8s Configs** | Cilium override, Cilium/netd/kubelet/controller monitoring (all 10s scrape) |

## Configuration

All settings are in **`.env`**. The file is self-documented with inline comments.

### Key Sections

| Section | What it controls |
|---|---|
| **Project & Region** | GCP project, cluster name, region, release channel |
| **Network** | VPC, subnet, CIDR ranges, Cloud NAT toggle |
| **Default Pool** | Machine type, disk, node count, shielded, auto-repair/upgrade |
| **Secondary Pool** | Machine type, disk, image, autoscaling, spot, gVisor, GCFS, shielded, tags, labels, taints |
| **Cluster Features** | Autoscaling profile, VPA, HPA, Cloud DNS, DNS cache, Filestore CSI, image streaming, cost allocation, Secret Manager, fleet |

### Optional Flags Pattern

Leave a value **empty** in `.env` to skip the flag entirely (gcloud defaults apply):

```bash
SECONDARY_GVNIC=""              # Flag not used — gcloud default
SECONDARY_GVNIC="true"          # --enable-gvnic added
```

### Dependent Settings

Some settings require companion values:

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

## Secondary Pool Node Config

The secondary pool can optionally apply a node system config file via `SECONDARY_SYSTEM_CONFIG` in `.env`. Set the path to a YAML file with kubelet and sysctl tuning. Leave empty to skip.

The pool uses **gVisor** sandbox runtime (`--sandbox type=gvisor`) and **COS_CONTAINERD** image by default. GCFS (image streaming) is enabled at the node pool level.

## Shared K8s Configs

Applied automatically during `./cluster.sh create`:

| File | Purpose |
|---|---|
| `gke/shared/cilium-config-override.yaml` | DPv2 scale-optimized tuning (monitor aggregation, eBPF map sizes, rate limits) |
| `gke/shared/cilium-pod-monitoring.yaml` | GMP `ClusterPodMonitoring` for anetd (port 9990, 10s) |
| `gke/shared/netd-conntrack-monitoring.yaml` | GMP `ClusterPodMonitoring` for conntrack/socket metrics (port 10231, 10s) |
| `gke/shared/controller-pod-monitoring.yaml` | GMP `PodMonitoring` for sandbox-controller (port 8080, 10s) |
| `gke/shared/kubelet-extra-monitoring.yaml` | GMP `ClusterNodeMonitoring` for kubelet metrics (10s) |

## Commands

```bash
./cluster.sh create  [--dry-run]   # VPC + subnet + cluster + secondary pool + shared configs
./cluster.sh apply   [--dry-run]   # Apply gke/secondary/ manifests
./cluster.sh delete  [--dry-run]   # Delete cluster (preserves VPC)
./cluster.sh status                # Show cluster + node pool info
```

Use `--dry-run` to preview gcloud commands without executing them.

## Project Structure

```
.
├── .env                                # All configuration
├── cluster.sh                          # Lifecycle entrypoint
├── app/
│   ├── controller/                     # Warm pool controller (Go)
│   ├── sandbox/                        # Simulation pod binary (Go)
│   ├── manifests/                      # K8s manifests (namespaces, controller, deployment, netpol)
│   ├── tests/                          # Benchmark + monitoring scripts
│   └── deploy.sh                       # Build, push, and deploy script
├── gke/
│   ├── shared/                         # Applied during cluster create
│   │   ├── cilium-config-override.yaml
│   │   ├── cilium-pod-monitoring.yaml
│   │   ├── netd-conntrack-monitoring.yaml
│   │   ├── controller-pod-monitoring.yaml
│   │   └── kubelet-extra-monitoring.yaml
│   ├── manual/                         # Manual-apply configs (not auto-deployed)
│   │   └── cilium-identity-labels-patch.yaml
│   └── secondary/                      # Secondary pool configs
├── gcp/
│   ├── dashboard.json.tpl              # GCP Monitoring dashboard template (__CLUSTER_NAME__ placeholder)
│   └── deploy-dashboard.sh             # Dashboard deploy script (delete + create)
└── README.md
```
