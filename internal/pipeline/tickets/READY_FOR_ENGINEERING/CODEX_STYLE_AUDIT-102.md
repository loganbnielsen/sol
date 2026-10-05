---
id: CODEX_STYLE_AUDIT-102
type: bug
severity: medium
title: "Return and verify local cluster deletion outcomes instead of discarding them"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Return and verify local cluster deletion outcomes instead of discarding them

**Depends on:** None.

**Principles:** 20–24, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/local/sol_cli_local_cluster.ml:61`: delete ignores the process Result and returns unit.
- `cli/bin/cmd_local.ml:166`: dev_down calls delete and immediately returns Ok.
- Offline reproduction at the audit snapshot used fake k3d exiting 23 with sentinel deletion denied: `sol local infra down --cluster` exited 0 and omitted the cause.

## Mechanism and impact

A failed deletion is indistinguishable from successful teardown to scripts and the operator. This is a small concrete error-boundary defect; no broader cluster management abstraction is needed.

## Remediation

Return the typed process failure from delete, propagate it at dev_down, and observe absence where the command promises completed removal. Classify confirmed absent separately from failed k3d observation, preserving evidence.

## Acceptance criteria

- A fake k3d deletion exit 23 yields nonzero command status and the original reason.
- Successful deletion followed by confirmed absence succeeds.
- Failed post-delete observation cannot claim verified removal.
- Already absent behavior is explicit and idempotent.

- Demo/example: update local teardown documentation/example if its completion contract changes.
- Language parity: no language-specific behavior.

## Existing work and scope

REFAC-139 extracted the local cluster adapter; no open owner was found for its ignored delete result. This is distinct from endpoint startup readiness.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
