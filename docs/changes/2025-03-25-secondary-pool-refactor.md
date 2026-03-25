# 2025-03-25 — Replace NAP/CCC with Manual Secondary Pool

## Summary

Replaced Node Auto-Provisioning (NAP) and Custom Compute Class (CCC) with a manually created secondary node pool, fully configurable from `.env`. Added sysctl + kubelet config support via `--system-config-from-file`.

## Changes

### Modified
- **`cluster.sh`** — Removed NAP flags, added secondary pool creation with 21 configurable settings (all controlled from `.env` with optional flags pattern)
- **`.env`** — Expanded with full secondary pool configuration: machine type, disk, image, autoscaling, surge, spot, gvnic, shielded, nested-virt, threads-per-core, auto-repair/upgrade, tags, labels, taints. Added default pool gvnic/shielded/auto-repair/upgrade settings.

### Added
- **`k8s/secondary/node-system-config.yaml`** — Node system config (gcloud format) with kubelet `allowedUnsafeSysctls: [net.*]` and 20 sysctl tuning parameters

### Live Cluster Changes
- Disabled NAP on `kata-gke`
- Disabled autoscaling on default pool, resized to 1 node/zone
- Created `secondary-pool`: n2-standard-8, UBUNTU_CONTAINERD, nested-virt, shielded, sysctl config, autoscaling 0-100

## Key Design Decisions
- **Optional flags pattern**: Empty `.env` value = flag not used at all. Only non-empty values generate gcloud flags.
- **Auto-upgrade constraint**: GKE requires `auto_upgrade=true` when using a release channel (REGULAR/RAPID/STABLE). Documented in `.env`.
- **gcloud config format**: Uses `linuxConfig.sysctl` (singular) and `kubeletConfig`, not the Terraform field names.

## Verification
- `bash -n cluster.sh` → SYNTAX OK
- `./cluster.sh create` → All idempotent checks pass, secondary pool created successfully
- Exit code: 0
