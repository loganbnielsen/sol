# FND-0008 — The runtime Secret identity was wrong, so the migration path could not start

- **Classification:** `VERIFIED_DEFECT`
- **State:** `QUALIFIED` (the identity defect: fixed in #359, behaviourally
  exercised by HARDEN Run 7 attempt 7). The derived ticket `INFRA-040` remains
  `OPEN` for its separate evidence-retention/diagnostics acceptance criteria.
- **First identified:** 2026-09-19 (HARDEN Run 6 / Attempt 6)
- **Last verified:** 2026-09-19, `main @ 910a59f1` (reconciled after Run 7)
- **Provider:** provider-neutral (manifest rendering); observed on AWS
- **Derived ticket:** **INFRA-040** (`READY_FOR_ENGINEERING`) — still open for the
  diagnostics/evidence-retention item, **not** for the identity
- **Related invariant:** `INV-IDENT-1`
- **Related:** ADR 0002; matrix sections B/C (deploy and migration); INFRA-043
  (the current deploy blocker, a different defect)

## Sol claim at stake

The application lifecycle (`sol migrate apply` → `sol migrate status` →
`sol deploy`) works against a conformant target. Matrix sections B and C are the
rows that assert it.

## What the defect was (Run 6) and how it was fixed

Run 6's migration Job died at container start:

```text
CreateContainerConfigError: secret "sol-secrets" not found
container envFrom: secretRef{name: sol-secrets}
```

while the substrate had created `secret/sol-secrets-secrets` (the creation
template appended `-secrets` to a name that already carried the suffix). Every
consumer referenced `sol-secrets`; the substrate created `sol-secrets-secrets`,
so no migration could start and no workload could be deployed.

**The fix landed in #359 ("one runtime Secret identity, and a Job that cannot
start says why"), which is present at this branch's base `7ea2ef43`.** The
shared constant and the workload-named function are now explicit and tested:

- `cli/sol/lib/sol_cli_manifest_yaml.ml:58` — `runtime_secret_name = "sol-secrets"`;
- `cli/sol/lib/sol_cli_manifest_yaml.ml:144-153` — `workload_secret_name name = Printf.sprintf "%s-secrets" name`, with the comment recording exactly this defect;
- `internal/ci/check_runtime_secret_identity.sh` and
  `cli/sol/test/test_runtime_secret_identity.ml` pin the agreement on both sides.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC (defect) | the Run-6 render: consumer `sol-secrets` vs created `sol-secrets-secrets` |
| STATIC (fix) | `workload_secret_name` + the guard/test that pin both sides |
| MECHANISM | offline test asserts the rendered consumer and creator agree |
| BEHAVIORAL | **Run 7 attempt 7**: `sol migrate apply` reached `Done.` and `sol deploy` reported `Migrations: OK -- 1 declared migration(s) present in schema_migrations`; the container that died at start in Attempt 6 started and ran |

## What is established

The runtime Secret identity agrees across producer and consumer, and the
migration path that could not start in Run 6 ran and completed on a real AWS
target in Run 7. The property `INV-IDENT-1` is behaviourally qualified on AWS.

## What is NOT established

- GCP: the render is provider-neutral, so the same property should hold, but no
  GCP deploy has reached this point.
- The **full workload deploy still does not complete** — but for a different,
  newly-recorded reason: Run 7 stopped at the boundary lease because the deploy
  identity lacks the grant (`INFRA-043` on `origin/main`). That is a separate
  defect and is not part of this finding.

## Impact

INFRA-040 no longer blocks the migration gate. Its remaining open item is the
evidence-retention/diagnostics criterion, demonstrated live in Run 7: `sol deploy`
said "see the Job logs" *after* deleting them, costing the diagnosis. Matrix
section C's migration-gate row is behaviourally met; section B remains blocked by
`INFRA-043`.

## Correction (2026-09-19 reconciliation)

The first version of this finding reproduced `INFRA-040`'s Run-6 description as
if it were the current code and cited stale line numbers. The implementation had
already been fixed in #359, which was merged before this audit branch's base. The
finding is corrected here, and the error is kept visible because it is the exact
failure mode the audit function exists to catch: **a ticket's historical
description is not evidence of the current code.** The classification
(`VERIFIED_DEFECT`) is unchanged; only the state and the implementation evidence
move.

## Derived engineering work

**INFRA-040** remains open for the evidence-retention/diagnostics acceptance
criteria only (Run 7 demonstrated the cost of the current behaviour). The deploy's
fail-closed behaviour is correct and must not be weakened.

## Supersession

The first version's `STATIC`/`OPEN` assessment is `SUPERSEDED` by this
reconciliation.
