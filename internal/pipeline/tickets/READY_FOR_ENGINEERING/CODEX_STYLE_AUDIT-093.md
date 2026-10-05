---
id: CODEX_STYLE_AUDIT-093
type: bug
severity: medium
title: "Keep readiness evidence and decisions typed through cloud apply and target status"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Keep readiness evidence and decisions typed through cloud apply and target status

**Depends on:** None.

**Principles:** 2, 6, 20–22, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/cloud/sol_cli_cloud_lifecycle.ml:218`: readiness can express only Established or Unmet.
- `:484`: run callback None and a successful unacceptable result become the same generic Unmet.
- `cli/bin/cmd_target.ml:63`: every subprocess failure becomes None, dropping cause.
- `cli/lib/cloud/sol_cli_cloud_apply.ml:146`: lifecycle success is decided by comparing readiness_summary text to Ready.

## Mechanism and impact

Permission denial, timeout, launch failure, and a confirmed unmet condition are indistinguishable. Target status reports a definite unmet condition where observation failed. Formatting text also controls lifecycle advancement, coupling rendering to semantic success.

## Remediation

Return typed ready/unmet/unobservable outcomes with the probe's original evidence. Aggregate typed outcomes for cloud decisions, rendering only at the reporting boundary. Keep bounded readiness polling and current check ownership; no new state-machine framework is needed.

## Acceptance criteria

- Permission denial, missing tool, timeout, malformed result, and confirmed unmet state remain distinguishable.
- Ready requires every required check to be successfully observed ready.
- Changing report wording cannot change lifecycle success.
- Apply and target-status tests retain original tool detail and never report unobservable as confirmed absent/unmet.

- Demo/example: update a target readiness/diagnosis example with unknown versus unmet behavior.
- Language parity: shared CLI behavior applies equally to both languages; record no divergence.

## Existing work and scope

FND-0068 concerns certificate readiness coverage, not classification of existing checks. BUG-206 owns platform install mechanism, not this evidence model; this ticket does not claim to explain that timeout.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
