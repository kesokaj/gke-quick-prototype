# Architectural Decision Records

## ADR-001: Single-Script Cluster Lifecycle

**Date:** 2026-03-25
**Status:** Accepted

### Context

The project needed a repeatable way to create, configure, update, and delete GKE clusters with consistent settings.

### Decision

- **Single entrypoint** (`cluster.sh`) with subcommands instead of separate scripts
- **`.env`-driven config** — every tuneable value lives in `.env`, script uses fallback defaults
- **Two-stage workflow** — `create` handles infrastructure (VPC, subnet, cluster, shared k8s configs, secondary pool); `apply` handles workload-specific configs
- **VPC lifecycle in create** — VPC + subnet created idempotently during `create`, preserved on `delete`
- **Shared configs applied during create** — cilium override (field-manager), kube-dns autoscaler, and monitoring are applied before secondary pool creation
- **Dry-run on all mutating commands** — `--dry-run` flag prints exact gcloud/kubectl commands without executing

### Consequences

- Simple onboarding: clone, edit `.env`, run `./cluster.sh create`
- K8s configs organized by scope: `gke/shared/` (cluster-wide) and `gke/secondary/` (pool-specific)
- VPC must be manually deleted after cluster teardown (safety measure)

## ADR-002: Conditional Cluster Features + gVisor Sandbox

**Date:** 2026-03-28
**Status:** Accepted

### Context

Needed to replicate a production GKE cluster config (COS + gVisor sandbox, Cloud DNS, cost allocation, Secret Manager, fleet registration) while keeping the script flexible for different environments.

### Decision

- **Cluster features as conditional flags** — VPA, HPA profile, Cloud DNS, DNS cache, Filestore CSI, image streaming, cost allocation, Secret Manager, and fleet are all controlled via `.env` toggles. Only non-empty/true values generate gcloud flags.
- **Secondary pool uses gVisor** — `--sandbox type=gvisor` with COS_CONTAINERD image. Nested virtualization removed (not needed with gVisor).
- **Sysctl config is variable-driven** — `SECONDARY_SYSTEM_CONFIG` path in `.env` instead of hardcoded file lookup. Empty = skip.
- **GCFS at node pool level** — Image streaming enabled on secondary pool via `--enable-gcfs`, not cluster-wide.
- **Fleet defaults to PROJECT** — `FLEET_PROJECT` falls back to `${PROJECT}` if not explicitly set.

### Consequences

- All cluster features visible and tuneable in `.env`
- Script logic unchanged — only values and conditional flags differ
- Easy to toggle features on/off per environment

## ADR-003: Cilium Identity Label Exclusion (Dataplane V2)

**Date:** 2026-03-30
**Status:** Accepted

### Context

In GKE Dataplane V2, Cilium computes a security identity from all pod labels. When sandbox pods transition from `warmpool=true` to `warmpool=false` during claim, Cilium generates a new identity for each unique label combination. With a warm pool of N pods, this causes N identity regenerations per benchmark cycle — unnecessary churn that wastes CPU and increases endpoint policy revision latency.

### Decision

