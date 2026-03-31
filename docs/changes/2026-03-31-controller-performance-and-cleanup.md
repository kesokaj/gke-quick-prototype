# Controller Performance & Cleanup Features

## Summary

Improved controller responsiveness during high-churn benchmarks and added
a bulk cleanup capability for claimed sandboxes.

## Changes

### Reconciler Performance (`app/controller/reconciler.go`)

- **Sync interval reduced** from 5s → 1s. Each sync is a single pod List
  call, so this is safe and dramatically reduces the "blind window" after
  surges drain the pool.
- **Metrics fetch runs concurrently** with pod List. Previously, the metrics
  API call (which can take 500ms+ at 2500 pods) blocked the entire sync
  cycle. Now it runs in a goroutine and the result is collected before
  processing pods.

### Kill All Claimed (`app/controller/handlers.go`)

- New endpoint: `DELETE /api/claimed`
  - Lists all pods with `managed-by=warmpool,warmpool=false`
  - Force-deletes each with `GracePeriodSeconds=0`
  - Removes from in-memory store
  - Returns `{"deleted": N}`
- New UI button: 💀 **Kill All Claimed** (next to Reset Metrics)
  - Confirmation dialog shows current claimed count
  - Toast notification with result

### Cloud Run WS Server Tuning (`app/deploy.sh`)

- Concurrency: default (80) → **300**
- Max instances: 10 → **100**
- Min instances: 0 (unchanged, scales to zero)

### Benchmark macOS Fix (`app/tests/benchmark.sh`)

- Replaced `flock`-based atomic counters with `mkdir`-based locking
  (portable to macOS which lacks `flock`)
- Added dry-run skip for `wait_for_pool`

## Modified Files

- `app/controller/reconciler.go` — 1s ticker, async metrics fetch
- `app/controller/handlers.go` — `DELETE /api/claimed` endpoint
- `app/controller/ui/index.html` — Kill All Claimed button + JS
- `app/deploy.sh` — Cloud Run concurrency/scaling config
- `app/tests/benchmark.sh` — macOS portability fix

## Verification

- Controller built and deployed via `./deploy.sh all`
- Benchmark tested: 2-minute run, 303 claims at 151/min, 0 errors
- Cloud Run ws-server updated live with `gcloud run services update`
