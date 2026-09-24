---
id: INFRA-069
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

Verify destroy against the IDs and regions recorded in state, not guessed names in a defaulted region

**Depends on:** REFAC-091.

**Finding:** FND-0045 (`internal/pipeline/audits/findings/`).

**Sequencing:** this is step 5 of the HARDEN-004 order in `internal/pipeline/audits/HARDEN-004-handoff.md` ("The order now"). Coordinate with the HARDEN-004 owner; land it as that step, not in parallel.

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`verify_gcp_destroy`/`verify_aws_destroy` describe `cluster_name ^ "-postgres"` etc. in a region that defaults to `us-central1`, read via a line-based tfvars parser that swallows errors; `gcp_absence_message` accepts any "not found" (including a wrong project). A wrong guess reads as "absent".

## Remediation

Capture a typed state inventory at the start of destroy; verify absence of those IDs in those regions/project; add `terraform state list` = empty as a post-condition; keep name-based describes only as an orphan sweep; take `var_file_value` out of decision paths; tighten absence matching to resource-not-found.

## Acceptance criteria

- A test with a wrong region/project in vars fails verification loudly rather than reporting absent.
- Verification inputs come from the pre-destroy inventory (test with a fixture).
- Demo/example: not applicable — state in completion notes.
