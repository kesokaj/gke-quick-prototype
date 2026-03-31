# Benchmark Rewrite: User Churn Simulator

## Summary

Complete rewrite of `app/tests/benchmark.sh` from a pool-scaling benchmark to a proper
user churn simulator that tests sandbox claim throughput and pool recovery.

## What Changed

### Architecture
- **Old**: Managed pool size during phases, spawned ephemeral K8s pods (`kubectl run`) for
  every API call (~3-5s overhead per call), simulated infrastructure scaling.
- **New**: Sets pool once (`--baseline`), uses public LoadBalancer IP with direct `curl`,
  simulates user arrival patterns creating high churn through claim/expire/replace cycles.

### Modified Files
- **`app/tests/benchmark.sh`** — Full rewrite

### Key Design Decisions
- `--baseline N` sets warmpool size once at start via `PUT /api/pool-size`
- `--surge-min N` / `--surge-max N` define claims per surge phase (random between min/max)
- `--lifetime DUR` is the max TTL; each sandbox gets random TTL between 2m and this value
- Surge phases block until all claims are fulfilled (waits for pool to refill, polls every 0.5s)
- Background "steady drip" of 1–2% of baseline claims runs continuously alongside phases
- Uses `mkdir`-based atomic locking for counters (macOS compatible, no `flock` dependency)

### Phase Design (Random Mode)
| Phase | Probability | Behavior |
|-------|-------------|----------|
| STEADY | 30% | 1-10% of baseline per tick, 15% chance of small burst |
| SURGE | 25% | rand(min,max) claims, retries until fulfilled |
| DOUBLE SURGE | 15% | Two back-to-back surges |
| SPIKE | 10% | surge-max at once, fire-and-forget |
| QUIET | 20% | 0-2 claims/tick, pool recovery |

## Verification

Tested live against GKE cluster:
```
Duration:     2m (129s)
Total claims: 303 (151/min)
Exhaustions:  0 (0.0%)
Errors:       0 (0.0%)
Schedule Duration: avg=3.0s  p50=3.5s  p95=4.8s
Claim-to-Ready:    avg=2.9s  p50=2.5s  p95=9.0s
```
