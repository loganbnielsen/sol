---
id: DOCS-016
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Make the first-class OCaml and TypeScript story consistent

README calls both languages first-class, while the tutorial and roadmap still
define Sol as OCaml-only. README and the TS demo also inventory only
`@sol-fab/kafka` and `@sol-fab/obs`, although the runnable service and worker now
consume `@sol-fab/svc` and `@sol-fab/worker` too.

## Acceptance criteria

- README, tutorial, roadmap, and `demo_ts` README agree on the product model.
- All four published `@sol-fab/*` packages and their ownership are documented.
- The mixed-language Pluto example is linked as the current runnable proof.
- Missing TS scaffolding and deployed CI are explicitly linked to FEAT-084 and
  FEAT-087; docs do not claim those incomplete paths already work.

## Demo/example coverage

Documentation-only; the existing mixed Pluto project is the referenced example.
