---
id: DOCS-010
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-08_docs_audit.md
---

TypeScript packages (`@sol/kafka`, `@sol/obs`) and the TS demo are undocumented in all primary docs

**Description:** `packages/sol-kafka/`, `packages/sol-obs/`, and the migrated `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}` (built via FEAT-034/035/038/039, with a real live cross-service trace-linked run proving they work) are not mentioned anywhere in `README.md`, `docs/guides/TUTORIAL.md`, or `docs/planning/ROADMAP.md`.

**Impact:** This is meant to be the framework's TypeScript showcase. A reader of the primary docs has no way to discover it exists, undermining its purpose before it's ever shown to anyone.

**Remediation:** Add a section to `README.md` (or a dedicated `docs/guides/TYPESCRIPT.md` linked from README/TUTORIAL) introducing `@sol/kafka`/`@sol/obs`, pointing at `examples/pluto/app/demo_ts/README.md` for the runnable example, and noting these are in-tree packages (not yet published to npm), matching this repo's own established language for the OCaml `*-eio` extraction pattern.
