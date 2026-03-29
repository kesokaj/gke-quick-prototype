# 2026-03-29 — Audit Cleanup: Dead Code, Documentation, Dashboard Templating

## Summary

Applied all findings from the full project audit. Removed dead code, fixed documentation drift, templated the dashboard cluster name, cleaned up unused configuration, and updated `.gitignore`.

## Modified Files

### Controller (`app/controller/`)
- **terminal.go** — Removed dead `newTerminalHandler` function and unused `kubernetes`, `rest` imports
- **handlers.go** — Removed unused `controllerNS` parameter from `NewHandlers`, fixed stale "expose" comment
- **main.go** — Updated `NewHandlers` call to match new signature, removed extra blank line

### Sandbox (`app/sandbox/`)
- **main.go** — Removed dead `downloadFromGCS`, `getMetadataToken`, `gcsObject`, `gcsBucket`. Fixed deprecated `mathrand.Read` → `crypto/rand.Read`

### Manifests (`app/manifests/`)
- **deployment.yaml** — Removed dead `CONTROLLER_URL` and `GCS_BUCKET` env vars

### Deploy Scripts
- **app/deploy.sh** — Removed `GCS_BUCKET` variable, `controller_url` parameter from `ensure_sandbox_pool`, cleaned up sed pipeline
- **gcp/deploy-dashboard.sh** — Added `get_cluster_name()` function, cluster name substitution at deploy time via sed

### Infrastructure
- **gcp/dashboard.json.tpl** — Replaced 61 hardcoded `sandbox-gke` references with `__CLUSTER_NAME__` placeholder
- **cluster.sh** — Fixed `SECONDARY_IMAGE_TYPE` fallback default from `UBUNTU_CONTAINERD` to `COS_CONTAINERD`

### Documentation
- **README.md** — Fixed project structure tree, removed nonexistent files, added `app/` and `gcp/` trees, updated shared configs table
- **app/README.md** — Removed stale `expose` endpoint, added `terminal` and `metrics/reset` endpoints, updated simulation phase descriptions, removed dead config vars
- **.gitignore** — Added explicit entries for build artifacts and test logs

## Verification

- `go build ./...` — Both controller and sandbox compile clean
- `go test ./...` — No test failures (no test files in active code)
- Dashboard JSON validates as valid JSON
- Shell scripts pass syntax review
