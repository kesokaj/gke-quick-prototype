# Controller Benchmark Script

## Summary

Created a new benchmark script (`app/tests/benchmark.sh`) that exercises the sandbox controller end-to-end via its HTTP API. This replaces the old orchestration scripts in `tmp/simulation/orchestration/` which manipulated Kubernetes directly via `kubectl`.

## Key Differences from Old Scripts

| Aspect | Old (tmp/simulation/orchestration/) | New (app/tests/benchmark.sh) |
|---|---|---|
| **Pool scaling** | `kubectl scale deployment` | `PUT /api/pool-size` |
| **Claiming sandboxes** | `kubectl label pod warmpool=false` | `POST /api/provision` with TTL |
| **Lifecycle** | Manual orphan reaping, manual deletion | Controller handles TTL GC automatically |
| **Status queries** | `kubectl get pods/deployment` | `GET /api/status` |
| **Metrics** | None built-in | `GET /api/metrics/summary` with p50/p95/p99 |

## Features Carried Over

- Random mode (weighted phases: steady 20%, surge 60%, cool 20%)
- Deterministic mode (fixed 15-min repeating cycles)
- Colored logging, timestamped log files
- Graceful shutdown (Ctrl+C scales to 0, prints final metrics)
- Node summary display
- Preflight checks
- Duration timer
- Dry-run mode

## New Features

- TTL lifetime per claimed sandbox (default: 3m, configurable via `--lifetime`)
- Concurrency-throttled parallel provisioning (default: 5, configurable via `--concurrency`)
- Automatic metrics reset at benchmark start
- Metrics summary printed at shutdown (schedule duration + claim-to-ready histograms)
- Benchmark stats (total provisions, errors, error rate)

## Modified Files

- `app/tests/benchmark.sh` [NEW]

## Verification

- `bash -n benchmark.sh` — syntax validation passed
- `./benchmark.sh --help` — help output verified
- Dry-run mode available via `--dry-run` for offline testing
