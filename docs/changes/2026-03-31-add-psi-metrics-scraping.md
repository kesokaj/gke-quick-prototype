# 2026-03-31: Add cAdvisor PSI Metrics Scraping and Dashboard

## Summary
Enabled collection and visualization of container pressure / PSI (Pressure Stall Information) metrics from the GKE cluster. These metrics provide clear insight into when containers are experiencing resource exhaustion (CPU, Memory, IO) that impacts performance, distinguishing between time spent waiting for a resource and time being actively stalled. 

## Files Modified
*   **`gke/shared/kubelet-extra-monitoring.yaml`**: Extended the `ClusterNodeMonitoring` config to scrape the `/metrics/cadvisor` endpoint, restricted strictly to `container_pressure_.*` metrics to prevent excessive ingestion costs.
*   **`gcp/dashboard.json.tpl`**: Added a new section "Container Pressure (PSI) — CPU, Memory, IO" containing three new timeseries widgets visualizing the PSI metrics across all pods.
*   **`TODO`**: Removed the completion items for PSI metric scraping verification.

## Verification
*   Successfully ran `kubectl apply -f gke/shared/kubelet-extra-monitoring.yaml`.
*   Successfully executed `gcp/deploy-dashboard.sh` to update the operations dashboard.
*   PSI metrics are actively charting in Google Cloud Monitoring.
