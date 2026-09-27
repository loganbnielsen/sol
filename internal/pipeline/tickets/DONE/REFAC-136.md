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

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `62ab9b9a`):** no `sol_cli_gcloud.ml`; `Sol_cli_gcp_destruction.gcp_absence_message` and `Sol_cli_cluster_substrate.absent_wording` held two different gcloud word lists, and `aws_error_code` was private to `sol_cli_aws_destruction.ml`.

- **`Sol_cli_gcloud`** (`classify : ?project -> Sol_cli_process.error -> Not_found | Other`, `says_not_found`, `mentioned_projects`): one word list, and finding C's project-subject refinement as the optional `~project`. The peering probe classifies the process error; the cluster-mode read uses `says_not_found` on the text it already holds (stderr and stdout).
- **A fail-open found by merging the lists.** The cluster-substrate list contained "could not fetch resource", which is gcloud's prefix for *every* API failure. A 403 (`Could not fetch resource: - Required 'container.clusters.get' permission …`) therefore read as an **absent cluster, i.e. a fresh target**, which is the misreading that check's own comment says it exists to prevent. Confirmed on `origin/main` in a scratch worktree: `Sol_cli_cluster_substrate.absent_wording <that 403>` → `true`. The unified list drops the phrase; the real 404 under that prefix says "was not found" and is still matched (test).
- **`Sol_cli_aws.error_code`**, moved from `sol_cli_aws_destruction` so any aws call site can branch on the code; both snapshot probes use it.
- Both are views: callers report the tool's own text (REFAC-125).
- **Acceptance:** `rg -n 'Sol_cli_string.contains' cli/lib` lists the kubectl and gcloud classifiers and `sol_cli_sensitive_vars` (which reads HCL source, not a tool's error) -- no gcloud/aws message matching elsewhere.
- **Tests:** `cli/test/test_cloud_cli.ml`: gcloud's `clusters describe` 404, compute's was-not-found under the generic prefix, the 403 under that prefix (negative), a not-found about another project (negative), timeout and missing-gcloud (negative); aws codes including a dotted one, and no code for a client-side failure. `test_cluster_substrate` gains the verbatim 403 as a negative case; `test_destroy_verification`'s subject tests run against `Sol_cli_gcloud`. `dune test cli/ --force`: 0 failures; format clean.
- **Demo/example:** not applicable (internal). **Language parity:** no impact.
