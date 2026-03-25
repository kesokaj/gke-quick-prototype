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
| **GKE Cluster** | Private cluster, DPv2, VPA, HPA performance, Workload Identity, Filestore CSI |
| **Default Pool** | Static node count (1/zone), gVNIC, shielded instance |
| **Secondary Pool** | Fully configurable from `.env`, UBUNTU image, nested-virt, sysctl tuning |
| **Shared K8s Configs** | Cilium override, anetd restart, kube-dns autoscaler, Cilium pod monitoring |

## Configuration

All settings are in **`.env`**. The file is self-documented with inline comments.

### Key Sections

| Section | What it controls |
|---|---|
| **Project & Region** | GCP project, cluster name, region, release channel |
| **Network** | VPC, subnet, CIDR ranges, Cloud NAT toggle |
| **Default Pool** | Machine type, disk, node count, gVNIC, shielded, auto-repair/upgrade |
| **Secondary Pool** | Machine type, disk, image, autoscaling, spot, gVNIC, shielded, nested-virt, threads-per-core, tags, labels, taints |

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

## Secondary Pool Sysctl Config

The file `k8s/secondary/node-system-config.yaml` is applied via `--system-config-from-file` during pool creation. It configures:

- **kubeletConfig**: `allowedUnsafeSysctls: [net.*]` — lets pods set net sysctls via `securityContext`
- **linuxConfig.sysctl**: 20 kernel parameters for high-churn workloads (conntrack, socket buffers, TIME_WAIT, file descriptors)

## Shared K8s Configs

Applied automatically during `./cluster.sh create`:

| File | Purpose |
|---|---|
| `k8s/shared/cilium-config-override.yaml` | DPv2 scale-optimized tuning (Hubble off, eBPF map sizes, rate limits) |
| `k8s/shared/cilium-pod-monitoring.yaml` | GMP `ClusterPodMonitoring` for anetd (port 9990) |
| `k8s/shared/kube-dns-autoscaler.yaml` | 1 kube-dns replica per node |

## Commands

```bash
./cluster.sh create  [--dry-run]   # VPC + subnet + cluster + secondary pool + shared configs
./cluster.sh apply   [--dry-run]   # Apply k8s/secondary/ manifests
./cluster.sh delete  [--dry-run]   # Delete cluster (preserves VPC)
./cluster.sh status                # Show cluster + node pool info
```

Use `--dry-run` to preview gcloud commands without executing them.

## Project Structure

```
.
├── .env                                # All configuration
├── cluster.sh                          # Lifecycle entrypoint
├── k8s/
│   ├── shared/                         # Applied during cluster create
│   │   ├── cilium-config-override.yaml
│   │   ├── cilium-pod-monitoring.yaml
│   │   └── kube-dns-autoscaler.yaml
│   └── secondary/                      # Secondary pool configs
│       └── node-system-config.yaml     # Sysctl + kubelet config
├── docs/
│   ├── architecture/
│   │   └── DECISIONS.md
│   └── changes/
│       └── *.md
└── README.md
```
