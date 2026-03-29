# 2026-03-30 — Network Isolation, Cilium Identity, Conntrack Monitoring

## Summary

Rewrote sandbox network isolation policy, added Cilium identity churn monitoring and mitigation tooling, added conntrack/socket observability to the dashboard, and standardized all GMP scrape intervals to 10s.

## Changes

### Network Isolation (`app/manifests/sandbox-isolation.yaml`)
- **Complete rewrite** — single policy enforcing two rules:
  - **Egress:** Internet-only. Blocks all RFC1918, CGNAT, loopback, link-local, metadata server
  - **Ingress:** Only `sandbox-control` namespace on port 3004
- **Removed stale config:**
  - Verdaccio egress rule (port 80) — no verdaccio exists
  - Hardcoded CIDRs `10.12.x.x` — from a different environment
  - CGNAT/Tailscale ingress ranges — not used
  - IPv6 NAT64 exceptions — over-engineered
  - Unnecessary kube-dns egress — pods use `dnsPolicy: None` with 8.8.8.8/1.1.1.1

### Cilium Identity Monitoring (`app/tests/monitor-cilium-identity.sh`)
- New script to watch Cilium identity churn during sandbox claim/detach
- Modes: `snapshot`, `labels`, `identities`, `endpoints`, `all`
- Tracks `warmpool=true→false` label transitions and endpoint regeneration

### Cilium Identity Label Exclusion (`gke/manual/cilium-identity-labels-patch.yaml`)
- ConfigMap patch to add `labels: "!warmpool"` to cilium-config
- Eliminates identity regeneration on pod claim (2 identities → 1)
- Placed in `gke/manual/` — not auto-applied, requires manual steps per GKE docs

### Conntrack Observability
- **`gke/shared/netd-conntrack-monitoring.yaml`** — ClusterPodMonitoring for netd port 10231
- **`gcp/dashboard.json.tpl`** — New "Conntrack & Sockets" section with 5 charts:
  - Conntrack table utilization (%)
  - Conntrack errors by type
  - TCP sockets (in-use + TIME_WAIT)
  - Socket memory
  - TCP retransmission rate

### Scrape Interval Standardization
All GMP monitoring resources set to **10s**:
- `cilium-pod-monitoring.yaml` (was 5s)
- `netd-conntrack-monitoring.yaml` (was 5s)
- `controller-pod-monitoring.yaml` (was 15s)
- `kubelet-extra-monitoring.yaml` (was 30s)

### Dashboard Deploy Fix (`gcp/deploy-dashboard.sh`)
- Changed from update to **delete + create** workflow (avoids etag issues)

### Documentation
- **README.md** — Updated shared configs table, project structure tree (added netd monitoring, gke/manual/, fixed descriptions)
- **app/README.md** — Added manifest file listing, tests listing, network isolation section

## Modified Files

- `app/manifests/sandbox-isolation.yaml` (rewrite)
- `app/tests/monitor-cilium-identity.sh` (new)
- `gke/manual/cilium-identity-labels-patch.yaml` (new)
- `gke/shared/netd-conntrack-monitoring.yaml` (new)
- `gke/shared/cilium-pod-monitoring.yaml` (interval)
- `gke/shared/controller-pod-monitoring.yaml` (interval)
- `gke/shared/kubelet-extra-monitoring.yaml` (interval)
- `gcp/dashboard.json.tpl` (conntrack section)
- `gcp/deploy-dashboard.sh` (delete+create)
- `README.md` (documentation)
- `app/README.md` (documentation)

## Verification

- Network policy applied and validated (pods can reach internet, cannot reach cluster)
- Cilium identity monitor tested — correctly detects identity transitions on claim
- Conntrack metrics verified live from netd port 10231 (Prometheus format)
- Dashboard deployed successfully to GCP Monitoring
- All monitoring resources applied (10s interval)
- JSON template validates as valid JSON
