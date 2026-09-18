---
id: FEAT-057
type: feature
severity: medium
source: FEAT-056 split 2026-09-11
---

**Depends on:** FEAT-056.

Finish DEC-016's deploy-time isolation check after `SOL_ENV` injection lands.

## Scope

- Fail closed when two environments of one workspace resolve to the same cluster.
- Name both environments and the shared cluster in the error.
- Keep environment selection sourced from the resolved target. Do not add `sol deploy --env`.

## Acceptance Criteria

- A same-cluster check rejects two environments of one workspace resolving to the same cluster.
- The error names both environments and the cluster they share.
- Tests cover the rejection and a non-conflicting pair.
