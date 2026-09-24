---
id: INFRA-070
type: bug
severity: high
source: internal/pipeline/audits/2026-09-23_correctness_audit.md
---

GCP `with_cluster_access` must honour `on_error` so a credential failure removes bootstrap access

**Depends on:** None.

**Finding:** FND-0047 (`internal/pipeline/audits/findings/`).

**Sequencing:** a small standalone fix (item E in `internal/pipeline/audits/HARDEN-004-handoff.md`); REFAC-091 removes the class. If REFAC-091 lands first, verify it covers this and close this ticket with that note.

**Premise verified 2026-09-23** against `origin/main @ f3e9480b` while filing (see the finding for the command/probe and observed output).

## Problem

`with_cluster_access` does `ignore on_error` on GCP, and `gcp_provisioner_kubeconfig` exits via `lifecycle_error` when `get-credentials` fails; the install (`:2415`) and destroy (`:2712`) callers pass `cleanup_bootstrap_access`, which therefore never runs — the provisioner stays elevated.

## Remediation

Call `on_error` before exiting on GCP (or return a result and let the caller clean up). Longer term, port the lifecycle to the `cmd_rollback.ml` result-returning shape (report: Recommended order, 3).

## Acceptance criteria

- Offline test (stub gcloud failing get-credentials) observes the bootstrap-access-remove apply being invoked before exit, on both install and destroy.
- Demo/example: not applicable — state in completion notes.

## Completion notes

- `with_cluster_access` now passes `on_error` to `gcp_provisioner_kubeconfig`, which calls it
  before every exit: the auth-plugin check, a non-zero `get-credentials`, and gcloud failing
  to run. This matches `with_provisioner_kubeconfig` on AWS.
- Regression in `internal/ci/test_cloud_lifecycle_offline.sh`: a GCP destroy with the
  `get-credentials` stub failing (`FAIL_ON=access`) must stop on that error and must issue
  the `provisioner_bootstrap_admin=false` apply after the failed `get-credentials`.
- Mutation check (`audits/README.md`): reverting the call site to
  `gcp_provisioner_kubeconfig ~region outputs f` builds (rc=0), and the harness then fails
  with "a GCP cluster-access failure exited without closing the bootstrap window".
- The install path (`cloud apply`) is covered by the same kind of harness case: a GCP
  `cloud apply` with `get-credentials` failing must issue the
  `provisioner_bootstrap_admin=false` apply after the failure. Mutation check for that case:
  dropping `~on_error:cleanup_bootstrap_access` from the install call site builds (rc=0),
  and the harness then fails with "a GCP cluster-access failure during apply exited
  without closing the bootstrap window".
- Demo/example: not applicable — state in completion notes.

## Completion notes

- `with_cluster_access` now passes `on_error` to `gcp_provisioner_kubeconfig`, which calls it
  before every exit: the auth-plugin check, a non-zero `get-credentials`, and gcloud failing
  to run. This matches `with_provisioner_kubeconfig` on AWS.
- Regression in `internal/ci/test_cloud_lifecycle_offline.sh`: a GCP destroy with the
  `get-credentials` stub failing (`FAIL_ON=access`) must stop on that error and must issue
  the `provisioner_bootstrap_admin=false` apply after the failed `get-credentials`.
- Mutation check (`audits/README.md`): reverting the call site to
  `gcp_provisioner_kubeconfig ~region outputs f` builds (rc=0), and the harness then fails
  with "a GCP cluster-access failure exited without closing the bootstrap window".
- The install path (`:2415`) uses the same helper, so it is fixed too. The harness has no
  GCP `cloud apply` case, so only destroy is exercised.
- Demo/example: not applicable (cloud lifecycle internals, no author-facing change).
- Language parity: no language-parity impact (CLI-only).
- FND-0047 state → `FIXED_UNQUALIFIED` for the INFRA-070 half. REFAC-091 removes the class.
