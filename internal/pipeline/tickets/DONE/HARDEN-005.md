---
id: HARDEN-005
type: verification
severity: medium
title: Cloud boundary fitness test, re-running the Azure-on-paper change surface with the guards at zero
source: internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md
---

**Depends on:** REFAC-093, REFAC-098.

**Related:** HARDEN-004

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S11 and § End-state report. The plan is authoritative for scope; this ticket carries the dependency and the acceptance criteria.

## Remediation

Do not implement Azure. Repeat the boundary audit's Azure-on-paper test against the final code. Baseline: about 5 registration touches and about 45 edits to existing lifecycle code. Target: Azure roots + Azure capabilities + one registration arm + credentials + qualification, with no generic identity widening and no scattered lifecycle edits.

## Acceptance criteria

- The REFAC-092 provider-match and wildcard allowlists are at zero, or each residual entry is justified in one line.
- The end-state report in the plan's § End-state report is written, with evidence for every preserved invariant.

## Completion notes (required)

- Demo/example: not applicable (cloud lifecycle internals) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `internal/planning/WORK_SUMMARY.md`, and any finding/decision whose status this changes.

## Completion notes

**Premise verified (2026-09-25):** after REFAC-098, provider dispatch stood at 3 (`cmd_cloud_tf.ml`
`credentials_result` ×2, `sol_cli_config.ml` ×1), and no fitness test had been run against the
final code.

**Done.**
- **Credential readiness** moved behind `Sol_cli_provider_registry.credentials`. The AWS and
  GCP bodies were moved verbatim into `Sol_cli_{aws,gcp}_cluster`, and `cmd_cloud_tf.ml` now
  has 0 provider-dispatch sites.
- **The ratchet is at 1 and 0** (qualified provider matches and wildcards). The residual
  `target_empty` placeholder is justified in the allowlist.
- **The Azure-on-paper test was measured, not estimated.** A hypothetical `Azure` constructor
  was built in a throwaway worktree. The compiler named exactly four registry sites, and the
  library, command and tests compiled once those were stubbed. The details and the resulting
  surface are in the report.
- **One hard-coded provider list remained, and is fixed.** `check_destroy_completeness.sh`
  named its target roots by hand, so a new provider's root would have silently escaped it.
  - It now derives them from `Sol_cli_provider.to_string`, and fails closed if that list
    cannot be read.
  - Its self-test gained a positive control: a fake `azure` provider's defective root is
    rejected without editing the guard.
- **The end-state report** is at `internal/pipeline/audits/2026-09-25_cloud_lifecycle_end_state.md`.
  It covers before and after, the deleted model, the provider change surface against the
  baseline (about 45 edits then, 4 registry arms now), complexity, and executable evidence for
  every preserved invariant.

**Verification.**
- The full `dune test cli/sol/test/` passes, and the offline lifecycle harness exits 0.
- `check_provider_dispatch.sh` and `test_destroy_completeness_check.sh` pass.
- The real repo's completeness scan is unchanged: 6 files in 2 roots.

**Bookkeeping.**
- Demo/example: not applicable. These are cloud lifecycle internals and a verification
  report.
- Language parity (DEC-022): no application-facing impact.
