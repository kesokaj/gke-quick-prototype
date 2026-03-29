# 2026-03-29 — Dashboard Fixes, UI Cleanup, Curl Pod GC

## Summary

Fixed missing metrics on the GCP Monitoring dashboard, simplified the provision modal for gVisor sandboxes, and added automatic cleanup of completed benchmark pods.

## Modified Files

### Dashboard & Monitoring
- `gcp/dashboard.json.tpl` — Fixed "Container Start Duration" chart to use `kubelet_run_podsandbox_duration_seconds` (the previous metric did not exist). Renamed to "RunPodSandbox Duration (gVisor)".
- `gke/shared/controller-pod-monitoring.yaml` — NEW. PodMonitoring for sandbox controller Prometheus metrics (schedule_duration, claim_to_ready, state_count).
- `gke/shared/kubelet-extra-monitoring.yaml` — NEW. ClusterNodeMonitoring that scrapes ALL `kubelet_*` metrics. GKE's default only keeps ~12 metrics (drops histograms like `runtime_operations_duration`).
- `gcp/deploy-dashboard.sh` — Simplified: no template rendering, static cluster name.

### Sandbox Image
- `app/sandbox/Dockerfile` — Added `ca-certificates` (fix TLS to Cloud Monitoring API) and debugging tools (wget, iproute2, iputils-ping, dnsutils, tcpdump, jq, vim-tiny, lsof, sysstat).

### Controller
- `app/controller/reconciler.go` — Added `gcCompletedPods()` to clean up Succeeded/Failed pods (bench-curl-*, one-off debug pods) in both sandbox and sandbox-control namespaces. Updated max unlimited lifetime from 2h to 24h.
- `app/controller/ui/index.html` — Simplified provision modal: removed DATABASES and USERS fields, added "Autoscale warmpool to match count" checkbox, updated TTL cap to 24h.

### Deploy Script
- `app/deploy.sh` — Replaced inline PodMonitoring/ClusterNodeMonitoring heredocs with `ensure_monitoring()` that reads from `gke/shared/` YAML files.

## Root Causes Found
1. **Network Probe Latency empty** — Missing `ca-certificates` in Dockerfile caused TLS handshake failures to Cloud Monitoring API.
2. **Schedule Duration / Claim-to-Ready / Pool State empty** — No PodMonitoring resource existed to scrape controller Prometheus metrics.
3. **Runtime Ops Latency / Kubelet Pod Start SLI empty** — GKE's default ClusterNodeMonitoring drops most kubelet histogram metrics via a keep/regex filter.
4. **Container Start Duration empty** — The metric `kubelet_container_start_duration_seconds` does not exist. Replaced with `kubelet_run_podsandbox_duration_seconds`.

## Verification
- Deployed and verified all charts showing data except Runtime Ops Latency (waiting for GMP scrape) and Runtime Operation Errors (no errors occurring = healthy).
- Confirmed new controller cleans up bench-curl-* pods automatically.
