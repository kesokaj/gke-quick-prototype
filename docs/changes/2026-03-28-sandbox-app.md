# 2026-03-28 — Sandbox App: Controller + Simulation

## Summary
Rebuilt sandbox application from Neon warmpool controller + simulation sources.

## New Files
- `app/controller/` — Go source, Dockerfile, go.mod (10 files)
- `app/sandbox/` — Go source, Dockerfile, go.mod (5 files)
- `app/manifests/` — controller.yaml, deployment.yaml, pdb.yaml
- `app/deploy.sh`, `app/README.md`

## Verification
- Both modules build clean (`go build ./...`)
- Deploy script syntax OK (`bash -n`)
