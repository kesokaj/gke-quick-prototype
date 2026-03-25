# 2026-03-25 — GKE Cluster Management Scripts

## Summary

Refactored `create.sh` into `cluster.sh` with a two-stage workflow and organized k8s/ configs.

## Changes

| File | Action | Description |
|---|---|---|
| `.env` | Modified | All configurable variables (project, network, pools) |
| `cluster.sh` | New | Single entrypoint: create/apply/update/delete/status |
| `k8s/shared/` | New dir | Cluster-wide configs (cilium, kube-dns, monitoring) |
| `k8s/secondary/` | New dir | Secondary pool configs (CCC, sysctl) |
| `k8s/secondary/compute-class.yaml` | New | Custom Compute Class for secondary pool |
| `create.sh` | Deleted | Replaced by `cluster.sh` |

## Workflow

```bash
./cluster.sh create  [--dry-run]   # Stage 1: VPC + subnet + cluster + shared configs + secondary pool
./cluster.sh apply   [--dry-run]   # Stage 2: Apply k8s/secondary/ configs
./cluster.sh update  [--dry-run]   # Update mutable settings
./cluster.sh delete  [--dry-run]   # Delete cluster (preserves VPC)
./cluster.sh status                # Show cluster info
```

## Verification

- `bash -n cluster.sh` — syntax OK
- `./cluster.sh create --dry-run` — all gcloud + kubectl commands verified
- `./cluster.sh apply --dry-run` — kubectl apply verified
- `./cluster.sh delete --dry-run` — gcloud delete verified
