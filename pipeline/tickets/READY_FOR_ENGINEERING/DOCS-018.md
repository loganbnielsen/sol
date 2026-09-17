---
id: DOCS-018
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Update the remaining reusable audit procedures to current Sol

`UX_AUDIT.md`, `STYLE_AUDIT.md`, and `SCAFFOLD_AUDIT.md` still target the old
Sun product: `sun` commands, `cli/sun`, `Sun.*` modules, removed hosted code,
and obsolete `sun dev`/`sun cloud init` workflows. `STYLE_AUDIT_FINDINGS.md` also
routes future passes through removed paths. The procedures cannot be followed
literally against this checkout.

## Acceptance criteria

- All reusable audit templates name current `sol` commands, modules, and paths.
- Checklist items for removed product surfaces are deleted, not renamed into
  fictional current features.
- Scaffold and UX procedures cover both language paths, with explicit verdicts
  for still-open TypeScript gaps rather than silence.
- `rg -n 'Sun|cli/sun|framework/sun|sun dev|sun cloud init' docs/audits` returns
  only deliberate historical findings, not active procedure text.

## Demo/example coverage

Documentation-only; no application behavior changes.
