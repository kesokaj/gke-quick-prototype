# Sync Health Failsafe and Real-Time Throughput UI

**Date**: 2026-03-31

## Summary
Implemented a robust observability and auto-recovery mechanism for the reconciler. The controller now actively monitors the health of its `1s` sync loop and detects "ghost" claims (state drift between internal memory and actual GKE `warmpool=true` labels). When drift is detected, the controller reverts the pod state to `idle`. Real-time throughput graphs (Claims/sec and Scheduled/sec) were added to the UI, alongside a refactored dashboard layout for better usability.

## Modified Files
- `app/controller/store.go`: Added `lastSync`, `mismatchCount`, and Prometheus `extractCounterValue()` methods to the state snapshot.
- `app/controller/metrics.go`: Registered Prometheus counters: `sandbox_sync_mismatch_total`, `sandbox_claim_total`, and `sandbox_scheduled_total`.
- `app/controller/handlers.go`: Incremented `sandbox_claim_total` on successful K8s patch.
- `app/controller/reconciler.go`: Added logic to detect `warmpool=true` -> `active` internal mismatches and auto-revert. Incremented `sandbox_scheduled_total`.
- `app/controller/ui/index.html`: Refactored layout (top-right buttons, 7-column stat row), widened search with multi-field filtering, and implemented Chart.js real-time line graphs.
- `docs/architecture/DECISIONS.md`: Added ADR-007 documenting the Sync Health failsafe and UI changes.
- `docs/specs/controller/integration-spec.md`: Updated `/api/status` endpoint structure.

## Verification Steps
1. Scale up the pool size using the UI (e.g., +10 or +50 pods).
2. Observe the "Scheduled Per Second" line graph spiking immediately in response.
3. Manually select and claim multiple pods under the Provision view.
4. Observe the "Claims Per Second" line graph accurately reflecting the throughput.
5. Manually force a label mismatch via `kubectl patch pod <name> -p '{"metadata":{"labels":{"warmpool":"true"}}}'` on an active pad. Confirm the controller logs the drift and reverts the pod to idle automatically, while the UI flashes the `MISMATCH` badge.
