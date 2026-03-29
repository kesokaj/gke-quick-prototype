# 2026-03-28 — Rename k8s/ → gke/ Directory References

## Summary

Updated all references from `k8s/` to `gke/` across scripts and documentation to match the renamed directory.

## Modified Files

| File | Changes |
|---|---|
| `cluster.sh` | 7 references: usage comments, path variables (`shared_dir`, `secondary_dir`, `sysctl_config`), inline comments |
| `README.md` | 7 references: sysctl config path, shared configs table, commands section, project structure tree |
| `docs/architecture/DECISIONS.md` | 1 reference: consequences section |
| `docs/changes/2026-03-25-gke-cluster-scripts.md` | 5 references: summary, changes table, workflow commands |
| `docs/changes/2025-03-25-cluster-settings-enhancements.md` | 1 reference: modified files list |
| `docs/changes/2025-03-25-secondary-pool-refactor.md` | 1 reference: added files list |

## Verification

- `grep -r 'k8s/' --include='*.sh' --include='*.md' .` → 0 results (all references updated)
