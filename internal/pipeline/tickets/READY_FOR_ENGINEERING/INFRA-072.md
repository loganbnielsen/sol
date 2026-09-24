---
id: INFRA-072
type: bug
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Destroy must observe retained artifacts before reporting them

**Depends on:** None.

**Finding:** FND-0046 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`retention_report` prints "final snapshot X" or "no residual billable artifacts" from the policy; nothing checks the snapshot exists/`available` or that `none` left no snapshots or retained automated backups (ADR 0004 postcondition). FND-0006 qualified the mechanism once; each destroy still reports on faith.

## Remediation

After destroy, query the provider (`aws rds describe-db-snapshots …`, automated backups) and pass typed evidence to the report; a missing snapshot or unexpected residue fails the command.

## Acceptance criteria

- Offline test with stubbed aws: missing snapshot → non-zero exit naming it; residue under `none` → non-zero exit listing it.
- Report text is derived from observed evidence (snapshot id from the provider response).
- Demo/example: not applicable — state in completion notes.
