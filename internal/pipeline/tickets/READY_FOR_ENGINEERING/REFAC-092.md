---
id: REFAC-092
type: refactor
severity: medium
title: CI guard that shrinks provider dispatch outside approved modules and forbids new wildcard provider matches
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** SEC-010.

**Related:** HARDEN-005

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S1.c. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

**Premise verified 2026-09-24:** no such guard exists under `internal/ci/`. The boundary audit counted 27 provider matches plus 17 `Aws_outputs`/`Gcp_outputs` matches in `cli/sol/bin/cmd_cloud_tf.ml`, 12 in `sol_cli_cloud_lifecycle.ml`, 7 in `sol_cli_config.ml` and 4 in `sol_cli_destroy_verification.ml`.

## Remediation

An `internal/ci/` check in the style of the existing guards:

- counts matches on `Sol_cli_provider.Aws|Gcp` and `Aws_outputs|Gcp_outputs` outside approved provider/registry modules, against a committed allowlist that may only shrink;
- **forbids new wildcard matches on `Sol_cli_provider.t` immediately**, with the post-SEC-010 survivors allowlisted, each with a one-line reason (`sol_cli_config.ml:1432`, production DB protection set for AWS only; `sol_cli_cloud_lifecycle.ml:52`, backend-config fallback).

## Acceptance criteria

- The check runs in CI and fails on a newly added provider match or wildcard (mutation-tested, HARDEN-003 style).
- The baseline count is recorded in the completion notes; later stages report it shrinking.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.
