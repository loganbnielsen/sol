---
id: REFAC-136
type: refactor
severity: low
title: One error classifier per cloud CLI -- gcloud's absence wording and aws's error code each live in one adapter
source: pattern audit of the REFAC-104..130 series (2026-09-26); REFAC-125 did this for kubectl only
premise: "test -f cli/lib/cloud/sol_cli_gcloud.ml"
---

**Depends on:** None.

## The problem

REFAC-125's rule is "ask the tool for a structured answer; where it has none, classify in one place per tool, with a test holding the verbatim message". It was applied to kubectl. For the cloud CLIs the classification is duplicated, and the copies disagree:

- gcloud "is it absent?" is decided twice with different word lists: `Sol_cli_gcp_destruction.gcp_absence_message` (`code=404`, `httperror 404`, `not_found`, `not found`, `does not exist`) and `Sol_cli_cluster_substrate.absent_wording` (`not found`, `not_found`, `does not exist`, `was not found`, `could not fetch resource`). A wording one recognises and the other does not makes the same cluster "absent" in one path and "unknown" in the other.
- The aws CLI's `An error occurred (<Code>) when calling …` code is parsed privately in `sol_cli_aws_destruction.ml:17`; other aws call sites (`sol_cli_aws_cluster.ml`) cannot reuse it.

## Remediation

- `Sol_cli_gcloud.classify : Sol_cli_process.error -> reason` (`Not_found | Other`, extended only as call sites need), holding the union of both word lists once, and the project-subject check from `gcp_absence_message` as an explicit, separately-tested refinement.
- `Sol_cli_aws.error_code : Sol_cli_process.error -> string option`, moved from `sol_cli_aws_destruction`, used by every aws call site that branches on a failure.
- Both are views: messages keep the tool's own text (REFAC-125's rule).

## Acceptance criteria

- `rg -n 'Sol_cli_string.contains' cli/lib` lists no gcloud/aws message matching outside those two adapters.
- Tests with each verbatim message the classifiers recognise, plus negative controls (an auth failure, a timeout, "not found" inside unrelated prose where the subject check applies).
- Demo/example: not applicable (internal). Language parity: no impact.
