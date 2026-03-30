# Comment Cleanup — Pre-Push Audit

**Date:** 2026-03-30
**Scope:** Removed unnecessary comments across all Go, YAML, and shell files. No code changes.

## Principles Applied

1. **Remove** comments that restate what the next line obviously does
2. **Remove** heavy section banners (`// -----` and `# ====`) when function names provide context
3. **Keep** comments that explain *why* (non-obvious behavior, design decisions, safety constraints)
4. **Trim** verbose YAML header blocks to concise 1-2 line summaries
5. **Move** detailed metric lists to root README (shared configs table)

## Files Modified

### Go (controller)
- `main.go` — removed 9 obvious comments (`// Config from environment`, `// Build k8s client`, etc.)
- `handlers.go` — removed 14 section dividers (`// ---------- Status + Listing ----------`) and restating comments
- `reconciler.go` — removed 20+ obvious comments, tightened remaining ones
- `store.go` — removed 1 multi-line comment explaining obvious guard clause
- `metrics.go` — removed 8 variable description comments (the `Help` field in prometheus already documents them)
- `terminal.go` — removed 6 obvious comments

### Go (sandbox)
- `main.go` — removed 13 section banners (`// -----------`) and phase comments, trimmed log messages
- `ws.go` — removed 5 obvious comments, tightened audience derivation comment
- `probe.go` — no changes (already clean)
- `metrics.go` — no changes (already clean)

### YAML
- `sandbox-isolation.yaml` — 14-line header → 3 lines
- `runsc-pod-monitoring.yaml` — 23-line header → 2 lines
- `netd-conntrack-monitoring.yaml` — 23-line header → 3 lines
- `cilium-config-override.yaml` — removed box-drawing, kept concise rationale per setting
- `controller.yaml` — removed resource type comments (`# ServiceAccount`, `# Service`, etc.)

### Shell scripts
- No changes to `cluster.sh` or `deploy.sh` comment structure (already appropriate)

## Verification

```bash
go vet ./controller/...  # ✓
go vet ./sandbox/...     # ✓
bash -n cluster.sh       # ✓
bash -n deploy.sh        # ✓
```
