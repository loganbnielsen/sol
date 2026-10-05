---
id: INFRA-106
type: infra
severity: high
source: alpha.7 GCP attempt 5, 2026-10-04
title: Keep qualification teardown active when its stdout consumer disappears
---

**Depends on:** None.

## Premise verified

During GCP attempt 5, killing the stdout reader caused a SIGPIPE in the harness after platform failure and before teardown. GKE and Cloud SQL remained running until manual recovery. Both provider harnesses print progress through a pipe and own billable resources.

## Remediation

Make progress logging independent of the caller's stdout lifetime, and ensure process termination paths run teardown and independent absence verification. Avoid terminating an in-flight Terraform provider plugin as part of signal handling.

## Acceptance criteria

- Close the harness stdout reader during a fixture run; the harness still tears down and records its verdict.
- Exercise SIGPIPE and SIGTERM without silently abandoning billable resources or corrupting Terraform state.
- Example impact: none; qualification machinery only. Language-parity impact: none.
