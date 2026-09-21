---
id: INFRA-058
type: bug
severity: high
title: Reconcile the operator diagnostic RoleBinding for every workload namespace, without touching workloads
source: audit finding FND-0018 — DEC-038 §6
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0018-operator-grant-follows-command-not-workload.md`
**Contract:** DEC-038 §6

## Problem

The operator's diagnostic RoleBinding is created by the substrate step, which is
scoped to the namespace the command operates on. A namespace therefore receives the
grant only if it participated in a `deploy`/`migrate` after the grant existed.
Live: `sol-operator` exists in `pluto-checkout` and is `NotFound` in `pluto-payments`
and `pluto-comms`, so the operator identity cannot read the workload it exists to
diagnose. The only existing path that would create the missing binding redeploys the
workload, which is exactly what must not be required.

## Invariant

Every namespace containing a Sol-managed workload must have the operator diagnostic
RoleBinding, **independent of whether that namespace participated in the current
deploy/migrate operation.** Existing namespaces count.

## Acceptance criteria

1. A reconciliation establishes the operator RoleBinding in **every** namespace
   containing a Sol-managed workload, not merely those in the invoking command's
   scope.
2. It is **RBAC-only**: it must not write runtime Secrets, and must not apply any
   workload or configuration document. Do not reuse `Sol_cli_substrate.ensure`,
   which carries unrelated side effects.
3. It is idempotent and safe to run repeatedly.
4. Existing namespaces are handled: after it runs, a workload that has not been
   deployed since the grant existed is diagnosable by the operator.
5. Regression coverage asserting the binding is produced for a namespace **outside**
   the invoking scope, and that no Secret or workload document is written by the
   reconciliation.
6. Live: `pluto-comms` becomes readable by the operator **without** restarting or
   redeploying `notify-worker`.

## Out of scope

Widening the operator's permissions; changing the deploy or provisioner grants.

## Landed (2026-09-21)

DEC-038 $6 implemented: `reconcile_operator_bindings` establishes the operator's read-only RoleBinding in every namespace holding a Sol-managed workload, derived from the workspace's service inventory rather than the caller's scope, RBAC only (no Secret, no workload document), create-idempotent. Live: all three workload namespaces carry it after one `sol migrate apply`, with `notify-worker` untouched. Caught live in the first implementation: fail-fast meant one never-deployed namespace (`pluto-demo-ts`) aborted the loop and left `pluto-payments` without its grant; now per-namespace best-effort, absence is not a failure, and everything else is collected and reported.

Merged in #401; see `internal/pipeline/audits/findings/FND-0018-operator-grant-follows-command-not-workload.md` and
`FND-0019-status-verdict-unsupported-by-evidence.md`.
