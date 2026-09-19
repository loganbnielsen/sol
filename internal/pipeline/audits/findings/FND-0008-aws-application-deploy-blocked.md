# FND-0008 — No workload can be deployed to an AWS target: the runtime Secret identity is wrong

- **Classification:** `VERIFIED_DEFECT`
- **State:** `OPEN` (INFRA-040 not implemented)
- **First identified:** 2026-09-19 (HARDEN Run 6 / Attempt 6)
- **Last verified:** 2026-09-19, `main @ 7ea2ef43`
- **Provider:** provider-neutral (manifest rendering); observed on AWS
- **Derived ticket:** **INFRA-040** (open) — `internal/pipeline/tickets/READY_FOR_ENGINEERING/INFRA-040.md`
- **Related invariant:** `INV-IDENT-1`
- **Related:** ADR 0002; matrix sections B/C (deploy and migration)

## Sol claim at stake

The application lifecycle (`sol migrate apply` → `sol migrate status` →
`sol deploy`) works against a conformant target. Matrix sections B and C are the
rows that assert it.

## Current implementation evidence

The migration Job's container uses `envFrom: secretRef{name: sol-secrets}`
(`sol_cli_manifest_yaml.ml:58` defines `runtime_secret_name = "sol-secrets"`),
while the substrate's creation template appends `-secrets` to a name that
already carries the suffix, producing `sol-secrets-secrets`
(`sol_cli_manifest_yaml.ml:167`). Every consumer references `sol-secrets`; the
substrate creates `sol-secrets-secrets`. The Job's container can never start, so
the migration gate never passes and **no workload can be deployed to a cloud
target**.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the two code locations and the constant; reproducible in rendering |
| MECHANISM | none (the fix is not implemented) |
| BEHAVIORAL | Run 6 live: `CreateContainerConfigError`, `secret "sol-secrets" not found`, while `secret/sol-secrets-secrets` existed with the right keys |

## What is established

A concrete, reproduced defect blocks the entire application path on AWS. Two
diagnostics gaps compound it (the deploy reports a Job timeout rather than the
container's failure; the Job is deleted with its reason; the prescribed remedy
accepts no `--scope`).

## What is NOT established

Whether the same defect blocks GCP identically — it is provider-neutral
rendering, so it should, but no GCP deploy has been attempted.

## Impact

Matrix sections B (deploy/rollback), C (migration ordering) and D (workload
availability) cannot be qualified while INFRA-040 is open. HARDEN-002 records
the app lifecycle as "the largest unexplored area".

## Derived engineering work

**INFRA-040** (high, open). The deploy's fail-closed behaviour is correct and
must not be weakened — only the identity and the reporting.

## Supersession

None.
