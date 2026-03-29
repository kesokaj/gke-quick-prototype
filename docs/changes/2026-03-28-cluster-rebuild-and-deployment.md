# 2026-03-28: Cluster Rebuild & App Deployment

## Summary

Rebuilt the GKE cluster from scratch with corrected naming, API enablement, and infrastructure fixes. Deployed the sandbox application (controller + simulation pods) successfully.

## Changes

### cluster.sh
- **Added `ensure_apis` function** — idempotent API enablement as the first step in `cmd_create`. 25 curated APIs covering compute, networking, observability, security, build, storage, fleet, and resource management.
- **Added `CLUSTER_VERSION` support** — optional pinned K8s version via `.env` (`1.34.4-gke.1047000`).
- **Added `VPC_MTU` support** — configurable VPC MTU via `.env` (set to `1500`).
- **Added `SECONDARY_PODS_RANGE`** — separate pod CIDR (`10.50.0.0/16`) for the secondary (gVisor) pool, isolated from the default pool's pod range (`10.100.0.0/16`).
- **Added L4 ILB Subsetting** — `--enable-l4-ilb-subsetting` with required `HttpLoadBalancing` addon.
- **Fixed `--addons` flag** — GKE only accepts a single `--addons` flag. Consolidated `HttpLoadBalancing`, `NodeLocalDNS`, and `GcpFilestoreCsiDriver` into a single comma-separated string.

### app/deploy.sh
- **Fixed `--condition=None`** — removed from IAM policy binding (gcloud version incompatibility).
- **Fixed `ensure_controller_service` stdout pollution** — log/ok messages redirected to stderr so only the URL is captured by the caller.
- **Fixed grep regex error** — switched to `grep -F` for literal string matching on Workload Identity member strings containing `[]` characters.

### .env
- Added `CLUSTER_VERSION`, `VPC_MTU`, `SECONDARY_PODS_RANGE_NAME`, `SECONDARY_PODS_RANGE`, `ENABLE_L4_ILB_SUBSETTING`.
- Declarative naming: `sandbox-gke`, `sandbox-vpc`, `sandbox-subnet-europe-west4`.

## Modified Files
- `cluster.sh`
- `app/deploy.sh`
- `.env`

## Verification
- Cluster `sandbox-gke` created in `europe-west4` with v1.34.4-gke.1047000
- VPC MTU confirmed at 1500
- L4 ILB Subsetting enabled
- Subnet has 3 secondary ranges: `pods` (10.100.0.0/16), `secondary-pods` (10.50.0.0/16), `services` (10.200.0.0/20)
- All 25 GCP APIs enabled
- Cilium config override verified in running agent
- Controller: 2 replicas running on default pool (10.100.x.x)
- Sandbox: 2 replicas running on secondary pool with gVisor (10.50.x.x)
- Workload Identity binding active
- NetworkPolicy applied
