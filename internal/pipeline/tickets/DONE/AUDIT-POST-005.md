---
id: AUDIT-POST-005
type: audit-finding
severity: medium
source: internal/pipeline/audits/2026-09-25_cloud_lifecycle_post_audit.md
---

The destroy-completeness guard misses `deletion_policy = "PREVENT"` and variable-driven forms

**Depends on:** None.

**Related:** DEC-045, REFAC-093, ADR 0004, INFRA-077

**Plan:** `internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`, § S2
("Abandonment inventory and guard").

## Problem

`internal/ci/check_destroy_completeness.sh` guards two distinct semantics, and each has a hole:

- **Rule 1** rejects `prevent_destroy` (`:66-68`) — the class that makes a target undeletable.
- **Rule 4** rejects an unannotated relinquishment (`deletion_policy = "ABANDON"`,
  `skip_destroy = true`, `skip_delete = true`, `:118-127`) unless a `# residue:` comment names who
  handles what is left.

Neither recognises `deletion_policy = "PREVENT"`, the Google provider's equivalent of
`prevent_destroy`, and both `skip_destroy` / `skip_delete` require the literal `= true`, so a
variable-driven form (`skip_destroy = var.foo`) also passes.

**Reproduced (2026-09-25), with a positive control:** a copy of the real GCP root passes the guard
(`3 terraform file(s) in 1 target root(s); …`). The same copy with an otherwise well-formed bucket
(soft delete routed through `var.gcs_soft_delete_retention_seconds`) carrying
`deletion_policy = "PREVENT"` also passes with rc 0, while the same mutation with a literal
soft-delete retention is rejected — proving the guard runs and can fire on that file.

## Root cause

Rule 1 was written to find `prevent_destroy` after the ADR-0004 audit; rule 4 was written for
DEC-045's *relinquishment* class. `deletion_policy = "PREVENT"` is a third spelling of the first
class that arrived with the GCP root, and rule 4's `= true` requirement was written for the common
case rather than the syntactic class.

## Impact

A future Terraform change could make a target undeletable — or relinquish a deletion — without the
guard firing. The consequence of the PREVENT hole is the one ADR 0004 exists to prevent: an operator
who cannot tear a target down through the normal lifecycle, discovered at the worst moment. No root
uses `PREVENT` today, so this is latent.

## Remediation

Strengthen the existing guard; do not add a new one and do not parse general HCL.

- Reject `deletion_policy = "PREVENT"` (and any `deletion_policy` value other than `"DELETE"`) as an
  undeletable-target hazard, in the same class as `prevent_destroy`.
- Treat `deletion_policy = "ABANDON"`, `skip_destroy`, `skip_delete` as the relinquishment class
  regardless of the right-hand side (`= true`, `= var.foo`), so a variable-driven form needs the
  `# residue:` annotation too.
- Keep the two classes distinct: PREVENT ⇒ reject; ABANDON/skip ⇒ allowed only with explicit residue
  ownership.
- Fail closed when the guard cannot classify a relevant deletion semantic: if a `deletion_policy`,
  `skip_destroy` or `skip_delete` assignment appears whose value the guard cannot classify, report it
  rather than passing.
- Preserve the existing rules and their self-test behaviour for ECR/force-delete, object-storage
  force-destroy, routed deletion guards and GCS soft delete.

## Acceptance criteria

`internal/ci/test_destroy_completeness_check.sh` demonstrates, as mutation/positive controls:

- adding `deletion_policy = "PREVENT"` fails;
- adding `prevent_destroy` fails;
- adding an unaccounted `ABANDON` fails;
- adding an unaccounted `skip_destroy` / `skip_delete` fails (in both `= true` and `= var.x` forms);
- the existing annotated relinquishment passes;
- the current AWS and GCP roots pass;
- an unclassifiable `deletion_policy` value is reported (fail closed).

## Completion notes (2026-09-25)

**Problem.** The guard rejected `prevent_destroy` (rule 1) and `deletion_policy = "ABANDON"` /
`skip_destroy = true` / `skip_delete = true` (rule 4), but not `deletion_policy = "PREVENT"` — the
Google provider's spelling of `prevent_destroy`, which makes a target permanently undeletable. Rule 4
also required the literal `= true`, so a variable-driven `skip_destroy` / `skip_delete` passed as
"not relinquishing".

**Reproduced (2026-09-25), with a positive control.** A copy of the real GCP root passes the guard.
The same copy with `deletion_policy = "PREVENT"` on an otherwise well-formed bucket (soft delete
routed through `var.gcs_soft_delete_retention_seconds`) also passed with rc 0, while the same
mutation with a literal soft-delete retention was rejected — proving the guard ran and could fail on
that file.

**Root cause.** Rule 1 was written to find `prevent_destroy`; rule 4 was written for DEC-045's
relinquishment class. `PREVENT` is a third spelling of the first class, and rule 4's `= true` was
written for the common form rather than for the syntactic class.

**Change** (one block, `internal/ci/check_destroy_completeness.sh`, rule 4). Every `deletion_policy`
/ `skip_destroy` / `skip_delete` assignment in a target root is now classified explicitly:

- `deletion_policy = "ABANDON"` / `skip_destroy = true` / `skip_delete = true` → relinquishment, and
  still requires the `# residue:` owner (unchanged);
- `deletion_policy = "PREVENT"` → rejected like rule 1's `prevent_destroy`;
- `deletion_policy = "DELETE"` / `skip_destroy = false` / `skip_delete = false` → the classifying
  values, accepted;
- anything else (a variable, an unrecognised literal) → **reported**, so a deletion semantic the
  guard cannot read is never a pass.

No new guard, no HCL parser, and the two classes stay distinct: PREVENT rejects, ABANDON/skip is
allowed only with an owner.

**Executable evidence.** `internal/ci/test_destroy_completeness_check.sh` gained, as
mutation/positive controls: `deletion_policy = "PREVENT"` rejected; `skip_destroy = var.x` rejected;
`deletion_policy = var.policy` rejected; an unannotated `skip_delete = true` rejected; and — so the
guard is not merely rejecting every mention — `deletion_policy = "DELETE"` and `skip_delete = false`
accepted. The pre-existing controls (ECR without `force_delete`, `prevent_destroy`, GCP
`force_destroy = false`, unannotated `ABANDON`, undeclared/literal GCS soft delete) still pass, the
annotated `ABANDON` still passes, and the real AWS and GCP roots pass:
`check_destroy_completeness: 6 terraform file(s) in 2 target root(s); …`.

**Canonical merge SHA.** The squash commit that moved this ticket to `DONE/`; recover it with
`git log --oneline -1 -- internal/pipeline/tickets/DONE/AUDIT-POST-005.md`.

- Demo/example: not applicable (CI guard).
- Language parity (DEC-022): no application-facing impact.
