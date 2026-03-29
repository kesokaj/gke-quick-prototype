# Monitoring Follow-up TODO

## Verify Tomorrow (2026-03-30)

- [ ] **Conntrack metrics**: Confirm all 6 nodes report `conntrack_entries`, `num_inuse_sockets`, `num_tw_sockets`, `socket_memory` in Cloud Monitoring dashboard
- [ ] **gVisor metrics**: Confirm all 3 secondary nodes report `meta_sandbox_running`, `fs_opens`, `netstack_tcp_current_established`, `netstack_nic_rx/tx_bytes`, `netstack_dropped_packets`
- [ ] **Dashboard charts**: Verify all charts in the "Conntrack & Sockets" and "gVisor Sandbox Runtime" sections actually render data (not just "no data")
- [ ] **Transient 500s resolved**: Check logs for any recurring 500 errors after the initial first-write cycle
  ```bash
  kubectl logs -n gmp-public -l k8s-app=conntrack-reporter --since=1h | grep -c Error
  kubectl logs -n gmp-public -l k8s-app=gvisor-metrics-reporter --since=1h | grep -c Error
  ```

## Known Issues

- **First-write 500s**: Both reporters get transient 500 errors on their first export cycle when creating new metric descriptors. These resolve automatically on the next 120s cycle.
- **prometheus-to-sd v0.9.2**: Using the older version because v0.12+ uses `CreateServiceTimeSeries` API which rejects custom metrics. This is fine but the image is from 2020.
- **Per-sandbox labels**: The gVisor reporter exports per-sandbox metrics with `pod_name`, `sandbox`, and `iteration` labels. With 19+ sandboxes × 9 metrics, that's ~170+ time series per node. Monitor for Cloud Monitoring quota issues.

## Optional Improvements

- [ ] Consider reducing `--export-interval` from 120s to 60s if more granularity is needed
- [ ] Add `conntrack_error_count` chart to dashboard (currently exported but not charted)
- [ ] Investigate if `--exporter-prefix` on runsc-metric-server can be changed to reduce label cardinality
