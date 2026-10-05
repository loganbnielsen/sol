---
id: CODEX_STYLE_AUDIT-090
type: bug
severity: medium
title: "Emit complete outbox metric snapshots scoped to the relay owner"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Emit complete outbox metric snapshots scoped to the relay owner

**Depends on:** None.

**Principles:** 15, 18, 20–22, 30, 32, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `framework/ocaml/sol-outbox/lib/sol_outbox.ml:55`: grouped pending/age queries scan all kinds in the shared table.
- `:106`: report_metrics updates only returned groups and ignores missing groups and query errors.
- `framework/ocaml/sol-outbox/sol-outbox.md` defines per-kind metrics and logical ownership.
- TS reference metric callbacks reset gauges before applying successful snapshots.

## Mechanism and impact

After a kind drains, GROUP BY stops returning it and its previously emitted positive count/age remain in the metric store. Every relay can also report other owners' backlog because the query is not scoped to E.kinds. Old or unrelated values become misleading operational evidence.

## Remediation

Build one complete successful snapshot over the relay's bounded declared kind set, emitting zero or removing drained series consistently. Scope query/emission to owned kinds. Query failure must remain unavailable/error evidence and must not be converted into a zero-backlog claim.

## Acceptance criteria

- Positive pending/age after a failed publish clears after a successful drain.
- Initial empty owned queue has defined tested metric semantics.
- Two relays with disjoint kinds emit no other-owner series.
- Failed snapshot query cannot claim zero backlog; preserve diagnosable failure evidence.

- Demo/example: update the outbox reference example or spec with empty/drained/error snapshot semantics.
- Language parity: TS reset behavior is already equivalent for stale-series removal; verify owner scoping separately and record the verdict.

## Existing work and scope

FEAT-124 records the metric contract but does not own stale gauges. No matching open ticket was found. Retain the documented single-logical-owner relay model.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
