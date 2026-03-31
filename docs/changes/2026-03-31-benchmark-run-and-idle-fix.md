# 2026-03-31 — Benchmark Run, Idle State Fix, Probe Tuning & Duration Enforcement

## Summary

Ran a 30-minute high-load benchmark (`--baseline 1000 --surge-min 200 --surge-max 1000`) and
monitored all system components. Discovered and fixed three issues:

1. Controller classified Running-but-not-Ready pods as "idle" (claimable)
2. Readiness probe config added unnecessary latency to pool replenishment
3. Benchmark script did not reliably stop when duration was reached

## Benchmark Results

| Metric               | Value              |
| -------------------- | ------------------ |
| Duration             | ~40 min (overran — fixed below) |
| Total Claims         | 29,385             |
| Claims/min           | ~735               |
| Pool Exhaustions     | ~19,000            |
| Errors               | 3 (transient timeouts) |
| Failed Pods          | 0                  |
| Controller Restarts  | 0                  |
| Node Count           | 105 (102 secondary + 3 default) |
| Max Active Pods      | ~2,400             |

### Latency

| Metric              | avg     | p50     | p95     | p99     |
| -------------------- | ------- | ------- | ------- | ------- |
| Claim-to-Ready       | 0.101s  | 0.08s   | 0.24s   | 0.42s   |
| Schedule Duration    | 4.748s  | 4.07s   | 8.82s   | 9.79s   |

### Latency After Probe Tuning

| Metric              | avg     | p50     | p95     | p99     |
| -------------------- | ------- | ------- | ------- | ------- |
| Schedule Duration    | 3.291s  | 3.73s   | 4.87s   | 4.97s   |

### System Health During Benchmark

- **Controller**: Stable throughout. CPU ~319m, Memory ~102Mi. No OOM, no restarts.
- **Sync**: `synced: true` at all checks. Mismatch count fluctuated briefly during spikes but self-healed within 1-2 sync cycles.
- **Nodes**: No memory pressure detected on any node. All nodes remained `Ready`.
- **Sandboxes**: Zero CrashLoopBackOff, zero Evicted, zero Failed pods throughout the entire run.
- **GKE Autoscaler**: Stable at 105 nodes (pre-scaled from prior runs).

## Changes

### 1. Idle State Classification Fix (`app/controller/reconciler.go`)

```diff
- if state == "idle" && pod.Status.Phase != corev1.PodRunning {
+ if state == "idle" && (pod.Status.Phase != corev1.PodRunning || !isPodReady(pod)) {
      state = "pending"
  }
```

- **READY (idle)**: Now strictly means Running AND Ready (passed readiness probes).
- **PENDING**: All pods the warmpool is waiting for (Pending, ContainerCreating, Running but not Ready).
- **FAILED**: Unchanged — stays its own category.
- **Claim logic**: `ClaimIdle()` filters by `state == "idle"`, so only truly ready pods are claimed.

### 2. Readiness Probe Tuning (`app/manifests/deployment.yaml`)

```diff
  readinessProbe:
-   initialDelaySeconds: 1
-   periodSeconds: 2
+   initialDelaySeconds: 0
+   periodSeconds: 1
```

Shaved ~1s off schedule duration by eliminating unnecessary probe delay. The status
endpoint is trivial (returns static JSON), so 1s period is safe.

### 3. Benchmark Duration Enforcement (`app/tests/benchmark.sh`)

- Added `is_expired()` helper that checks elapsed time against `DURATION_SEC`
- All phase functions (`phase_steady`, `phase_surge`, `phase_quiet`) now check `is_expired()` on each loop iteration
- `run_random()` and `steady_drip()` also check `is_expired()`
- `phase_surge` has a 120s max timeout to prevent infinite "waiting for replacements" spins
- Benchmark now reliably stops within seconds of the configured duration

## Modified Files

- `app/controller/reconciler.go` — idle state classification
- `app/manifests/deployment.yaml` — readiness probe tuning
- `app/tests/benchmark.sh` — duration enforcement
- `docs/specs/controller/integration-spec.md` — state derivation updated

## Verification

1. `go build ./...` — passes
2. Deployed to GKE cluster — controller healthy, pool counts match K8s reality
3. 1-minute benchmark test — stopped cleanly at 1m 6s (within tolerance)
4. Schedule duration improved from p50=4.07s to p50=3.73s after probe tuning
