# DOGFOOD-003: Local Cluster Deploy Loop
**Date:** 2026-06-11  
**Tester:** Claude Sonnet 4.6 (automated dogfood pass)  
**Branch:** DOGFOOD-003/local-cluster-deploy

---

## Environment

- OS: Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu)
- k3d v5.6.0, cluster: `sun-local` (running, provisioned by DOGFOOD-002)
- Workspace under test: `/tmp/dogfood-test/dogfood_acme`
- `sun` binary: `~/.local/bin/sun` → `_build/default/cli/sun/bin/main.exe`

---

## Steps Executed

| Step | Command | Result |
|------|---------|--------|
| 1 | `sun up --dry-run` | Exit 0; manifests rendered correctly with internal DNS |
| 2 | `sun up` | Exit 0; both services compiled, pushed, deployed, rolled out |
| 3 | `sun status` | Exit 0; namespace, pod, readiness, and endpoint visible |
| 4 | `curl POST /charges` | `{"id":"ch_770445","accepted":true}` ✓ |
| 5 | `curl GET /healthz` | `{"status":"ok"}` ✓ |
| 6 | Worker logs (`sun logs`) | Only retry messages in stdout (see F1) |
| 7 | Loki query for worker logs | Detailed error visible: missing table (see F2) |
| 8 | `sun migrate status` | Showed `1  notifications  (pending)` |
| 9 | `sun migrate apply` | Exit 0, migration applied |
| 10 | Worker restart | Pod restarted; messages processed; DB has 3 rows ✓ |
| 11 | `curl POST /charges` with `amount_cents` | `amount_cents=3000` stored correctly ✓ |

---

## Findings

### F1 — MINOR: `sun logs` shows only stdout/stderr; Loki-routed logs are invisible

`sun logs comms/notify_worker` wraps `kubectl logs` and therefore only shows
content written to stdout/stderr. The notify_worker writes all application logs
(including error detail) via `Obs_loki`, not to stdout. The only lines visible
via `sun logs` are the `sun-worker: attempt N failed` retry messages emitted by
the framework itself.

When the worker is failing, the operator must query Loki directly (via Grafana
or the Loki HTTP API) to see the actual error. This is a significant operational
gap — the command a user would reach for first (`sun logs`) provides incomplete
information.

**Suggested improvement:** `sun logs` could optionally include a Loki tail as a
secondary stream, or the man page should document that Loki/Grafana is the
source for application log detail.

### F2 — MINOR: `sun up` does not warn about pending migrations

After `sun up` completes successfully, the worker immediately starts processing
Kafka messages and fails because the database table does not exist. The user
must separately run `sun migrate apply` before the worker can function.

There is no warning in `sun up` output that pending migrations exist. A user
following the README would see the service deploy "successfully," then need to
debug via Loki to understand why the worker is retrying.

**Suggested improvement:** `sun up` could check for pending migrations and
print a warning: `⚠ 1 pending migration(s) — run sun migrate apply`.

### F3 — MINOR: Scaffolded POST /charges uses `amount_cents` but README shows `amount`

The scaffold generates a handler that reads `amount_cents` from the request
body (`get_i "amount_cents"`). However, the generated README does not document
the endpoint schema, and the natural convention for a `POST /charges` body is
`{"amount": N, ...}`. Sending `{"amount": 1999}` results in `amount_cents=0`
being stored silently (no validation error).

**Not a runtime crash**, but a UX trap for developers extending the scaffold.

**Suggested improvement:** Generated handler should either use `amount` (with
a note that it maps to cents), or the README template should include the
request schema.

---

## What Passed

- `sun up --dry-run` renders correct manifests (internal cluster DNS, correct
  namespaces, resource limits, network policies, ingress).
- `sun up` builds OCaml binaries inside the workspace, packages them into
  Ubuntu 24.04 containers, pushes to the local k3d registry, and applies
  manifests with server-side validation before final apply.
- Both services rolled out to Running/1 with no manual intervention.
- `sun status` output includes namespace, pod name, readiness, and HTTP
  endpoint with port-forward address — sufficient for day-1 ops.
- HTTP service (`charge_svc`) responds correctly: 202 on valid POST, 200 on
  /healthz.
- Worker-to-DB path: after `sun migrate apply`, the worker correctly inserted
  3 notification rows from 3 distinct charge events.
- Loki logs from in-cluster workers work correctly (DOGFOOD-009 fix
  confirmed): trace_id and span_id appear in logfmt line body; HTTP 400 no
  longer occurs.
- `sun migrate status` and `sun migrate apply` work correctly against the
  port-forwarded PostgreSQL instance.

---

## Acceptance Criteria Status

| Criterion | Status |
|-----------|--------|
| `sun up` succeeds without hand-written Kubernetes manifests | **Pass** |
| Deployed service responds successfully | **Pass** |
| Status output identifies namespace, workload, readiness, and endpoint | **Pass** |
| Any local/prod parity gaps are captured as follow-up tickets | **Pass** (F1–F3 above) |
