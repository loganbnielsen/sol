---
id: FEAT-056
type: feature
severity: medium
source: DEC-016 split 2026-09-11
---

**Depends on:** DEC-016.

Finish the runtime enforcement pieces from DEC-016 once the decision record and manifest invariant test land separately.

## Scope

- Thread the resolved target environment into `configmap_doc`, so application code receives `SOL_ENV` through the existing `<name>-env` ConfigMap mechanism.
- Treat `SOL_ENV` as behaviour-only: logging labels, feature flags, and destructive-operation refusal; never topology or internal addressing.
- Fail closed when two environments of one workspace resolve to the same cluster, naming both environments and the shared cluster in the error.
- Keep environment selection sourced from the resolved target. Do not add `sol deploy --env`.

## Acceptance criteria

- `SOL_ENV` is available to application code through the existing `<name>-env` ConfigMap path.
- The rendered manifests still keep environment identifiers out of namespaces, service names, and injected internal URLs.
- A same-cluster check rejects two environments of one workspace resolving to the same cluster, with an error naming both environments and the cluster.
- Tests cover both `SOL_ENV` injection and the same-cluster rejection.
