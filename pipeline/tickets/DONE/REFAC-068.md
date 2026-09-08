---
id: REFAC-068
type: refactor
severity: medium
source: cross-cutting-design-review 2026-08-31
branch: refac-068-070-cleanup
worktree: none (direct main-checkout branch, no linked worktree)
pr: https://github.com/loganbnielsen/sun/pull/65
---

Replace scaffolded app `failwith` sprawl with one entrypoint failure boundary

**Depends on:** None.

## Problem

Generated service, worker, and function entrypoints contain repeated `failwith`
calls for config, database, Kafka, and runner failures. That is acceptable for
tiny examples, but poor as generated production starter code.

## Goal

Keep user handlers result-based and convert startup/runtime errors once at the
generated `main` boundary.

## Acceptance criteria

- Scaffold templates use one small `fatal : string -> 'a` or equivalent at each
  generated executable boundary.
- Repeated inline `failwith (label ^ ...)` patterns are removed from generated
  templates.
- Existing scaffold golden tests are updated.
- Library callback signatures remain unchanged unless a separate design review
  says otherwise.
