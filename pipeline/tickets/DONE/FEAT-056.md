---
id: FEAT-056
type: feature
severity: medium
source: DEC-016 split 2026-09-11
---

**Depends on:** DEC-016.

Expose DEC-016's resolved target environment to application code.

## Scope

- Thread the resolved target environment into `configmap_doc`, so application code receives `SOL_ENV` through the existing `<name>-env` ConfigMap mechanism.
- Treat `SOL_ENV` as behaviour-only: logging labels, feature flags, and destructive-operation refusal; never topology or internal addressing.
- Keep environment selection sourced from the resolved target. Do not add `sol deploy --env`.

## Acceptance criteria

- `SOL_ENV` is available to application code through the existing `<name>-env` ConfigMap path.
- The rendered manifests still keep environment identifiers out of namespaces, service names, and injected internal URLs.
- Tests cover `SOL_ENV` injection and the no-target default.

## Follow-up

FEAT-057 carries the same-cluster rejection.
