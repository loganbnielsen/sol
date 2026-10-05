---
id: INFRA-117
type: infra
severity: medium
source: AWS/GCP live qualification boundary audit 2026-10-05
title: Keep local qualification tests focused on runner safety and evidence integrity
---

**Depends on:** INFRA-115, INFRA-118.

## Premise verified

`internal/qualification/gcp/test-live-qual.sh` is 1,404 lines and builds fake `gcloud`, `kubectl`,
Terraform, Docker, curl and Sol commands. `internal/qualification/aws/test-live-row.sh` is 600
lines and similarly fakes Sol, AWS, Kubernetes, Docker and the qualification transport. Together
the two provider-specific end-to-end tests are 2,004 lines against 2,201 lines in the two active
live runner scripts. They model successful and failing provider/product flows in addition to
checking runner safeguards. CI runs both suites for every non-docs change.

The tests have caught real harness defects, so deleting all local tests would remove valuable
protection. The live matrices already require actual provider/Kubernetes observations for
behavioral claims, while Sol's product behavior has its own offline/unit/integration CI coverage.
The GCP observer and result-matrix verifier also have separable, deterministic evidence-parsing
contracts that can be tested with captured fixtures.

## Remediation

Replace the broad fake-provider end-to-end suites with a small runner-safety suite. Retain local
checks for behaviors whose failure could overwrite another attempt, mutate the wrong target,
lose cost-bearing resources, or manufacture false qualification evidence:

- an occupied state key or evidence directory belonging to another attempt is refused before
  mutation;
- release identity and attempt identity bind to the exact evidence bundle;
- `verify` is read-only, and the only target teardown path is the supported Sol destroy command;
- an interrupted process or closed stdout consumer does not silently bypass required cleanup;
- independent inventory reads distinguish `PRESENT`, `ABSENT` and `UNKNOWN`, and incomplete or
  mismatched evidence cannot pass a row;
- evidence required by the stages actually reached is retained before teardown.

Keep deterministic tests for the GCP observer's kubeconfig selection, bounded reads and
failure reporting, and for matrix/result-bundle validation. Use sanitized captured provider
responses for any retained response parsing. Remove fake-provider scenarios that claim to prove
Sol's cloud apply, Kubernetes/chart convergence, application deployment, database/broker
behavior or provider lifecycle; those claims stay owned by product CI and the real AWS/GCP
qualification matrices. Do not reduce, skip or relabel any live matrix row to make the local test
suite smaller.

Coordinate CI selection with INFRA-115: retain fast universal invariants, and run the focused
runner tests when qualification scripts, evidence formats, or their safety guards change. A local
mock result is never evidence of live conformance.

## Acceptance criteria

- The active AWS/GCP fake end-to-end suites no longer simulate provider/product convergence or
  application behavior.
- The remaining focused suite covers every runner-safety behavior listed above, with negative
  cases proving refusal, cleanup, tri-state inventory and evidence rejection.
- GCP observer and matrix verifier tests remain independent of live credentials and retain their
  failure-injection cases using fixtures rather than a simulated GCP implementation.
- The CI trigger for these tests follows INFRA-115 and is visible; product and provider behavior
  remains covered by independent CI and the unchanged live qualification matrices.
- `internal/qualification/ALPHA_CAMPAIGN.md`, provider matrices and evidence classes continue to
  mark deployed behavior `NOT RUN` until real AWS/GCP evidence exists.
- Example impact: none; qualification tooling. Language-parity impact: none.
