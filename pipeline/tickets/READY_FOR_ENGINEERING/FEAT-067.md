---
id: FEAT-067
type: feature
severity: medium
source: split from FEAT-066, 2026-09-12 — slice 1 of the release record
---

**Depends on:** None.

**Related:** DEC-018 (the decision this implements), FEAT-050 (digest-pinned artifacts — until it lands, resolved workloads carry image references, not digests), FEAT-065 (requested scope + resolved set in the plan), FEAT-066 (slices 2–3: rollback execution, leases and retention).

Write the release record on every deploy, and add `sol releases` to list them.

## Context

This is slice 1 of FEAT-066, split out so it can land read-only and with no
mutation risk, exercising the record shape against real deploys before rollback
depends on it. The mutation half — `sol rollback <release-id>`, the migration
boundary check, the lease and retention — stays in FEAT-066.

## Work

- **Record on deploy:** one immutable ConfigMap per release (`immutable: true`),
  written in the same `default`-namespace convention the existing
  `sol-deploy-state-<workspace>` ConfigMap uses. Labels for lookup
  (`sol.dev/type=release`, `sol.dev/target`, `sol.dev/scope`,
  `sol.dev/workspace`), annotations for the long fields.
- **Pointer object:** a mutable `sol-release-current-<workspace>` ConfigMap
  naming the current release, so `sol releases` and a later rollback can find
  "what is deployed" without scanning.
- Never store secret values — references (key names) only.
- **`sol releases`** lists id, commit, scope, created, newest first.
- Fields follow DEC-018: release id, created-at, workspace, target, git commit
  and dirty flag, requested scope, resolved workloads (name + image reference),
  migrations, mode. Artifact digests arrive with FEAT-050; until then the image
  reference is what the record can honestly carry.

## Acceptance criteria

- Every `sol up` and `sol deploy` writes a release record; `sol releases` shows
  it.
- A release ConfigMap cannot be edited in place (`immutable: true`).
- The record carries the requested scope and the resolved workloads, so a later
  rollback can restore the resolved set rather than today's membership of that
  scope.
- No secret value is stored — only names/references.
