# Add Cilium Identity Label Exclusion Script

**Date**: 2026-03-30

## Summary

Created `gke/manual/apply-cilium-identity-labels.sh` — a script to apply and revert the Cilium identity label exclusion patch (`!warmpool`) following the official GKE Dataplane V2 workaround.

## Problem

When sandbox pods are claimed, the `warmpool` label changes from `true` to `false`. Without exclusion, Cilium creates a new security identity for each label combination, causing unnecessary identity churn and endpoint regeneration.

## Solution

The script follows the official [GKE Dataplane V2 workaround](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/dataplane-v2#identity-relevant-label-filtering-issue) (4-step procedure):

1. **Clean up** `cilium-config-emergency-override` — remove `data.labels` key if present (emergency-override is broken for this on v1.34/1.35)
2. **Patch** `cilium-config.data.labels` with `!warmpool`
3. **Restart anet-operator** via same-version control plane upgrade (`gcloud container clusters upgrade --master`)
4. **Rolling restart** of `anetd` DaemonSet

Additional features:
- Automatic timestamped backup of `cilium-config` before patching
- `--dry-run` mode for safe previewing
- `revert` command to remove the labels key
- `status` command for quick verification
- `--labels` flag for custom exclusions

## Commands

```bash
./gke/manual/apply-cilium-identity-labels.sh status             # Show current state
./gke/manual/apply-cilium-identity-labels.sh apply              # Full apply (with master upgrade)
./gke/manual/apply-cilium-identity-labels.sh apply --skip-master # Skip master upgrade
./gke/manual/apply-cilium-identity-labels.sh revert             # Remove exclusion
./gke/manual/apply-cilium-identity-labels.sh apply --dry-run    # Preview only
```

## New Files

- `gke/manual/apply-cilium-identity-labels.sh` — Apply/revert automation script
- `gke/manual/cilium-identity-labels-exclude-agent.yaml` — Extended patch for agent+pool labels
- `gke/manual/.gitignore` — Ignore backup JSON files

## Verification

- `status` confirms `cilium-config.data.labels = !warmpool` and `emergency-override` is clean
- All sandbox pods share a single Cilium identity regardless of warmpool state
- Smoke tests confirmed pods still schedule and network correctly after the change
- `anetd` DaemonSet rolled out with all 6/6 pods healthy
