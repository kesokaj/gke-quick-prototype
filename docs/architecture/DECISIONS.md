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
- K8s configs organized by scope: `k8s/shared/` (cluster-wide) and `k8s/secondary/` (pool-specific)
- VPC must be manually deleted after cluster teardown (safety measure)
