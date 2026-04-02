# 2026-04-01: Aggregated Dashboard Charts to Remove Noise

## Summary
Refactored several core GCP operations dashboard charts that were previously suffering from "spaghetti chart" noise. By implementing `topk(10, ...)` PromQL constraints and strict Cloud Monitoring reducer aggregations, these charts now instantly highlight system bottlenecks (max constraints and top 10 worst offenders) without drowning the operator in visual noise from hundreds of healthy pods or metrics.

## Files Modified
*   **`gcp/dashboard.json.tpl`**: 
    *   Container Pressure (PSI): Aggregated by `topk(10)` to show only the 10 most starved containers.
    *   BPF Map Pressure: Aggregated by `topk(10, max...)` to highlight only the 10 closest maps to overflowing.
    *   Kubelet Runtime Ops Latency: Dropped the `p50` plots to declutter and wrapped the `p99` latency in `topk(10)` to display only the absolute slowest operations.
    *   Agent CPU/Memory: Replaced the plotting of every individual agent instance with two explicit aggregate lines per node: `avg()` and `max()`. 
    *   TCP Sockets (In Use / Time Wait): Swapped `REDUCE_NONE` filter logic to `REDUCE_SUM` to output a total concrete system load instead of an overlapping per-container unreadable line.

## Verification
*   Successfully ran `gcp/deploy-dashboard.sh` and pushed the new JSON layout to GCP.
*   The dashboard interface was visually cleaned up and directly highlights system limits.
