# UI Terminal Fix, Provision Modal Improvements, Download Reduction

## Summary

Four changes:

1. **Terminal button fixed** — WebSocket URL was using empty `API` string resulting in `ws:///api/...` (triple slash). Now uses `location.host` correctly.
2. **Provision modal** — Added "Count" field (1–500) alongside "Lifetime (TTL)" field. Batch provisioning uses concurrent requests (5 at a time) with a live progress counter.
3. **Quick Claim button** — Always uses 5m default TTL (same as before, simplified).
4. **Cloud NAT egress reduction** — Sandbox download phase changed from random 1–500MB (100MB.zip / 1GB.zip) to fixed 5 × 1MB (1MB.zip). Reduces per-sandbox egress from avg ~50MB to exactly 5MB.

## Modified Files

- `app/controller/ui/index.html` — Terminal WebSocket URL fix, provision modal count+TTL, batch provisioning
- `app/sandbox/main.go` — Download phase: 5×1MB instead of random 1–500MB

## Verification

- Both Go modules (`app/controller`, `app/sandbox`) compile successfully
- Terminal WebSocket URL now resolves to `ws://host:port/api/sandboxes/{name}/terminal`
- Provision form shows Count + TTL side-by-side
- Batch provision runs 5-concurrent with progress updates
