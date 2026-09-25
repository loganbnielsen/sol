---
id: AUDIT-POST-006
type: audit-finding
severity: low
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

The sensitive-variable parser only recognises terraform fmt layout

**Depends on:** None.

**Related:** SEC-010, SEC-008

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S1.b.

## Problem

`Sol_cli_sensitive_vars` refuses a root-declared `sensitive = true` variable in the Terraform argv,
because the run log records the command line. It reads the declaration with a deliberately small text
parser, and that parser only recognises `terraform fmt` layout:

- `variable_name` (`sol_cli_sensitive_vars.ml:10-20`) requires the header line to end in `{` after
  trimming, so a block written as `variable "db_password"\n{` is not seen;
- `is_sensitive_true` (`:23-31`) strips spaces and tabs and compares to exactly `sensitive=true`, so
  `sensitive = true # comment` is not seen.

`declared` (`:57-78`) fails closed only when the root cannot be read at all, so a root that is
parseable but not in fmt layout is silently treated as declaring no secrets. No `terraform fmt`
check runs in CI.

## Root cause

The parser was written to the shape the repository's own roots have, and that assumption was
recorded nowhere executable. The AWS and GCP roots are in fmt layout today, so there is no live leak
— the gap is between what the invariant claims and what the parser verifies.

## Impact

A root (or a later hand-added variable) formatted differently from `terraform fmt` output could put a
secret back into the run log without Sol refusing, which is the regression SEC-010 fixed. Because the
failure is silent, nothing would reveal it until an operator read the run log.

## Remediation

Keep this proportional: do not build an HCL parser. Do both of the small things, since each is
cheap and they cover different halves of the risk.

1. Tolerate the demonstrated harmless formatting variation in the existing parser: recognise a
   variable header whose `{` is on the following line, and a `sensitive` assignment with a trailing
   comment (or other trailing content after the value).
2. Make the assumption executable: add a CI/`runtest` check that the Terraform roots whose layout the
   parser depends on are `terraform fmt -check` clean, so the layout cannot drift silently.

Do not weaken the fail-closed behaviour for an unreadable root.

## Acceptance criteria

`cli/sol/test/test_sensitive_vars.ml` covers at least:

- `sensitive = true`;
- `sensitive=true`;
- `sensitive = true # comment`;
- an open brace on the next line;
- the existing cases (several files, a brace inside a string, a validation block, a root that
  declares nothing sensitive, an unreadable root failing closed);
- the real AWS and GCP roots as positive controls.

If parser correctness depends on formatted Terraform, CI enforces it (a `terraform fmt -check` rule
over the roots, with its own mutation/positive control: an unformatted fixture is rejected).

## Completion notes (required)

- Problem / root cause / change / executable evidence / canonical merge SHA.
- Demo/example: not applicable (cloud lifecycle internals / CI guard) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
