---
id: CODEX_STYLE_AUDIT-097
type: bug
severity: medium
title: "Make run-log append failure obey the lifecycle error and resource policy"
source: internal/pipeline/audits/2026-10-04_37_principles_review.md
---

Make run-log append failure obey the lifecycle error and resource policy

**Depends on:** None.

**Principles:** 20, 22–24, 35 in the source review's 37-point checklist.

**Premise verified:** Read implementations and callers at `0303432b031f04162d524dfb56f608722a047018` on 2026-10-04; the behavior below remains present. Recheck against current main before implementation.

## Evidence and affected boundary

- `cli/lib/cloud/sol_cli_run_log.ml:95`: ordinary log writes catch Sys_error and warn.
- `:121`: append_phase_log opens/writes/closes without exception translation or guaranteed close.
- `cli/lib/cloud/sol_cli_terraform_plan.ml:189`: show_and_record appends inside a Result operation.
- `cli/lib/cloud/sol_cli_cloud_apply.ml:171`: lifecycle cleanup branches handle Error outcomes, not incidental append exceptions.

## Mechanism and impact

An unavailable log path, disk-full condition, or write/close error can escape the Result-controlled operation and skip normal failure arbitration. Opened channels can also escape cleanup on write failure. This filing establishes the unchecked exception; it does not claim a particular live bootstrap leak was observed.

## Remediation

Use protected channel ownership and the existing best-effort run-log policy for append. Where a phase genuinely requires a persisted artifact, encode its failure explicitly and keep cleanup in the operation's failure path. Do not let incidental diagnostics introduce unchecked operational exceptions.

## Acceptance criteria

- Missing/unwritable/full append target cannot raise through show_and_record.
- Operation result and intended cleanup remain observable under append failure.
- Opened channels close after write/close errors.
- Failure-injection coverage verifies warning/context and typed behavior, without relying on filesystem permissions that root bypasses.

- Demo/example: not applicable: internal run logging.
- Language parity: no language-parity impact.

## Existing work and scope

INFRA-106 is stdout/SIGPIPE ownership in the qualification harness, not this file-append boundary. No matching open owner was found.

This filing records a source review, not a completed implementation or live qualification. Keep the implementation focused on the named boundary; preserve cancellation, cleanup, and established successful behavior.
