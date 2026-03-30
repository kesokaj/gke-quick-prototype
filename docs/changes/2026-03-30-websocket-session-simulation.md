# WebSocket Session Simulation

## Summary

Added a persistent WebSocket connection from sandbox pods to a new Cloud Run service (`ws-server`) to simulate active developer sessions. The sandbox sends `ping` every 2 seconds and the server responds with `pong`. Connections are authenticated via Workload Identity ID tokens and automatically reconnect on failure.

## Changes

### New Files

- `app/ws-server/main.go` — Cloud Run WebSocket server that handles `/ws` connections, responds to "ping" with "pong", and exposes health/metrics endpoints.
- `app/ws-server/Dockerfile` — Multi-stage build for the ws-server (distroless base).
- `app/ws-server/go.mod`, `app/ws-server/go.sum` — Module dependencies (gorilla/websocket).
- `app/sandbox/ws.go` — WebSocket client with auto-reconnect, ID token auth via GCE metadata server, periodic ping/pong logging.

### Modified Files

- `app/sandbox/main.go` — Added `wsConnected` to sandbox state and `/_sandbox/status` endpoint. Starts `wsSessionLoop` goroutine after pod is claimed.
- `app/manifests/deployment.yaml` — Added `WS_SERVER_URL` environment variable placeholder.
- `app/manifests/sandbox-isolation.yaml` — Added egress rule allowing `169.254.169.254:80` for GCE metadata server (Workload Identity tokens).
- `app/deploy.sh` — Integrated ws-server build/push/Cloud Run deployment, IAM binding for sandbox-sa, URL extraction and injection.
- `app/controller/handlers.go` — Added `/api/sandboxes/{name}/status` proxy endpoint.
- `app/controller/ui/index.html` — Live WS/phase/CPU tier status in Config column for claimed sandboxes.
- `gcp/dashboard.json.tpl` — Added Cloud Run monitoring tiles (request rate, latency, instances, errors).

## Architecture Decisions

- **Authenticated Cloud Run**: Org policy blocks `allUsers`, so ws-server uses `--no-allow-unauthenticated` with sandbox-sa granted `roles/run.invoker`.
- **Metadata IP**: Sandbox pods use `dnsPolicy: None` with public DNS, so the GCE metadata server is accessed at `169.254.169.254` instead of `metadata.google.internal`.
- **NetworkPolicy exception**: A specific `/32` rule was added for the metadata IP on port 80 only, maintaining strict isolation otherwise.
- **Graceful logging**: Logs first ping/pong, then every 30 pings (~60s) to avoid flooding.

## Verification

1. `./app/deploy.sh build && ./app/deploy.sh push && ./app/deploy.sh deploy 3`
2. Claim a sandbox: `curl -X POST -d '{"lifetime":"5m"}' http://<controller-ip>:8080/api/provision`
3. Check status: `curl http://<controller-ip>:8080/api/sandboxes/<name>/status` → `wsConnected: true`
4. Check logs: `kubectl logs -n sandbox <pod> | grep ws` → ping/pong heartbeat entries
5. Check Cloud Run: `gcloud run services logs read sandbox-ws-server --region=europe-west4 --limit=10` → 101 WebSocket upgrades
