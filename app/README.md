# Sandbox Application

Warm pool controller and simulation workloads for testing gVisor sandbox environments on GKE.

## Architecture

```
app/
├── controller/     # Warm pool controller (Go, runs in sandbox-control namespace)
├── sandbox/        # Simulation pod binary (Go, runs in sandbox namespace with gVisor)
├── manifests/      # K8s manifests
│   ├── namespaces.yaml          # sandbox + sandbox-control namespaces
│   ├── controller.yaml          # Controller deployment, service, RBAC
│   ├── deployment.yaml          # Sandbox warm pool deployment (gVisor, public DNS)
│   ├── sandbox-isolation.yaml   # NetworkPolicy (internet-only egress, controller ingress)
│   └── sandbox-sa.yaml          # Sandbox service account + RBAC
├── tests/
│   ├── benchmark.sh             # Load testing / QPS benchmarks
│   ├── monitor-cilium-identity.sh  # Cilium identity churn monitor
│   ├── test-detach-comparison.sh   # Dirty vs clean detach RS behavior test
│   └── test-sandbox-lifecycle.sh   # End-to-end lifecycle tests
├── deploy.sh       # Build, push, and deploy script
└── .current-tag    # Auto-generated image tag
```

### Controller

Manages a warm pool of sandbox pods via a K8s Deployment. Pods sit idle until claimed (detached from the Deployment by flipping `warmpool=false` label and clearing `ownerReferences` atomically). The clean detach bypasses the RS controller's `ReleasePod` path, preventing Expectations hangs — K8s immediately auto-replaces the pod.

![Controller Lifecycle](docs/images/controller_lifecycle.png)

<details>
<summary>View Mermaid Source</summary>

```mermaid
flowchart TD
    User([User / API Request]) -->|POST /api/provision| Ctrl

    subgraph "K8s ReplicaSet (sandbox-pool)"
        pod1[Pod A\nwarmpool=true]
        pod2[Pod B\nwarmpool=true]
        pod3[Pod C\nwarmpool=true]
    end

    Ctrl{Sandbox\nController} -->|Selects Ready Pod| pod1
    Ctrl -.->|1. Updates label\nwarmpool=false| pod1
    
    pod1 -.->|2. Detaches| activePod[Pod A\nwarmpool=false\nActive Workload]
    
    K8s[K8s Control Plane] -.->|3. Reconciles missing replica| pod4[New Pod D\nwarmpool=true]
    
    subgraph "Claimed / Active"
        activePod
    end
```

</details>

**Features:**
- Pool size management (scales Deployment replicas)
- Provision/claim sandboxes with lifetime expiry
- Expose sandboxes externally via LoadBalancer
- Pod logs, events, and exec
- Prometheus metrics (schedule duration, claim-to-ready latency)
- Embedded web UI dashboard

**API endpoints:**
| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/status` | Pool status counts |
| GET | `/api/sandboxes` | List all sandboxes |
| GET | `/api/sandboxes/{name}` | Sandbox detail |
| GET | `/api/sandboxes/{name}/logs` | Pod logs |
| GET | `/api/sandboxes/{name}/events` | Pod events |
| POST | `/api/provision` | Claim an idle sandbox |
| POST | `/api/sandboxes/{name}/restart` | Restart a sandbox |
| DELETE | `/api/sandboxes/{name}` | Delete a sandbox |
| PUT | `/api/pool-size` | Set pool size |
| GET | `/api/metrics/summary` | Metrics summary |
| POST | `/api/metrics/reset` | Reset metrics |
| GET | `/metrics` | Prometheus metrics |
| WS | `/terminal/{name}` | Interactive terminal |
| GET | `/ui` | Web dashboard |

### Simulation Pod

Runs inside gVisor-sandboxed pods. Simulates realistic user workloads:

1. **Phase 1 — Download:** Fetches 5 × 1 MB from external speedtest servers
2. **Phase 2 — Disk:** Writes 500 MB–3 GB random data to ephemeral storage
3. **Phase 3 — CPU:** Duty-cycled load bursts (90% light/8% medium/2% heavy) until SIGTERM
4. **Background:** WebSocket session to Cloud Run (ping/pong every 2s), network probe to 8.8.8.8

### Network Isolation

![Network Isolation](docs/images/network_isolation.png)

<details>
<summary>View Mermaid Source</summary>

```mermaid
flowchart LR
    subgraph Sandbox Namespace
        Pod["Sandbox Pod (gVisor)"]
    end
    
    subgraph Allowed Egress
        Internet((Internet))
        PublicDNS((Public DNS\n8.8.8.8, 1.1.1.1))
    end
    
    subgraph Blocked Egress
        KubeDNS((kube-dns))
        InternalIPs((RPC1918 / CGNAT))
        Metadata((GCE Metadata))
    end
    
    subgraph Allowed Ingress
        Ctrl["Controller\n(sandbox-control ns)"]
    end
    
    Pod -->|HTTPS / WSS| Internet
    Pod -->|UDP 53| PublicDNS
    
    Pod -.->|Blocked| KubeDNS
    Pod -.->|Blocked| InternalIPs
    Pod -.->|Blocked| Metadata
    
    Ctrl -->|TCP 3004\nProbes / Status| Pod
    Internet -.->|Blocked| Pod
    
    classDef blocked fill:#ffebee,stroke:#ef5350,stroke-width:2px,color:#c62828,stroke-dasharray: 5 5;
    classDef allowed fill:#e8f5e9,stroke:#66bb6a,stroke-width:2px,color:#2e7d32;
    classDef pod fill:#e3f2fd,stroke:#42a5f5,stroke-width:2px,color:#1565c0;
    
    class KubeDNS,InternalIPs,Metadata blocked;
    class Internet,PublicDNS,Ctrl allowed;
    class Pod pod;
```

</details>

Sandbox pods (`sandbox-isolation.yaml`) enforce strict isolation:
- **Egress:** Internet only — all RFC1918, CGNAT, loopback, link-local, and metadata server blocked
- **Ingress:** Only `sandbox-control` namespace on port 3004 (health probes)
- **DNS:** Pods use `dnsPolicy: None` with public nameservers (8.8.8.8, 1.1.1.1) — no kube-dns access

## Usage

### Build & Deploy

```bash
# Build both images (ARM Mac → AMD64)
./deploy.sh build

# Push to Google Artifact Registry
./deploy.sh push

# Deploy to GKE (5 replicas by default)
./deploy.sh deploy 10

# Or build + push + deploy in one command
./deploy.sh all 10

# Teardown everything
./deploy.sh teardown
```

### Access the Dashboard

```bash
kubectl port-forward -n sandbox-control svc/sandbox-controller 8080:8080
# Open http://localhost:8080/ui
```

## Configuration

All configuration is read from the project `.env` file:

| Variable | Used by | Description |
|----------|---------|-------------|
| `PROJECT` | deploy.sh | GCP project ID |
| `REGION` | deploy.sh | GAR region |
| `TARGET_NAMESPACE` | controller | Sandbox pod namespace (default: sandbox) |
| `DEPLOYMENT_NAME` | controller | Deployment to manage (default: sandbox-pool) |
| `POOL_SIZE` | controller | Initial pool size (default: 5) |
