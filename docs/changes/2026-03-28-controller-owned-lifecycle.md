# Controller-Owned Sandbox Lifecycle

**Date:** 2026-03-28
**Scope:** Controller lifecycle refactor, UI cleanup, dead code removal

## Summary

Refactored the sandbox system so the **controller is the single authority** for sandbox lifecycle management. The sandbox pod no longer controls its own lifetime — it runs workload phases until the controller terminates it via TTL or GC.

## Changes

### Sandbox Pod (`app/sandbox/main.go`)
- Removed `chooseLifetime()` — no self-imposed timer
- Removed `notifyController()` and `controllerURL` init — pod doesn't request its own death
- Removed crash simulation gates (5% random rolls)
- Load loop runs indefinitely until SIGTERM
- Clean signal handling: logs "received SIGTERM from controller" on termination

### Sandbox Dockerfile (`app/sandbox/Dockerfile`)
- Switched from `distroless/static` to `debian:bookworm-slim`
- Added bash, curl, procps, htop, strace, net-tools for terminal access

### Controller Reconciler (`app/controller/reconciler.go`)
- Renamed `reap()` → `gc()` with comprehensive garbage collection
- GC handles: TTL expired, failed pods, exited pods, stale unlimited pods (2h cap)
- Each GC reason is logged and counted via `sandbox_gc_total` Prometheus counter

### Controller Handlers (`app/controller/handlers.go`)
- Default TTL: `5m` (was `unlimited`)
- Max TTL cap: `2h` (new)
- Removed expose action route and expose service enrichment
- Removed `controllerNS` field

### Controller Metrics (`app/controller/metrics.go`)
- Added `sandbox_gc_total` counter with `reason` label

### Controller Store (`app/controller/store.go`)
- Removed `Exposed`, `ServiceName`, `ExternalIP` fields

### Deleted Files
- `app/controller/exec.go` — dead code (never called)
- `app/controller/expose.go` — per-pod LoadBalancer expose (not needed for this sandbox type)

### Controller UI (`app/controller/ui/index.html`)
- Renamed "IDLE" → "READY", "ACTIVE" → "CLAIMED" in stats bar
- Removed PG column from table
- Removed disk metric display (always 0 on gVisor)
- Removed Expose button and toggleExpose function
- Fixed log modal to properly parse sandbox JSON logs (ts/phase/msg format)
- Expires column now shows countdown ("4m 30s left") instead of absolute time
- Node names shortened for readability
- Provision defaults changed to 5m TTL

### Tests (`app/tests/test-sandbox-lifecycle.sh`)
- Test captures baseline active count for resilience to pre-existing pods
- Broadened detach detection grep patterns
- All 20 tests pass

## Verification

- `go build` passes for both sandbox and controller
- All 20 lifecycle tests pass
- Bash works inside sandbox pods (`kubectl exec ... -- bash`)
- Controller UI confirms renamed labels and improved log formatting
