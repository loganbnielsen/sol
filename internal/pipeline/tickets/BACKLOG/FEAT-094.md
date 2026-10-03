---
id: FEAT-094
type: feature
severity: low
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Detect edits to already-applied migrations (checksum validation)

**Depends on:** None.

**Finding:** FND-0032 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding).

## Problem

Neither pg-eio nor Sol's gate records a content checksum; editing an applied migration file is silently ignored.

## Decision Required

Should a checksum mismatch fail the deploy gate, or only warn? (Flyway fails; some teams allow repeatable edits.)

## Remediation

Store a checksum per applied migration and have `status`/the deploy gate report a mismatch.

## Acceptance criteria

- A modified applied migration is reported by `sol migrate status` and fails the production gate.

## Disposition (2026-10-03) — decision required

Smallest decision: should an edited already-applied migration fail the deploy gate (Flyway-style) or only warn? Consequence: fail-closed can block a legitimate repeatable edit; warn keeps a silent divergence.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.
