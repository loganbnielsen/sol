---
id: VERIF-011
type: bug
severity: medium
title: A guard mutation self-test runs nowhere, and two guards run only mutated
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: 'rg -q test_resource_identity_check .github/workflows/ci.yml && rg -q test_resource_identity_check internal/ci/run_fast_checks.sh'
---

A guard mutation self-test runs nowhere, and two guards run only mutated

**Depends on:** VERIF-005.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a` by scanning every workflow
`run:` command, `internal/ci/run_fast_checks.sh` and the Dune files for each guard's basename:

- `internal/ci/test_resource_identity_check.py` is referenced by nothing, while its guard
  `internal/ci/check_resource_identity.py` runs in both `.github/workflows/ci.yml:665-667` and
  `internal/ci/run_fast_checks.sh:72`. The guard's mutation evidence is dead code.
- `internal/ci/check_cluster_access_identity.py` and `internal/ci/check_gcp_provisioner_role.py` are
  invoked only from their own mutation scripts (`test_cluster_access_identity.sh:5`,
  `test_gcp_provisioner_role.sh:5`), on a temporary copy. Those scripts do run the real file as a
  control, so drift is caught indirectly; what is absent is the guard's own verdict on the real tree
  with its own diagnostic.
- Deliberate and verified, not findings: `check_authority.sh`, `check_readiness_invocations.sh`,
  `check_public_cloud_lifecycle.sh`, `check_publisher_deployer_boundary.sh` and
  `test_cloud_lifecycle_offline.sh` are invoked only from a test or from a Dune rule, which is where
  each of them belongs.

## Problem

Mutation coverage is the evidence that a guard can fail, and one guard's evidence never runs.
Separately, a guard that only ever executes on a mutated copy cannot report drift in the tree it
ships with. Both are wiring defects rather than design defects, and both are exactly what
VERIF-005's class convention makes impossible in future: a guard's mutation self-test becomes part
of the class, so it cannot be forgotten when the guard is added.

## Desired invariant

Every guard that runs in a verification class has its mutation self-test running in the same class,
and every guard's verdict is produced on the real tree as well as on its mutants.

## Remediation

Wire `test_resource_identity_check.py` into the same class as its guard (`ci.yml` and
`run_fast_checks.sh` until VERIF-005 replaces both). Add a step that runs
`check_cluster_access_identity.py` and `check_gcp_provisioner_role.py` against the real tree, next
to their existing mutation scripts. Then let VERIF-005's convention carry the invariant so this
cannot recur.

## Acceptance criteria

- `test_resource_identity_check.py` runs in CI and in the pre-push gate, and its output names the
  guard it covers.
- `check_cluster_access_identity.py` and `check_gcp_provisioner_role.py` each run against the
  repository tree in CI, not only against a mutated copy.
- A repository-wide check exists that every `internal/ci/check_*` guard and every `test_*`
  mutation self-test is invoked by some class — or VERIF-005's convention makes it structural and
  this is recorded as such.
- Demo/example: not applicable — CI tooling only. Language parity: no application-facing contract
  changes; state that in one line.

## Completion notes (2026-10-02)

**Premise re-verified** against `origin/main @ 408bc4c4`: `internal/ci/check_*` and `test_*` are
`static` class members discovered by `internal/tooling/scripts/verify.sh`, so each runs in CI and in
the pre-push gate unless it is deliberately caller-invoked.

**Made structural by VERIF-005.** Membership is the filename inside the class directory:

- `internal/ci/test_resource_identity_check.py` now runs in both gates, and its output names the
  guard it covers.
- `internal/ci/check_cluster_access_identity.py` and `internal/ci/check_gcp_provisioner_role.py`
  run against the repository tree (their default roots are repo-relative), not only on a mutated
  copy.
- A guard or mutation self-test cannot be unwired again: a new `check_*`/`test_*` file is a class
  member by construction, and an empty class is an error. The four caller-invoked members
  (`check_ticket_move.sh`, `check_ticket_transitions.sh`, `check_readiness_invocations.sh`,
  `test_cloud_lifecycle_offline.sh`) live in `context/` and are invoked by their caller — a ci.yml
  step, the pre-commit hook or a Dune rule — which the ticket already recorded as correct.

**Evidence.**

```
$ bash -c 'source internal/tooling/scripts/verify.sh; discover "$root/internal/ci"; \
           printf "%s\n" "${members[@]}"' | rg 'cluster_access_identity|gcp_provisioner_role|resource_identity'
.../internal/ci/check_cluster_access_identity.py
.../internal/ci/check_gcp_provisioner_role.py
.../internal/ci/check_resource_identity.py
.../internal/ci/test_cluster_access_identity.sh
.../internal/ci/test_gcp_provisioner_role.sh
.../internal/ci/test_resource_identity_check.py
$ python3 internal/ci/test_resource_identity_check.py   # names the guard it covers
```

**Demo/example:** not applicable — CI tooling only. **Language parity (DEC-022):** no
application-facing contract changes.
