---
id: CODEX_STYLE_AUDIT-096
type: bug
severity: medium
title: "Refuse unreadable Terraform materialization provenance before refreshing assets"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Refuse unreadable Terraform materialization provenance before refreshing assets

**Depends on:** None.

**Principles:** 15, 19, 21–24, 34, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/cloud/sol_cli_terraform_workdir.ml:58`: read_lines maps every Sys_error to an empty list.
- `:80`: previous manifest identifies stale copied files to remove.
- `:93`: current source list replaces the manifest after copying.

## Mechanism and impact

An unreadable existing .sol-materialized becomes first materialization. Removed .tf files remain active and Terraform continues evaluating them; replacing the manifest loses the cleanup history. Individual atomic writes do not make that failed observation valid.

## Remediation

Read provenance through a Result, allowing only confirmed initial absence as empty. Refuse preparation before replacing files or running Terraform when existing provenance is unobservable. Keep runtime/state artifacts protected.

## Acceptance criteria

- Confirmed initial absence permits materialization.
- Existing-manifest read failure leaves manifest/assets unchanged and prevents Terraform invocation.
- Successful refresh removes stale source assets and preserves runtime/state files.
- Test failed-read and stale-removal transitions through materialize.

- Demo/example: not applicable: internal asset preparation; record why.
- Language parity: no language-parity impact.

## Existing work and scope

REFAC-140 owns splitting, not this failure classification. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
