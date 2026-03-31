# Sandbox Controller Integration Spec

## Overview

The sandbox controller manages a warm pool of sandbox pods via a Kubernetes Deployment. It provides an HTTP API for claiming sandboxes, managing pool size, and observing metrics.

## Service

| Property         | Value                                         |
| ---------------- | --------------------------------------------- |
| Name             | `sandbox-controller`                          |
| Namespace        | `sandbox-control`                             |
| Port             | `8080`                                        |
| Service Type     | `LoadBalancer` (public IP)                    |
| Reconciler       | 1s sync interval                              |
| Metrics fetch    | Async (concurrent with pod list)              |

## API Endpoints

### Pool Management

| Method   | Path              | Description                          |
| -------- | ----------------- | ------------------------------------ |
| `GET`    | `/api/status`     | Pool counts and sync health (idle, pending, active, failed, total, poolSize, lastSyncSec, synced, mismatchCount, totalClaims, totalScheduled) |
| `PUT`    | `/api/pool-size`  | Set Deployment replicas              |
| `DELETE` | `/api/claimed`    | Force-delete all claimed sandboxes   |

### Sandbox Lifecycle

| Method   | Path                             | Description                          |
| -------- | -------------------------------- | ------------------------------------ |
| `GET`    | `/api/sandboxes`                 | List all sandboxes                   |
| `GET`    | `/api/sandboxes/{name}`          | Get single sandbox details           |
| `POST`   | `/api/provision`                 | Claim an idle sandbox                |
| `POST`   | `/api/sandboxes/{name}/{action}` | Sandbox actions (logs, events, etc.) |
| `DELETE` | `/api/sandboxes/{name}`          | Delete a specific sandbox            |

### Observability

| Method   | Path                    | Description                          |
| -------- | ----------------------- | ------------------------------------ |
| `GET`    | `/api/metrics/summary`  | Schedule Duration + Claim-to-Ready p50/p95/p99 |
| `POST`   | `/api/metrics/reset`    | Reset all metric counters            |
| `GET`    | `/healthz`              | Health check                         |

## Provision Request

```json
{
  "lifetime": "5m"    // duration (5m, 1h, 24h) or "unlimited" (24h cap)
}
```

## Provision Response

```json
{
  "name": "sandbox-pool-abc123",
  "node": "gke-sandbox-gke-secondary-pool-xxx",
  "podIP": "10.0.1.42",
  "state": "active",
  "expiresAt": "2026-03-31T11:00:00Z"
}
```

## Kill All Claimed

`DELETE /api/claimed` — Force-deletes all pods with `warmpool=false`.

```json
// Response
{ "deleted": 1105 }
```

Use case: post-benchmark cleanup of orphaned claimed pods that are no longer
managed by the Deployment.

## Pool Size Request

```json
{ "size": 500 }
```

- Patches the `sandbox-pool` Deployment replicas
- Deployment controller handles pod creation/deletion
- Claimed pods (`warmpool=false`) are detached and unaffected by replica scaling

## Reconciler

| Property           | Value   |
| ------------------ | ------- |
| Sync interval      | 1s      |
| Pod label selector | `managed-by=warmpool` |
| State derivation   | `warmpool=false` → active, Running+Ready → idle, else pending/failed |
| Metrics fetch      | Concurrent goroutine (non-blocking) |
| GC targets         | TTL expired, failed, exited, stale (>24h unlimited) |
| Kick channel       | Non-blocking signal from handlers for immediate sync |

## Garbage Collection

The reconciler GC runs every sync cycle and deletes:

| Reason       | Condition                                      |
| ------------ | ---------------------------------------------- |
| `ttl_expired`| Active pod past `expiresAt`                    |
| `failed`     | Pod in failed state (CrashLoopBackOff, etc.)   |
| `exited`     | Active pod not Running/Pending                 |
| `stale`      | Active unlimited pod older than 24 hours       |

Completed pods (Succeeded phase) in both `sandbox` and `sandbox-control`
namespaces are cleaned after 2 minutes.
