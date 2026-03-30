# WS-Server Integration Spec

## Overview

The `ws-server` is a Cloud Run service that simulates persistent developer session connections. Sandbox pods connect via WebSocket after being claimed, sending `ping` and receiving `pong` responses.

## Service

| Property         | Value                                         |
| ---------------- | --------------------------------------------- |
| Name             | `sandbox-ws-server`                           |
| Platform         | Google Cloud Run (managed)                    |
| Region           | `europe-west4` (same as GKE cluster)          |
| Port             | `8080`                                        |
| Auth             | Requires `roles/run.invoker` (Workload ID)    |
| Min instances    | `0` (scales to zero)                          |
| Max instances    | `10`                                          |
| Session affinity | Enabled                                       |
| Timeout          | `3600s` (1 hour, Cloud Run max for WS)        |

## Endpoints

### `GET /ws` — WebSocket

Upgrades to WebSocket. Reads text messages:

- **Receives** `"ping"` → **Sends** `"pong"`
- Any other message → ignored

**Headers:**

| Header          | Required | Description                               |
| --------------- | -------- | ----------------------------------------- |
| `Authorization` | Yes      | `Bearer <ID_TOKEN>` (Workload Identity)   |
| `X-Pod-Name`    | No       | Source pod name for logging                |

**Connection lifecycle:**
1. Client sends `ping` every 2 seconds
2. Server responds with `pong`
3. Cloud Run closes idle connections after 3600s
4. Client auto-reconnects with fresh token on disconnect

### `GET /healthz` — Health Check

Returns `200 OK` with JSON:

```json
{
  "status": "ok",
  "activeConnections": 3,
  "ts": "2026-03-30T12:00:00Z"
}
```

## Client Configuration

The sandbox client is configured via environment variables:

| Variable         | Description                                    | Set By       |
| ---------------- | ---------------------------------------------- | ------------ |
| `WS_SERVER_URL`  | WebSocket URL (e.g., `wss://...run.app/ws`)    | `deploy.sh`  |
| `POD_NAME`       | Pod identifier for logging                     | K8s downward API |

## Authentication Flow

```
Sandbox Pod                    Metadata Server           Cloud Run
     |                              |                        |
     |--- GET /identity?aud=... --->|                        |
     |<--- ID Token (JWT) ---------|                        |
     |                              |                        |
     |--- WebSocket Upgrade + Bearer Token ----------------->|
     |<--- 101 Switching Protocols -------------------------|
     |                              |                        |
     |--- "ping" ------------------------------------------>|
     |<--- "pong" ------------------------------------------|
```

- Token fetched from `http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/identity?audience=<service_url>`
- Requires NetworkPolicy egress to `169.254.169.254/32:80`
- Token refreshed on each reconnection

## Sandbox Status Endpoint

`/_sandbox/status` (on each sandbox pod, port 3004) includes:

```json
{
  "status": "ok",
  "ready": true,
  "pod": "sandbox-pool-xxx",
  "phase": "load",
  "cpuTier": "light",
  "dutyPct": 0.30,
  "wsConnected": true
}
```

Proxied through controller at `GET /api/sandboxes/{name}/status`.

## Observability

### Sandbox Logs (structured JSON)

| Phase | Message                         | Fields                                        |
| ----- | ------------------------------- | --------------------------------------------- |
| `ws`  | `starting WebSocket session loop` | url, audience, intervals                    |
| `ws`  | `dialing`                       | url, timeout, has_token                       |
| `ws`  | `connected`                     | url, pod                                      |
| `ws`  | `first pong received ✓`        | connected_dur_s                               |
| `ws`  | `ping/pong heartbeat`          | pings_sent, pongs_received, connected_dur_s   |
| `ws`  | `connection lost — scheduling reconnect` | reason, connection_dur_s, reconnect_count |
| `ws`  | `read/write error`             | error, connected_dur_s, pings/pongs counters  |
| `ws`  | `ID token fetch failed`        | error, audience                               |

### Dashboard Tiles (GCP Monitoring)

- Cloud Run request count (by response code)
- Cloud Run request latency (p50, p95, p99)
- Cloud Run active instances
- Cloud Run error rate (4xx, 5xx)

## Network Requirements

The NetworkPolicy must allow:

1. **Egress to metadata server**: `169.254.169.254/32` port `80/TCP`
2. **Egress to Cloud Run**: Public internet (already allowed by default rule)
