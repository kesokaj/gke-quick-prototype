# 2025-03-25: GKE Cluster Script Enhancements

## Summary
Updated `cluster.sh` and applied live cluster settings for dev environment.

## Changes Applied (live + script)

### Service Accounts
- `gke-default@PROJECT.iam` — default pool SA (role: owner)
- `gke-secondary@PROJECT.iam` — NAP auto-provisioned pools SA (role: owner)

### Cluster Settings
- **VPA**: enabled
- **HPA profile**: performance (faster scaling decisions)
- **Workload Identity**: enabled (`PROJECT.svc.id.goog`)
- **Filestore CSI driver**: enabled

### NAP Autoprovisioning Config
- Service account: `gke-secondary`
- Scopes: `cloud-platform`
- Surge upgrade: 3, max unavailable: 1

### Cloud NAT Tuning (high-churn)
- Dynamic port allocation: enabled
- Min ports per VM: 1024
- Endpoint-independent mapping: disabled (mutually exclusive with dynamic ports)
- UDP timeout: 120s, TCP established: 3600s, TCP transitory: 60s
- ICMP: 60s, TCP time wait: 300s
- Logging: errors only

### Default Pool
- Static: 1 node per zone (no autoscaling)
- Surge upgrade: 3, max unavailable: 1

## Modified Files
- `cluster.sh` — SA creation, workload identity, NAP config, Cloud NAT tuning, Filestore CSI, static default pool
- `.env` — NUM_NODES=1, SECONDARY_MACHINE_TYPE added, ENABLE_CLOUD_NAT toggle
- `gke/secondary/compute-class.yaml` — templated SECONDARY_MACHINE_TYPE via envsubst
