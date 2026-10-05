---
id: CODEX_STYLE_AUDIT-106
type: bug
severity: medium
title: "Fail topic setup when required Kafka topics were not successfully established"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Fail topic setup when required Kafka topics were not successfully established

**Depends on:** None.

**Principles:** 15, 20–23, 28, 29, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `platform/local/scripts/create-topics.sh:14`: all topic-create failures are suppressed by a grep pipeline and `|| true`.
- Final topic list proves only listing connectivity.
- Offline fake rpk allowed listing and denied all creates with exit 17: setup exited 0 with no required topic present.

## Mechanism and impact

Selective ACL denial or invalid creation parameters can leave required topics absent while setup reports success. This differs from an unreachable broker, which also prevents the final list and was already covered.

## Remediation

Distinguish valid existing topics from genuine create failures and verify required topic metadata through structured output. Preserve original broker failure evidence; establish the setup's partition/replication contract explicitly rather than ignoring incompatible existing shape.

## Acceptance criteria

- Existing valid required topics pass idempotently.
- List-success/create-denied, missing required topic, and incompatible declared shape fail.
- Original create/metadata errors remain visible.
- Offline broker fixtures exercise selective failure and valid existing topics.

- Demo/example: not application API work; update maintainer setup guidance if necessary and record that scope.
- Language parity: no language-parity impact.

## Existing work and scope

BUG-129 covers unreachable broker readiness and deliberately retained other setup behavior. This selective-create failure is a new concrete boundary case.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
