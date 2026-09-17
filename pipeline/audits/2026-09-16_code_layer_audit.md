# Sol code-layer audit — 2026-09-16

**Scope:** public framework APIs, CLI boundary types, OCaml/TypeScript example
paths, and over-engineering. Live infrastructure and sibling `*-eio` internals
were excluded because this pass found no cross-package premise requiring them.

## Ranked findings

No new actionable layer violation was found.

- Public framework surfaces are kept in `.mli` files; Kafka service helper
  modules are explicitly `private_modules` and re-export through
  `Kafka_service`.
- Runtime lifecycle sharing sits in the small `sol-runtime` boundary and the
  duplication guard confirms there is one signal-handler implementation.
- Deployment plans carry abstract Kubernetes, release, and deployment IDs until
  manifest/log/store serialization edges. The focused type audit found no new
  premature identity erasure.
- The mixed Pluto workspace proves that deployment discovery is language-neutral;
  language-specific runtimes remain below the unit boundary.
- Small duplicated TypeScript `intEnv` helpers should stay duplicated: two tiny
  callers do not justify another shared package or abstraction.

Residual risk is documentation, not dependency direction: package specs expose
stale representations of otherwise sound public APIs (DOCS-017).

`app -> Sol public API -> typed event/plan -> language/provider adapter -> transport/runtime`

## Ponytail pass

No speculative factory, single-implementation interface, or removable wrapper
was strong enough to ticket. The largest safe cut is documentation drift, not
runtime code. `net: -0 runtime lines, -0 deps possible` until AUDIT-068's required
dependency replacements are validated.
