# Sandbox Detach/Claim OwnerReferences Fix

## Summary

Updated the sandbox provisioning logic to fix an edge case where the Kubernetes
ReplicaSet controller gets stuck with unsatisfied Expectations. Previously,
"detaching" a sandbox pod from the warmpool only changed the `warmpool` label to
`"false"`. This left the pod's `ownerReferences` pointing to the ReplicaSet,
forcing the RS controller to run its internal `ReleasePod` logic — an extra API
PATCH that can `409 Conflict` with the custom controller, wedging the RS
Expectations and preventing pod replenishment until a manual `rollout restart`.

The provision patch now atomically sets `"ownerReferences": []` alongside the
label change in a single JSON Merge Patch. This bypasses the RS Release path
entirely, letting the ReplicaSet immediately see the deficit and create a
replacement pod.

## Root Cause

The RS controller's `ClaimObject` method sees an owned pod with mismatched
labels and calls `ReleasePod` to remove its `controllerRef`. If this Release
patch races with the custom controller's provision patch on the same pod, a
`409 Conflict` can break the RS Expectations counter. The RS then blocks at
`SatisfiedExpectations` until the 5-minute timeout — or indefinitely if the
conflict repeats.

## Fix

Single-line change in `handleProvision`: add `"ownerReferences":[]` to the
existing JSON merge patch payload. The RS controller now sees the pod as an
orphan with a non-matching selector and skips both the Release and adoption
paths.

## List of Modified Files

- `app/controller/handlers.go` — Added `ownerReferences:[]` to the claim patch
- `app/controller/handlers_test.go` — **[NEW]** Unit tests verifying the patch
  payload structure and patch type (MergePatch, not StrategicMergePatch)
- `app/tests/test-detach-comparison.sh` — **[NEW]** Live comparison test
  showing dirty (label-only) vs clean (label+ownerRef) detach behavior with
  RS controller log evidence

## Verification Steps

1. Unit tests pass: `cd app/controller && go test -v -run TestProvision ./...`
2. Live cluster test: deployed to GKE, claimed a pod, verified:
   - `ownerReferences` cleared on claimed pod
   - RS immediately created replacement (same second)
   - No RS `"Patching pod to remove its controllerRef"` log with clean detach
3. Comparison test: `app/tests/test-detach-comparison.sh` shows the RS Release
   log entry with dirty detach, absent with clean detach
