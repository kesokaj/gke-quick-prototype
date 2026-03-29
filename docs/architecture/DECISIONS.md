# Architectural Decision Records

## ADR-001: Single-Script Cluster Lifecycle

**Date:** 2026-03-25
**Status:** Accepted

### Context

The project needed a repeatable way to create, configure, update, and delete GKE clusters with consistent settings.

### Decision

- **Single entrypoint** (`cluster.sh`) with subcommands instead of separate scripts
- **`.env`-driven config** — every tuneable value lives in `.env`, script uses fallback defaults
- **Two-stage workflow** — `create` handles infrastructure (VPC, subnet, cluster, shared k8s configs, secondary pool); `apply` handles workload-specific configs
- **VPC lifecycle in create** — VPC + subnet created idempotently during `create`, preserved on `delete`
- **Shared configs applied during create** — cilium override (field-manager), kube-dns autoscaler, and monitoring are applied before secondary pool creation
- **Dry-run on all mutating commands** — `--dry-run` flag prints exact gcloud/kubectl commands without executing

### Consequences

- Simple onboarding: clone, edit `.env`, run `./cluster.sh create`
- K8s configs organized by scope: `gke/shared/` (cluster-wide) and `gke/secondary/` (pool-specific)
- VPC must be manually deleted after cluster teardown (safety measure)

## ADR-002: Conditional Cluster Features + gVisor Sandbox

**Date:** 2026-03-28
**Status:** Accepted

### Context

Needed to replicate a production GKE cluster config (COS + gVisor sandbox, Cloud DNS, cost allocation, Secret Manager, fleet registration) while keeping the script flexible for different environments.

### Decision

- **Cluster features as conditional flags** — VPA, HPA profile, Cloud DNS, DNS cache, Filestore CSI, image streaming, cost allocation, Secret Manager, and fleet are all controlled via `.env` toggles. Only non-empty/true values generate gcloud flags.
- **Secondary pool uses gVisor** — `--sandbox type=gvisor` with COS_CONTAINERD image. Nested virtualization removed (not needed with gVisor).
- **Sysctl config is variable-driven** — `SECONDARY_SYSTEM_CONFIG` path in `.env` instead of hardcoded file lookup. Empty = skip.
- **GCFS at node pool level** — Image streaming enabled on secondary pool via `--enable-gcfs`, not cluster-wide.
- **Fleet defaults to PROJECT** — `FLEET_PROJECT` falls back to `${PROJECT}` if not explicitly set.

### Consequences

- All cluster features visible and tuneable in `.env`
- Script logic unchanged — only values and conditional flags differ
- Easy to toggle features on/off per environment
