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
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes (2026-09-24)

- **`internal/ci/check_provider_dispatch.sh`** counts `Sol_cli_provider.Aws|Gcp` and
  `Aws_outputs|Gcp_outputs` occurrences per file under `cli/sol/{lib,bin}` (the provider module
  itself exempt) against `internal/ci/provider_dispatch_allowlist.txt`. Growth fails; an unrecorded
  reduction fails too, so every PR that moves knowledge behind a capability lowers the ratchet. Stale
  entries fail. Wired into CI next to the destroy-completeness guard.
- **Wildcard provider arms** are detected by indentation: a `| _` arm counts only if a sibling arm in
  the same column is a provider constructor. So an enclosing option match's wildcard next to
  provider arms is not miscounted (mutation case 7).
- **Baseline (main @ 73d13ff9): 77 dispatch occurrences** — `cmd_cloud_tf.ml` 44,
  `sol_cli_cloud_lifecycle.ml` 19, `.mli` 2, `sol_cli_config.ml` 7, `sol_cli_destroy_verification.ml`
  4, `sol_cli_profile_preflight.ml` 1 — **and 2 wildcard provider arms**, both in `sol_cli_config.ml`:
  production DB deletion protection (AWS only, GCP relying on its root default) and the production
  profile's node shape (AWS only). The boundary audit's "about 45 edits" counted distinct match
  sites; 77 counts every occurrence, including each arm.
- **Correction to the record:** SEC-010's notes listed `sol_cli_cloud_lifecycle.ml:52` as a wildcard
  provider match. It is not; that wildcard belongs to the enclosing `match target.state_bucket`. The
  line-based search behind the boundary audit could not tell the difference; this guard can. SEC-010's
  notes are corrected in this PR.
- **Evidence:** `test_provider_dispatch_check.sh` (9 cases: new module, growth, unrecorded reduction,
  wildcard, allowlisted wildcard, nested non-provider wildcard, stale entry, provider module exempt,
  baseline). Historical positive control: run against the pre-SEC-010 tree (`git archive dc8d2b61`),
  it flags `sol_cli_db_credential.ml` for both a new dispatch and a wildcard arm — the defect SEC-010
  fixed.
- Demo/example: not applicable (CI guard). Language parity (DEC-022): no application-facing impact.
