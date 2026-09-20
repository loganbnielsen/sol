---
id: INFRA-051
type: bug
severity: low
title: Decide how release pruning reads the release set it may not list
source: audit finding FND-0014 — live AWS Run 8 step 6
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0014-release-pruning-lists-configmaps-it-may-not-list.md`

## The defect

Every successful deploy warns:

```text
warning: could not prune old releases: kubectl get configmap failed:
Error from server (Forbidden): configmaps is forbidden: … cannot list resource
"configmaps" in API group "" in the namespace "default"
```

Release records live in `default`, where the deploy identity holds a deliberately
narrow exception (`sol_boundary_lease`): `configmaps` with `create`, and with
`get`/`update`/`delete`. **`list` is absent by design.** Pruning is a discovery
operation — it asks which releases exist — so it is refused and silently skipped.

Not urgent: the deploy succeeds and the workload runs. But release records
accumulate unboundedly in `default`, and a rollback path the profile relies on
degrades with only a warning to show for it.

## First: choose the contract

Do not implement before deciding, because the two readings differ in kind:

- **Broaden the exception** to `list` on `configmaps` in `default`. Small, but it
  widens the boundary the RBAC file argues hardest for, and `list` cannot be
  name-scoped — the same limitation the file already documents for `create`.
- **Keep the boundary, change the mechanism**: read the release set where Sol can
  address it by name (the workspace Secret, or the boundary-lease ConfigMap it
  already owns), or make the skip a diagnosed outcome rather than a warning.

Record the choice as a `DEC` if it is a contract decision, then implement.

## Acceptance criteria

1. A deploy either prunes the release set it is entitled to see, or records
   explicitly that it did not and why — never a bare warning.
2. The deploy identity's grants are unchanged unless the decision above says
   otherwise, and `check_production_infra.sh` still pins them.
3. Whichever mechanism is chosen, the matrix has a row for it, so "pruning did not
   happen" is a qualification result rather than an unnoticed warning.

## Out of scope

The namespace/RBAC mismatch (`INFRA-048`) and the secret-backend default
(`INFRA-050`). This is the same INV-AUTH-6 shape, but a separate defect.
