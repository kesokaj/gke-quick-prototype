# Standardize Cilium Identity Label Exclusion

**Date**: 2026-03-31

## Summary

Integrated the Cilium identity label exclusion patch into the standard `cluster.sh` deployment lifecycle and unified all high-cardinality sandbox labels (`warmpool`, `agents.x-k8s.io/sandbox-name-hash`, `pool`) into a single, shared configuration file (`gke/shared/cilium-identity-labels-patch.yaml`).

## Problem

Previously, the Dataplane V2 identity label workaround was applied via a separate manual script (`gke/manual/apply-cilium-identity-labels.sh`). Several different patch iterations existed for excluding different labels, requiring administrators to manually execute the multi-step workaround to reduce Cilium identity churn.

## Solution

1. **Unified Exclusions**: Combined all high-churn endpoint labels into a single `gke/shared/cilium-identity-labels-patch.yaml` file (`!warmpool !agents.x-k8s.io/sandbox-name-hash !pool`).
2. **Standardized Application**: Added the official [GKE Dataplane V2 workaround](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/dataplane-v2#identity-relevant-label-filtering-issue) sequence directly to `cluster.sh` within the `apply_shared()` phase:
   - Cleans the deprecated `cilium-config-emergency-override`.
   - Patches the `labels` field in the main `cilium-config` ConfigMap.
   - Automatically executes a same-version control plane upgrade to reload the `anet-operator`.
   - Automates a rolling restart of the `anetd` DaemonSet to propagate changes to endpoints.
3. **Clean Up**: Deleted the deprecated `gke/manual/` scripts and fragmented patch configurations from previous iterations.

## Modified Files
- `cluster.sh`
- `docs/architecture/DECISIONS.md` (ADR-003)

## Created Files
- `gke/shared/cilium-identity-labels-patch.yaml`

## Deleted Files
- `gke/manual/apply-cilium-identity-labels.sh`
- `gke/manual/cilium-identity-labels-patch.yaml`
- `gke/manual/cilium-identity-labels-exclude-agent.yaml`

## Verification
- Running `./cluster.sh create` or `./cluster.sh apply` now natively executes the Dataplane V2 workaround, logs the control plane upgrade process, and guarantees stable identity assignment for idle and claimed sandboxes.
