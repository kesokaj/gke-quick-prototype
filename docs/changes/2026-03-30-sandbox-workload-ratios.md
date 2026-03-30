# Sandbox Workload Ratio Tuning & Audit

## Summary

Adjusted the sandbox-sim workload distribution to be more conservative and realistic.
Added phase/tier visibility to the `/_sandbox/status` endpoint. Cleaned up dead code.

## Changes

### Disk Write Ratios (Phase 2)
- **Before:** 70% → 500MB, 20% → 1GB, 7% → 3GB, 3% → 3-10GB
- **After:** 90% → 500MB, 8% → 1GB, 2% → 3GB (removed 3-10GB tier)

### CPU Load Loop (Phase 3)
- **Tier selection (Before):** 70% light (1-2 cores), 20% medium (3-4 cores), 10% heavy (all cores)
- **Tier selection (After):** 90% light (300m duty-cycled), 8% medium (1 full core), 2% heavy (all cores)
- **Duty-cycling:** Added 100ms window burn/sleep cycle for sub-core CPU targets. Light tier burns 30ms/sleeps 70ms per window = ~300m in `kubectl top`.
- **State changes:** Changed from weighted rolls (15/30/25/20/10%) with random 3-20s duration to equal probability (20% each of idle/light/moderate/heavy/peak) with fixed 30s hold.

### Status Endpoint Visibility
- Added `phase` field: cycles through `idle` → `download` → `disk` → `load`
- Added `cpuTier` field: `light`, `medium`, or `heavy`
- Added `dutyPct` field: duty cycle percentage (0.30 for 300m)

### Code Audit Fixes
- Removed dead `burstDisk()` function (never called)
- Fixed stale scenario log message (still referenced "500 MB-10 GB")
- Updated section comments to match current behavior

## Modified Files
- `app/sandbox/main.go` — all changes above

## Verification
- Built and pushed `sandbox-sim:baf1748-1774897477`
- Deployed to GKE with 3 replicas
- Verified idle pod status: `{"phase":"idle","cpuTier":"","dutyPct":0.00}`
- Claimed sandbox, verified activated status: `{"phase":"load","cpuTier":"light","dutyPct":0.30}`
- Sampled `kubectl top` over 4 intervals: 71m, 251m, 312m, 60m — matches expected ~300m with idle state cycling
