---
id: FEAT-060
type: feature
severity: low
source: review of FEAT-056 (SOL_ENV injection) 2026-09-11 — two acceptance criteria unmet
---

**Depends on:** FEAT-056 (done). Closes the two criteria that review found unmet.

FEAT-056 is `DONE`, but two of its criteria are not: `SOL_ENV` is only asserted for services, and it is documented nowhere. Both are small; this ticket exists so a `DONE` ticket isn't standing on unverified or undocumented behaviour.

## Scope

**1. Assert `SOL_ENV` for every primitive, not just services.**

`render` handles all three primitives through the same `configmap_doc` path, but only `svc_spec` is covered. Add the same assertions for `worker_spec` and `fn_spec`: present with the resolved environment, absent when no environment is resolved. The fixtures already exist.

Postgres URL, secrets and the env label are each asserted per primitive elsewhere in the same file, so the gap is inconsistent with the file's own standard rather than a deliberate choice.

**2. Document `SOL_ENV` as behaviour-only.**

FEAT-056's criterion was that the variable is "documented as behaviour-only, never topology". Nothing in `docs/`, `framework/`, `examples/` or the README mentions it. Document it in `docs/deployment/service-runtime-contract.md`'s "Config and secret injection" section, alongside the existing injection facts:

- `SOL_ENV` carries the resolved environment's name, and is **absent** when no target is resolved (`sol up` locally).
- It exists for **behaviour**: logging labels, feature flags, refusing destructive operations outside production.
- It must **never** be used for topology — no address, hostname, namespace or URL may be derived from it, because addressing is deliberately identical in every environment (DEC-016).

## Acceptance criteria

- `SOL_ENV` is asserted present-with-value and absent-by-default for `render_spec` on services, workers and functions.
- `docs/deployment/service-runtime-contract.md` documents `SOL_ENV`: what sets it, when it is absent, and the behaviour-only rule with the reason.
- No behaviour changes — this is coverage and documentation for what already ships.
