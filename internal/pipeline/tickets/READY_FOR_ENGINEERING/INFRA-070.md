---
id: INFRA-070
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

GCP `with_cluster_access` must honour `on_error` so a credential failure removes bootstrap access

**Depends on:** None.

**Finding:** FND-0047 (`internal/pipeline/audits/findings/`).

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`with_cluster_access` does `ignore on_error` on GCP, and `gcp_provisioner_kubeconfig` exits via `lifecycle_error` when `get-credentials` fails; the install (`:2415`) and destroy (`:2712`) callers pass `cleanup_bootstrap_access`, which therefore never runs — the provisioner stays elevated.

## Remediation

Call `on_error` before exiting on GCP (or return a result and let the caller clean up). Longer term, port the lifecycle to the `cmd_rollback.ml` result-returning shape (report: Recommended order, 3).

## Acceptance criteria

- Offline test (stub gcloud failing get-credentials) observes the bootstrap-access-remove apply being invoked before exit, on both install and destroy.
- Demo/example: not applicable — state in completion notes.
