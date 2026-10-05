---
id: CODEX_STYLE_AUDIT-101
type: bug
severity: medium
title: "Require verified local infrastructure endpoint readiness before reporting success"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Require verified local infrastructure endpoint readiness before reporting success

**Depends on:** None.

**Principles:** 6, 15, 20–24, 28, 33, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/bin/cmd_local.ml:117`: start_port_forwards sleeps two seconds and starts supervisors, reporting startup errors only as warnings.
- `:131`: print_summary unconditionally prints each endpoint's success summary.
- `:142`: dev_up returns Ok after these functions.
- `cli/lib/kube/sol_cli_port_forward.ml:220`: start returns Ok after fork; child exec/bind/target failures can happen later.
- Unlike cmd_up's expose_service path, this caller performs no check_alive or endpoint readiness observation.

## Mechanism and impact

Infrastructure installation can succeed while advertised developer endpoints are unavailable, or a conflicting listener serves a different target. A fixed sleep before startup proves neither supervisor nor endpoint readiness. The command's success is stronger than its observed evidence.

## Remediation

Give the local infrastructure controller a bounded endpoint-start/readiness phase with typed outcomes. Observe required forwards after launch and verify the intended endpoint contract before success summaries. Report any optional endpoints as optional explicitly. Preserve already-created cluster/chart resources on exposure failure, with actionable retry guidance; do not pretend the release itself must be destroyed.

## Acceptance criteria

- Supervisor exec failure, target unavailable, bind conflict, and readiness deadline exhaustion prevent success/ready output and return the intended nonzero outcome for required endpoints.
- Valid ready endpoints succeed without a fixed timing assumption.
- Partial forward startup has explicit owned cleanup/retry behavior.
- Offline fake supervisor/probe fixtures establish the contract without cloud resources.

- Demo/example: update and exercise local infra onboarding guidance with truthful readiness/failure output.
- Language parity: infrastructure readiness is shared across languages.

## Existing work and scope

FRIC-001/UX-002 fixed misleading application exposure in sol up, not local infra's unconditional summaries. CODEX_STYLE_AUDIT-083 owns supervisor implementation, not this caller's readiness contract.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
