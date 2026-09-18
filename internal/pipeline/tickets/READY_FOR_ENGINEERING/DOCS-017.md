---
id: DOCS-017
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Bring framework package specs back to their public API contracts

The Kafka-service and service package specs contain stale signature blocks:
`config_of_env` drops its `result`, old flat Kafka module names remain,
decode-error bytes have the wrong optionality, `Response.not_implemented` is
documented but not public, `Request.t` omits `trace_ctx`, and `Service.run` has
the wrong result type and omits `?stop`.

## Acceptance criteria

- Every public signature shown in `framework/kafka-eio-service/*.md` and
  `framework/sol-svc/*.md` matches its current `.mli` exactly.
- Obsolete public members and module names are removed.
- Code examples compile, or are explicitly marked illustrative.
- Add the smallest maintainable drift check: compiled snippets if practical,
  otherwise a focused signature/doc assertion; do not build a documentation
  framework.

## Demo/example coverage

Documentation/API-contract correction only; no runnable app behavior changes.
