# Controller Metrics Fixes

**Date**: 2026-03-30

## Summary

Fixed multiple bugs in the sandbox controller's metrics system: Reset Metrics UI button, P-value calculation accuracy, and claim-to-ready measurement correctness.

## Changes

### UI Fixes (`app/controller/ui/index.html`)

- **Reset Metrics button**: Removed `confirm()` dialog for immediate reset; fixed `refreshMetrics()` → `fetchMetricsSummary()` (was `ReferenceError: refreshMetrics is not defined`)

### Backend: P-value Interpolation (`app/controller/metrics.go`)

- Changed `histogramQuantile()` from returning raw bucket upper bounds to **linear interpolation** between bucket boundaries (matching Prometheus `histogram_quantile` behavior)
- Before: P50=5s, P95=15s, P99=15s (bucket ceilings)
- After: P50=3.75s, P95=4.88s, P99=4.97s (properly interpolated)

### Backend: Claim-to-Ready Metric (`app/controller/handlers.go`, `app/controller/reconciler.go`, `app/controller/store.go`)

**Root cause**: The claim-to-ready metric was measured in the reconciler sync loop, which had three compounding bugs:
1. **Same-cycle measurement**: `DetachedAt` was set and `time.Since(DetachedAt)` measured in the same function call → microseconds for pre-warmed pods
2. **Controller restart pollution**: On restart, already-claimed pods got `DetachedAt = time.Now()` and were re-measured with escalating durations on every sync cycle (49s → 53s → 114s)
3. **Reset re-measurement**: `ResetObservations()` cleared `ReadyObserved` for active pods, causing all claimed pods to be re-measured

**Fix**: Moved claim-to-ready recording to the provision handler (`handleProvision`), measuring the actual K8s API call latency. This gives the real user-facing claim speed (~50-100ms).

Additional hardening:
- `ResetObservations()` now only resets `ReadyObserved` for idle/pending pods
- On controller restart, pre-existing claimed pods use the `sandbox.gvisor/claimed-at` annotation for accurate `DetachedAt` and are marked as already-observed

## Modified Files

- `app/controller/ui/index.html` — Reset button fix
- `app/controller/metrics.go` — Percentile interpolation
- `app/controller/handlers.go` — Claim metric recording
- `app/controller/reconciler.go` — Removed broken reconciler metric, improved restart handling
- `app/controller/store.go` — Safe ResetObservations

## Verification

- Reset Metrics: no confirmation dialog, no JS error, metrics clear immediately
- Schedule Duration: P50=3.75s (interpolated, not bucket ceiling 5s)
- Claim → Ready: P50=0.05s, avg=0.066s (actual API latency)
- Controller restart: pre-existing claimed pods are not falsely measured
