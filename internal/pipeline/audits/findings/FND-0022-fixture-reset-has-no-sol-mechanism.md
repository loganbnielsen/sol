# FND-0022 — "reset the fixture" has no Sol mechanism, because an unchanged deploy is idempotent by design

**Classification:** `QUALIFICATION_GAP` · **State:** `OPEN`
**Severity:** medium · **Ticket:** `INFRA-062` · **Evidence:** `BEHAVIORAL`
**Found while:** resetting the `notify_worker` fixture (DEC-039 / run record boundary)

## The attempt

The fixture was to be re-established through the documented Sol mechanism — no
ad-hoc `kubectl delete pod` — by redeploying the revision Sol already had recorded:

```
sol deploy qual/aws/us-east-1 --scope comms/notify_worker \
  --image-ref notify_worker=<repo>/notify-worker@sha256:64960f1c…
```

It succeeded in every sense Sol reports:

```
Migrations: OK — 1 declared migration(s) present in schema_migrations
[apply] ok (11.8s)
  ✓  namespace pluto-comms  image …@sha256:64960f1c…
Done. 1 service(s) deployed.
```

…and **nothing was reset**:

| | before | after |
|---|---|---|
| pods | `…-nwx89`, `…-x4lt4` | the **same two pods**, same creation timestamps (`2026-09-20T21:35:29Z`) |
| restarts | 22, 11 (`CrashLoopBackOff`) | 24, 13 |
| Deployment generation | 1 | **1** — the spec was never changed |
| ready | 0/2 | 0/2 |
| `sol status` | `DEGRADED` | `DEGRADED` |

The release record *did* advance (`r-291245be11e2b8a6` → `r-33d8e08d02d2a45c`, the id
the pre-fix fail-open had been unable to record), so the deploy did its bookkeeping.
It simply had no reason to touch the workload.

## Why it is a procedure gap and not a product defect

This is **intended product behaviour**, and a qualified one: B2 asserts that an
identical repeat deploy produces *no workload restarts* and an unchanged pointer, and
the acceptance criterion for B3-adjacent rows depends on exactly that. Sol has no
"restart" or "rollout" operation, and should not acquire one casually.

What is wrong is the procedure's implicit assumption that a **fixture reset** is
expressible. It is not, and the ways to make it expressible are different decisions:

- a **new revision** (a different digest) — resets the pods, but changes the fixture's
  release identity, so the new epoch starts from a different artefact than the one the
  failure was recorded against;
- an explicit **restart/reset capability** in Sol — a product decision, and one that
  must not weaken B2's idempotence contract;
- **teardown and recreate** of the fixture namespace — the largest change, and the one
  closest to a clean new epoch;
- ad-hoc `kubectl delete pod` — explicitly rejected: it is neither documented nor
  reproducible, and it hides the missing capability.

## Stop condition, honoured

DEC-039 and the run's rule both say: if normal Sol reconciliation cannot restore the
fixture to health, stop and report rather than repeatedly restarting it. It cannot —
not because reconciliation failed, but because there is nothing for it to reconcile —
so the run stops. `notify-worker` is at 0/2 ready with both replicas failing their
readiness probe, and has not been restarted by hand.

## What would make it qualified

A documented answer to "how does a qualification run re-establish a fixture", recorded
in the procedure, with the trade-off above made explicit — plus an assertion that the
answer does not weaken the idempotence B2 qualifies.
