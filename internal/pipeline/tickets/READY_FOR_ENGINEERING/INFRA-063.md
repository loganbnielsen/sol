---
id: INFRA-063
type: refactor
severity: high
title: Reconcile every mutable Sol-owned ConfigMap the deploy identity writes, as one object class
source: audit finding FND-0023
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0023-mutable-configmap-write-class.md`

## Problem

Three distinct Sol-owned mutable ConfigMaps in `default` are written with an operation
that becomes a patch when the object exists, while the deploy identity holds
`get`/`list`/`watch`/`create`/`update` there and never `patch`:

| Object | Effect |
|---|---|
| `sol-release-current-<workspace>` | the deploy reported success without recording the pointer (**FND-0014**, fixed) |
| release records | pruning cannot run (`INFRA-051`) |
| `sol-deploy-state-<workspace>` | **BUG-025's drift check has no state to compare against** (observed live) |

## Why one ticket and not a fourth

The first instance was fixed by changing the object's *write mechanism* (`get`, then
`create` when absent or `replace` when present — no generic `patch` required). The rest
are the same mismatch, on the same class, written by the same identity, authorised by
the same grant. Fixing another object name individually guarantees a fifth.

## Acceptance criteria

1. Audit every mutable Sol-owned ConfigMap the deploy identity writes; list them in the
   finding or a doc, with what each carries.
2. Each uses the established narrow mechanism (`get` → `create`/`replace`, never a
   generic `patch`).
3. Coverage that a **second** write of an existing object succeeds — the case all three
   failures share.
4. BUG-025 is not qualified until its state object can actually be maintained; add
   evidence that the drift check observes a real change rather than an absent object.

## Out of scope

Broadening the deploy identity's RBAC to include `patch` on ConfigMaps; the narrow
mechanism is already proven and keeps the identity boundary as it is.
