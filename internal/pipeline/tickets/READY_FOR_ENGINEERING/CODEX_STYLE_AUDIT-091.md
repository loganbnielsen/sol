---
id: CODEX_STYLE_AUDIT-091
type: bug
severity: medium
title: "Keep declared outbox kinds round-trip safe between publish and relay selection"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Keep declared outbox kinds round-trip safe between publish and relay selection

**Depends on:** None.

**Principles:** 1, 2, 7, 15, 21, 29, 31, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `framework/ocaml/sol-outbox/lib/sol_outbox.ml:36`: relay SQL splits a comma-separated string into kind names.
- `:92`: publish verifies only membership in E.kinds.
- `:201`: relay serializes declarations with String.concat comma.
- Unlike Sol_jobs kind validation, the outbox does not establish that declared names survive this encoding.

## Mechanism and impact

For E.kinds containing `a,b`, publishing that declared kind succeeds and can commit an intent, but relay selection asks SQL for a or b and never selects the committed row. An empty kind set also starts a relay that polls nothing. The accepted publication contract is broader than the relay's selectable contract.

## Remediation

Establish one authoritative declaration/encoding contract before producer or relay effects. Either reject names that cannot round-trip through the existing encoding or use a real SQL array encoding preserving supported names. Validate empty/duplicate declarations deliberately. Preserve valid uppercase OrderPlaced/OrderFulfilled names; do not blindly copy the jobs lowercase regex.

## Acceptance criteria

- Comma-containing/empty declarations cannot commit unserviceable intents.
- Empty E.kinds refuses relay startup before polling.
- Every valid published kind can be selected by its relay.
- Producer and relay share the same tested rule; retain current uppercase examples.

- Demo/example: update package spec and runnable outbox example if public kind validation changes.
- Language parity: check TS outbox kind selection and record implemented/equivalent/deferred with a concrete trigger.

## Existing work and scope

Sol_jobs validation is a precedent, not a dependency. No matching open outbox ticket was found. Do not add distributed fencing or redesign ordering in this fix.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
