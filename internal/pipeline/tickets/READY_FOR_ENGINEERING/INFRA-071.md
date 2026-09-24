---
id: INFRA-071
type: bug
severity: medium
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

`gcp_protection_state`: identify guarded resources by address, and treat an empty state as empty

**Depends on:** None.

**Finding:** FND-0048 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

It picks the first resource of each type in `root_module` and maps it onto a fixed address; child modules and second instances are mishandled. No `values` key or a null `deletion_protection` raises `Type_error`, reported as "unexpected `terraform show -json` shape" for a legitimately empty/half-built state.

## Remediation

Build `represented` from real addresses (`terraform state list` or walking root+child modules by `address`); absent `values` = empty state; `deletion_protection` as `bool option`.

## Acceptance criteria

- Fixture tests: empty state → nothing represented (no error); a child-module resource and a second instance are handled by address; null protection does not raise.
- Demo/example: not applicable — state in completion notes.
