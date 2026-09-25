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

## Completion notes (2026-09-25)

**Problem.** The reader assumed one layout: it required the block header to end in `{` on the same
line, and compared a stripped body line to exactly `sensitive=true`. A valid root laid out
differently — a trailing comment, a one-line block, tabs — was answered "declares no secrets", which
is indistinguishable from a root that declares none.

**Root cause.** The parser was written to the shape this repository's own roots happen to have, and
that assumption was recorded nowhere executable.

**What the layouts actually are (checked against Terraform 1.9.8, not assumed).**
`variable "x" { sensitive = true }` on one line is **valid** and `terraform fmt` leaves it alone;
`sensitive = true # comment` is fmt-clean; and a `{` on the line *after* the header is **invalid**
HCL ("Invalid block definition"), so no root can contain one. The reader therefore handles the first
two and does not pretend to accept the third.

**Change** (`cli/sol/lib/sol_cli_sensitive_vars.ml`). The reader now strips an unquoted `#`/`//`
comment (quote-aware, so the existing "a brace inside a string" fixture still holds), tolerates any
whitespace, recognises a one-line block body, and — the important half — **fails closed** when it
meets a `sensitive` assignment whose value it cannot evaluate (`sensitive = var.flag`), naming the
file and line, instead of skipping it. `declared_in` returns a result so the failure reaches the
command edge, which already exits 1. An unreadable root still fails closed.

**Why no `terraform fmt -check` CI step.** The ticket asked for the formatting assumption to be
enforced if correctness depended on it. It no longer does: with the comment/single-line handling and
the fail-closed path, the reader's answer no longer depends on `terraform fmt` layout, and CI has no
Terraform toolchain (a guard that skipped without it would be the "coverage that cannot fail" this
repository already warns about). Removing the dependence is smaller and stronger than enforcing it.

**Executable evidence.** `cli/sol/test/test_sensitive_vars.ml` fixtures now cover `sensitive = true`,
`sensitive=true`, `sensitive = true # comment`, a tab-indented assignment, a one-line block, a
`sensitive = false`, the nested `validation` block whose `error_message` contains `}`, and a
resource-level `sensitive = true` that is not a variable declaration; the expected set is exactly
`[api_token; commented_secret; db_password; inline_secret; spaced_secret]`. Two cases assert the
fail-closed path returns an error naming `vars.tf` / `vars.tf:3`. The real AWS and GCP roots remain
positive controls (`declared ~root` finds `db_password` sensitive in both), and "an unreadable root
fails closed" still holds. `dune test cli/sol/test/` passes (9 sensitive_vars cases).

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-006.md`.

- Demo/example: not applicable (cloud lifecycle internals / CI guard).
- Language parity (DEC-022): no application-facing impact.
