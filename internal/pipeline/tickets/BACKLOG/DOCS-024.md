---
id: DOCS-024
type: docs-finding
severity: low
title: Give TypeScript a framework/ slot pointing at its repositories
source: operator review notes (2026-09-25), internal/pipeline/audits/2026-09-25_organization_proposal.md rule 5
premise: "test -f framework/typescript/README.md"
---

**Depends on:** DEC-046.

**Premise verified (2026-09-25):** `ls framework/` → `ocaml/` and `README.md` only. `framework/README.md` says a `framework/typescript/` directory "would be empty today, so it does not exist". A README-only directory isn't empty, and it makes TypeScript visible to someone browsing the tree.

## Remediation

- Add `framework/typescript/README.md`, pointing to the `@sol-fab/kafka` and `@sol-fab/obs` packages and repositories, the TypeScript scaffold templates, and `examples/pluto/app/demo_ts`.
- Update `framework/README.md` so both languages are listed the same way.

## Acceptance criteria

- `framework/` lists one directory per first-class application language.
- **Demo/example:** the README links `examples/pluto/app/demo_ts`.

## Completion notes (required)

- Language parity (DEC-022): discoverability only; no capability change.
