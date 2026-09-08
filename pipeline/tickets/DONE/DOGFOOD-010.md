---
id: DOGFOOD-010
type: dogfood-finding
severity: high
source: project/dogfood/RUN_2026-06-12.md
branch: DOGFOOD-010/populate-local-postgres-url
worktree: ../sun-DOGFOOD-010-populate-local-postgres-url
---

Populate local deploy `POSTGRES_URL` or fail before accepting writes.

**Depends on:** None.

**Problem:** A fresh local `sun up` deploy on the known local k3d context renders
per-workload Secrets with `POSTGRES_URL: ""`. The generated service and worker
then start successfully, but both silently drop into `pool = None` behavior. The
service accepts `POST /charges`; the worker acks consumed Kafka messages without
persisting notifications; `GET /notifications` stays empty.

**Evidence:** In the 2026-06-12 dogfood run, the generated
`dogfood_2026_06_12` workspace deployed cleanly. A direct port-forward to the
new namespace on port 18080 returned `ok` from `/health` and accepted a charge,
but `/notifications` remained `[]` for 20 seconds. The pod Secret was:

```yaml
stringData:
  POSTGRES_URL: ""
```

**Goal:** The local deploy path should either provide a usable in-cluster
Postgres URL or fail before the app can accept writes that will never be
persisted.

**Remediation:**

1. In `sun up` local/k3d mode, populate `POSTGRES_URL` with the in-cluster dev
   Postgres URL, for example
   `postgresql://postgres:dev@postgresql.postgresql.svc.cluster.local:5432/dev`.
2. Keep non-local deploys protected by the existing `POSTGRES_URL` preflight.
3. Change generated service/worker startup so `POSTGRES_URL=""` is treated as
   invalid, not as an optional missing database. At minimum, log a clear error;
   preferably fail startup for workloads that require storage.
4. Add a dogfood or integration check that deploys a fresh workspace, posts a
   charge, and verifies `/notifications` contains the worker-written row through
   the new workspace's own service.

**Acceptance criteria:**

- Fresh local `sun up` pods have a non-empty, usable `POSTGRES_URL`.
- `POST /charges` followed by `GET /notifications` succeeds in a fresh local
  workspace without manually running `sun secret set`.
- Empty database credentials cannot produce a healthy-looking deployment that
  acks Kafka messages without persistence.
- Production/live deploy behavior still refuses missing credentials outside the
  known local dev context.