- **Exclude `warmpool` from identity** via `cilium-config.data.labels = !warmpool` (not `cilium-config-emergency-override`, which is broken per GKE v1.34/1.35 known issue)
- **Automation script** (`gke/manual/apply-cilium-identity-labels.sh`) follows the official [GKE workaround](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/dataplane-v2#identity-relevant-label-filtering-issue): patch config → same-version master upgrade → anetd rolling restart
- **ConfigMap-based config** persists through GKE upgrades since user modifications to `cilium-config` are preserved

### Consequences

- All sandbox pods share a single Cilium identity regardless of warmpool state
- Claiming/releasing sandboxes no longer triggers endpoint regeneration
- Script provides safe revert with automatic ConfigMap backup
- Must be re-applied if more high-cardinality labels are introduced

## ADR-004: Claim-to-Ready Metric in Handler, Not Reconciler

**Date:** 2026-03-30
**Status:** Accepted

### Context

The claim-to-ready metric was measured in the reconciler sync loop by recording `time.Since(DetachedAt)` when a claimed pod reported Ready=true. For warm-pool pods (already running and ready), this produced three categories of incorrect values: sub-millisecond (same-cycle), escalating stale (controller restart), or repeated (after metric reset).

### Decision

- **Record in the provision handler** (`handleProvision`), timing from claim start to successful K8s label patch. This measures the actual user-facing claim latency.
- **Reconciler no longer measures claim-to-ready** — removed entirely to prevent stale/duplicate observations
- **Pre-existing claimed pods on restart** use the `sandbox.gvisor/claimed-at` annotation for `DetachedAt` and are marked `ReadyObserved=true` to prevent measurement
- **Histogram percentiles** use Prometheus-style linear interpolation between bucket boundaries instead of returning raw upper bounds

### Consequences

- Claim-to-ready reflects actual API latency (~50-100ms for warm-pool claims)
- Metric is deterministic and reproducible (one observation per claim, in the handler)
- Controller restarts do not pollute the metric
- Reset Metrics only resets observations for idle/pending pods, not active ones

## ADR-005: WebSocket Session Simulation via Cloud Run

**Date:** 2026-03-30
**Status:** Accepted

### Context

Sandbox pods simulate developer workloads (CPU cycles, disk I/O, network downloads) but lacked a persistent connection component. Real developer sessions maintain long-lived connections (WebSocket terminals, LSP, file sync). We needed a way to simulate this and monitor connection health.

### Decision

- **Cloud Run WS server** (`ws-server`) handles WebSocket connections, responds to `ping` with `pong`, and tracks active connection counts. Deployed to the same region (`europe-west4`) as the GKE cluster.
- **Authenticated access** — Org policy prohibits `allUsers`. Sandbox pods authenticate via Workload Identity: fetch an ID token from the GCE metadata server (`169.254.169.254`) and send it as a Bearer token in the WebSocket handshake.
- **NetworkPolicy exception** — A targeted egress rule allows `169.254.169.254/32:80` for metadata token fetch while maintaining full sandbox isolation otherwise.
- **Metadata IP direct** — Sandbox pods use `dnsPolicy: None` with public nameservers, so `metadata.google.internal` can't resolve. The metadata IP (`169.254.169.254`) is used directly.
- **Auto-reconnect** — If the WS connection drops (Cloud Run 60-min timeout, network issues), the client reconnects after 2 seconds with a fresh ID token.
- **Periodic logging** — Logs the first ping/pong exchange and then every 30 pings (~60s) with cumulative counters, plus detailed disconnect reasons with connection lifetime.

### Consequences

- Each claimed sandbox maintains exactly one WebSocket connection to Cloud Run
- Connection health visible via `/_sandbox/status` (wsConnected field), proxied through controller API and shown in the UI
- Cloud Run auto-scales from 0 (no cost when no sandboxes are claimed)
- WS server is fully managed — no infrastructure to maintain beyond the deploy script
- Deploy script handles build, push, Cloud Run deployment, and IAM binding automatically

## ADR-006: Reconciler Performance & Bulk Cleanup

**Date:** 2026-03-31
**Status:** Accepted

### Context

During high-churn benchmarks (500+ pod pool, surge claims of 200-1000), the controller reported 0 idle pods for 10-15 seconds after surges, even though K8s showed pods as Running. The 5-second reconciler interval combined with a blocking metrics API call created a "blind window" where the controller couldn't see newly created replacement pods.

Additionally, after benchmarks, hundreds of claimed (detached) pods lingered with no way to bulk-delete them since they are no longer managed by the Deployment.

### Decision

- **Reconciler interval**: 5s → **1s**. Each sync is a single `List` call + Deployment `Get`, so the kube-api load increase is minimal (~5 QPS).
- **Async metrics fetch**: The Metrics API call (`PodMetricses.List`) now runs in a goroutine concurrent with the pod list processing. This saves ~500ms per sync cycle at scale.
- **Bulk claimed cleanup**: New `DELETE /api/claimed` endpoint lists all `warmpool=false` pods and force-deletes them with `GracePeriodSeconds=0`. UI button with confirmation dialog.
- **Portable atomic counters**: Benchmark script uses `mkdir`-based locking instead of `flock` (macOS compatibility).

### Consequences

- Controller "blind window" reduced from ~10s to ~2s (1s interval + ~1s sync duration)
- Metrics fetch no longer blocks pod state updates
- Post-benchmark cleanup is instant via UI button
- Benchmark script works on both macOS and Linux without additional dependencies

