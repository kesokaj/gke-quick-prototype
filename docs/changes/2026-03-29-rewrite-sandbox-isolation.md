# 2026-03-29 — Rewrite Sandbox Network Isolation Policy

## Summary

Rewrote `app/manifests/sandbox-isolation.yaml` from scratch to cleanly enforce two rules:

1. **Sandbox pods can ONLY reach the public internet** — all RFC1918, CGNAT, loopback, and link-local ranges are blocked. DNS (port 53) is explicitly allowed so hostname resolution works.
2. **Only the controller can talk to sandbox pods** — ingress limited to `sandbox-control` namespace on port 3004.

## What was removed (stale config)

| Item | Problem |
|---|---|
| Verdaccio egress rule (port 80 to `sandbox-control`) | No verdaccio deployment exists in this project — leftover from prior iteration |
| Hardcoded CIDRs `10.12.0.0/17`, `10.12.128.0/17` | From a different environment — actual subnet is `10.10.0.0/20` with pods at `10.100.0.0/16` |
| IPv6 exception `2a07:8241::/32` | Provider-specific range from previous environment |
| IPv6 NAT64 exceptions (`64:ff9b::*`) | Over-engineered — the simple `fc00::/7` + `fe80::/10` + `::1/128` exclusions cover all private IPv6 |
| CGNAT + Tailscale ingress CIDRs (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) | Not relevant — no Tailscale in this project |

## Design decisions

- **DNS is explicitly allowed** as a separate egress rule (port 53 UDP+TCP). Without this, pods cannot resolve hostnames for their download phase.
- **Kubelet probes are NOT explicitly allowed** in ingress — on GKE with DPv2 (Cilium), kubelet health checks are delivered node-locally and are not subject to NetworkPolicy. This is standard GKE behavior.
- **Split into two named policies** (`sandbox-egress`, `sandbox-ingress`) instead of one combined policy for clarity and independent lifecycle management.
- **Controller communication** works because exec/terminal goes through the K8s API server (SPDY), which the kubelet proxies. The controller never makes direct HTTP calls to pod IPs.

## Modified files

- `app/manifests/sandbox-isolation.yaml` — Complete rewrite

## Verification

- Validate by deploying and confirming:
  - `kubectl exec` into a sandbox pod and verify `curl https://example.com` works
  - Verify `curl 10.x.x.x` (any cluster IP) times out
  - Verify readiness/liveness probes pass
  - Verify controller terminal and logs features work
