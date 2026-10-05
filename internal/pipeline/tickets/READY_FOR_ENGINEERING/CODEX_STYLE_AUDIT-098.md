---
id: CODEX_STYLE_AUDIT-098
type: bug
severity: medium
title: "Validate finite operational duration overrides before cloud mutation"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Validate finite operational duration overrides before cloud mutation

**Depends on:** None.

**Principles:** 2, 7, 15, 21, 23, 24, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/cloud/sol_cli_cloud_wiring.ml:349`: SOL_PLATFORM_READINESS_TIMEOUT_S accepts infinity and silently defaults malformed input to 900.
- `cli/lib/cloud/sol_cli_aws_destruction.ml:253`: SOL_DESTROY_SNAPSHOT_INTERVAL_S accepts infinity.
- `cli/lib/cloud/sol_cli_aws_cluster.ml:172`: SOL_WHOAMI_RETRY_INTERVAL_S checks finiteness but silently defaults malformed input to 10.

## Mechanism and impact

Infinity makes the readiness deadline unreachable or selects an unbounded sleep. Explicit invalid settings are silently replaced by a different policy, defeating operator intent and predictable bounded execution.

## Remediation

Normalize these actual duration inputs through one Result-returning finite nonnegative parser before mutation. Omission uses documented defaults; explicit invalid values return contextual configuration errors. Keep zero semantics intentional per setting.

## Acceptance criteria

- Omitted/blank optional values follow the documented unset policy.
- Valid zero and finite values retain supported semantics.
- Garbage, negative, NaN, and infinite values refuse before mutation.
- No unbounded poll/sleep can be selected through these overrides.
- Cover each setting's caller, not only the helper.

- Demo/example: document or demonstrate valid tuning and invalid-input refusal.
- Language parity: no language-specific behavior: provider lifecycle is shared.

## Existing work and scope

No matching open owner was found. Keep this scoped to duration overrides rather than creating a general configuration framework.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
