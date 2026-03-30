# Recreatability Audit Fixes

**Date:** 2026-03-30
**Scope:** 6 recreation gaps fixed to enable zero-to-running setup from a fresh clone.

## Summary

Traced the full recreation path (clone → .env → cluster.sh create → deploy.sh all → dashboard) and fixed 6 gaps that would cause failures or confusion.

## Changes

### cluster.sh

- **G-1:** Added `run.googleapis.com` to `ensure_apis()` — Cloud Run deploy fails without this on a fresh project
- **G-2:** Moved `--enable-l4-ilb-subsetting` from unconditional to conditional (`[[ "${ENABLE_L4_ILB_SUBSETTING}" == "true" ]]`) — previously ignored the `.env` setting
- **G-6:** Aligned 6 fallback defaults with `.env.example` values:
  - `CLUSTER_NAME`: `sandbox-testing` → `my-cluster`
  - `VPC`: `kfg-network` → `my-network`
  - `SUBNET`: `kfg-subnet-*` → `my-subnet-*`
  - `RELEASE_CHANNEL`: `rapid` → `REGULAR`
  - `DEFAULT_AUTO_UPGRADE`: `false` → `true`
  - `SECONDARY_AUTOSCALING`: `true` → `false`
  - `SECONDARY_AUTO_UPGRADE`: `false` → `true`

### app/deploy.sh

- **G-3:** Added kubectl context sanity check in `validate()` — warns if current context doesn't match `CLUSTER_NAME`
- **G-5:** Added cleanup for cluster-scoped monitoring resources in `cmd_teardown()` — `ClusterNodeMonitoring`, conntrack DaemonSet, gVisor DaemonSet now deleted

### README.md

- **G-4:** Rewrote root README with:
  - Prerequisites table (gcloud, kubectl, docker, go, python3)
  - Numbered "Zero to Running" setup steps covering all scripts
  - Operations section with day-to-day commands
  - Complete project structure tree

## Modified Files

- `cluster.sh` (G-1, G-2, G-6)
- `app/deploy.sh` (G-3, G-5)
- `README.md` (G-4)

## Verification

```bash
bash -n cluster.sh    # ✓ syntax OK
bash -n app/deploy.sh # ✓ syntax OK
```
