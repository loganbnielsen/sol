---
id: CODEX_STYLE_AUDIT-094
type: bug
severity: medium
title: "Preserve the original rollout failure when adding deployment diagnosis"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Preserve the original rollout failure when adding deployment diagnosis

**Depends on:** None.

**Principles:** 20–22, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/deploy/sol_cli_up_execution.ml:93`: wait_for_service_rollout discards the rollout_status Error in a wildcard branch.
- Secondary diagnosis replaces it with unhealthy/undetermined text, or the generic rollout failed message when current pods look healthy.

## Mechanism and impact

A useful rollout timeout, forbidden response, or subprocess launch error is lost. A later successful probe cannot explain why the original operation failed; operator evidence is replaced by a different observation.

## Remediation

Retain and render the primary typed process failure, adding secondary diagnosis as context rather than substitution. Preserve the non-success outcome even if later pod state is healthy.

## Acceptance criteria

- Timeout, authorization denial, and launch failure preserve their original cause.
- Secondary unhealthy/undetermined/healthy diagnosis remains useful additional context.
- Fake rollout failure followed by healthy diagnosis still fails and includes the first error.
- Avoid performing extra probes merely to manufacture a replacement explanation.

- Demo/example: update the deployment failure example or tutorial if its user-facing report changes.
- Language parity: rollout reporting is a shared CLI path; record equivalent behavior for both languages.

## Existing work and scope

The readiness-model ticket addresses platform observation; this ticket owns the workload rollout adapter. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
