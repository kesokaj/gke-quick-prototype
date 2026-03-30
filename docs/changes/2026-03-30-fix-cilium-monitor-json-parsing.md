# Fix: Cilium Identity Monitor JSON Parsing

## Summary

Rewrote `monitor-cilium-identity.sh` to replace all Python JSON parsing with `jq`.

## Bug

The label watcher (`watch_labels`) and endpoint watcher (`watch_endpoints`) were broken:
- `kubectl get -w -o json` outputs **multi-line pretty-printed JSON**, not one JSON object per line
- The Python inline parsers iterated line-by-line (`for line in sys.stdin`) and called `json.loads(line)` on each partial line
- Every parse attempt failed with `JSONDecodeError`, which was silently caught and discarded
- Result: **zero events** were ever detected — the watchers appeared to run but produced no output

The snapshot function also used Python to extract `warmpool` values from CiliumIdentity `security-labels`.

## Fix

Replaced all Python with `jq`:
- `jq --unbuffered -c` natively handles concatenated multi-line JSON streams from `kubectl -w`
- Label watcher: extracts `{name, wp}` per event, bash `while read` loop with `declare -A` tracks state
- Endpoint watcher: extracts `{name, id}` per event, same state-tracking pattern
- Snapshot: uses `jq -r` to parse CiliumIdentity security-labels

## Modified Files

- `app/tests/monitor-cilium-identity.sh` — Full rewrite from Python to jq

## Verification

1. `./monitor-cilium-identity.sh snapshot` — correctly shows idle/claimed pod counts and sandbox identities
2. `./monitor-cilium-identity.sh labels` — correctly lists all pods with initial warmpool values on startup
3. Identity transitions (`warmpool=true → false`) will now trigger `← IDENTITY CHANGE` output
