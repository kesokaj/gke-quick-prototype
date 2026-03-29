# 2026-03-30: Conntrack & gVisor Metrics via prometheus-to-sd

## Summary

Deployed two `prometheus-to-sd` DaemonSets to push node-level metrics from localhost-bound scrapers (netd and runsc-metric-server) to Cloud Monitoring as custom metrics. Added gVisor runtime dashboard section. Updated `cluster.sh` for full reproducibility.

## Problem

Both `netd` (conntrack metrics on `:10231`) and `runsc-metric-server` (gVisor metrics on `:9115`) bind to `127.0.0.1`, making them unreachable by GMP collectors. GKE Managed Prometheus cannot scrape localhost-only endpoints.

## Solution

Used `prometheus-to-sd:v0.9.2` sidecars with `hostNetwork: true` — since they share the node's network namespace, `localhost` resolves to the same process. Metrics are pushed to Cloud Monitoring as `custom.googleapis.com/gke/node/*`.

**Key design decisions:**
- **v0.9.2 not v0.12+**: Newer versions use `CreateServiceTimeSeries` API which rejects custom metrics.
- **gmp-public namespace**: `kube-system` has GKE Warden restrictions preventing custom ServiceAccounts.
- **Workload Identity**: KSA `conntrack-reporter` in `gmp-public` bound to `gke-default` GSA (roles/owner).
- **120s export interval**: Appropriate for node-level gauges; avoids Cloud Monitoring API overhead.

## Modified Files

- `gke/shared/netd-conntrack-monitoring.yaml` — Rewrote from ClusterPodMonitoring to prometheus-to-sd DaemonSet (gmp-public namespace, WI KSA)
- `gke/shared/runsc-pod-monitoring.yaml` — **NEW**: gVisor metrics reporter (gVisor nodes only via nodeSelector)
- `gcp/dashboard.json.tpl` — Added gVisor section + fixed metric paths to `custom.googleapis.com/gke/node/*` with `gke_container` resource type
- `cluster.sh` — Extended `apply_shared()` with all monitoring yamls, WI binding, and gVisor reporter
- `README.md` — Updated shared configs table and project structure

## Verification

```bash
# Conntrack metrics (all 6 nodes)
kubectl get pods -n gmp-public -l k8s-app=conntrack-reporter

# gVisor metrics (3 secondary nodes)
kubectl get pods -n gmp-public -l k8s-app=gvisor-metrics-reporter

# Query Cloud Monitoring API
TOKEN=$(gcloud auth print-access-token)
curl -s "https://monitoring.googleapis.com/v3/projects/lvble-repro-sandbox1/timeSeries?filter=metric.type%3D%22custom.googleapis.com/gke/node/conntrack_entries%22&interval.startTime=$(date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ')&interval.endTime=$(date -u '+%Y-%m-%dT%H:%M:%SZ')&pageSize=3" -H "Authorization: Bearer ${TOKEN}"
```
