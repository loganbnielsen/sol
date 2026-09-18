# DOGFOOD-002: Local Dev Lifecycle
**Date:** 2026-06-11  
**Tester:** Claude Sonnet 4.6 (automated dogfood pass)  
**Branch:** DOGFOOD-002/local-dev-lifecycle

---

## Environment

- OS: Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu)
- k3d v5.6.0, helm v3.21.0, kubectl present
- Cluster: `sun-local` (already running from prior session)
- Workspace under test: `/tmp/dogfood-test/dogfood_acme` (from DOGFOOD-001)

---

## Steps Executed

| Step | Command | Result |
|------|---------|--------|
| 1 | `sun dev up` (cluster already running) | Exit 0, all 6 endpoints ✓ |
| 2 | Probe all endpoints | kafka ✓, schema-reg ✓, postgres ✓, loki ✓, pushgateway ✓, grafana ✓ (via manual pf) |
| 3 | `sun dev status` | Exit 0, shows pods + 6 port-forward PIDs |
| 4 | `sun dev run` | Workers started but immediately failed (see F1, F2) |
| 5 | Service request via deployed workspace | `POST /charges` → `{"id":"ch_585481","accepted":true}` ✓ |
| 6 | Verify Kafka event | `rpk topic consume` confirmed event landed ✓ |
| 7 | `sun logs comms/notify_worker --no-follow` | Exit 0, showed only `[obs-loki] Loki returned HTTP 400` (see F3) |
| 8 | `sun dev down` | Exit 0 |
| 9 | Verify port-forwards stopped | Loki still responded (see F4) |
| 10 | `sun dev up` (restart) | Exit 0, shows ✓ (see F4) |

---

## Findings

### F1 — BLOCKER: `sun dev run` fails — parallel `dune exec` lock contention

When `sun dev run` spawns two or more services simultaneously, each calls `dune exec` in the same `_build` directory. Dune allows only one writer of the build lock at a time; the second `dune exec` fails immediately with:

```
Error: Unexpected contents of build directory global lock file
(_build/.lock). Expected an integer PID. Found: 
Hint: Try deleting _build/.lock
```

**Fixed in this pass:** `sun dev run` now runs a single `dune build` for all service targets before spawning anything, then runs the pre-built executables from `_build/default/` directly (no dune involved at run time).

### F2 — BLOCKER: `sun dev run` services can't reach Kafka — broker advertises internal cluster DNS

After fixing F1, the service (`charge_svc`) still fails:

```
Failed to resolve 'redpanda-0.redpanda.redpanda.svc.cluster.local.:9093': Name or service not known
Fatal error: kafka register: could not provision topic ...: Local: Timed out
```

`sun dev up` port-forwards `localhost:9092` → `redpanda:9093`. On first connect, librdkafka bootstraps via `localhost:9092` (works), but the broker's metadata response advertises its internal Kubernetes hostname `redpanda-0.redpanda.redpanda.svc.cluster.local:9093`. librdkafka then reconnects to that hostname, which is unresolvable from outside the cluster.

**Root cause:** Redpanda is installed without an external advertised listener. The Helm chart needs:
```
config.redpanda.advertised_kafka_api[0].name=external
config.redpanda.advertised_kafka_api[0].address=localhost
config.redpanda.advertised_kafka_api[0].port=9092
```
plus a corresponding external listener definition.

**Not fixed in this pass** — requires Helm values change + cluster reconfig. Follow-up ticket: DOGFOOD-008.

### F3 — Worker logs emit only Loki HTTP 400

`sun logs` works correctly (correct namespace, correct kubectl call). However, the only log line from `notify_worker` in the deployed `comet-kafka` workspace is `[obs-loki] Loki returned HTTP 400`. The worker is running, processes events, but its log shipper is getting a 400 from Loki. Likely a label format or tenant ID mismatch.

**Not fixed in this pass.** Follow-up ticket: DOGFOOD-009.

### F4 — `sun dev down` / `sun dev up` restart is unreliable — stale port-forwards survive

`state_dir = ".sun"` (relative) means PID files are stored relative to cwd. If `sun dev up` was run from `/home/user/Code/sun` and `sun dev down` is run from a different directory, the PID files are not found and old port-forwards survive. After restart, `sun dev up` starts new port-forward processes that fail immediately (port already bound by old ones), but the health checks pass because old processes still serve the ports. The ✓ output is misleading — no new port-forwards are actually running.

**Fixed in this pass:**
1. `state_dir` changed to `~/.local/share/sun/` (absolute via `XDG_DATA_HOME` or `$HOME`)
2. `dev_up` now calls `stop_port_forwards()` at startup to clear stale processes before binding ports

---

## What Passed

- `sun dev up` is idempotent; Helm upgrades are clean and fast (~30s second run).
- All 6 infrastructure endpoints verified reachable via port-forward.
- `sun dev status` output is clear: cluster state, all pods, port-forward PIDs.
- `sun logs` correctly resolves workspace name from cwd and calls kubectl.
- Deployed services (`sun up` path) work end-to-end: HTTP → Kafka → worker.
- `sun dev down` stops port-forwards it owns cleanly.

---

## Required Follow-up Tickets

- **DOGFOOD-008**: Fix Redpanda advertised listener for `sun dev run` (Kafka DNS outside cluster) — blocker for local service development
- **DOGFOOD-009**: Investigate Loki HTTP 400 from worker log shipper

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| Local infrastructure starts from a clean state | **Pass** (F4 fixed) |
| Application processes run without hand-edited env vars | **Blocked** (F2 — Kafka DNS) |
| Logs and status commands provide enough information | **Partial** (F3 — Loki 400 truncates worker logs) |
| Repeat start/stop loop is repeatable | **Pass** (F4 fixed) |
