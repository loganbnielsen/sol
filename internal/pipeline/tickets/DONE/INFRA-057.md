---
id: INFRA-057
type: feature
severity: high
title: Make the operator identity real, and stop presenting a failed read as absent evidence
source: audit finding FND-0017 — DEC-038
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0017-no-identity-can-follow-sols-own-diagnostic-instruction.md`
**Decision:** `DEC-038`

Two changes, delivered separately because they are independent: the capability, and
the visibility of its absence.

## Part A — the invisible degradation (do this first, it needs no grants)

`fetch_namespace_events` (`sol_cli_rollout_diagnosis.ml`) turns *every* failure into
`[]`, so a denied read is indistinguishable from a quiet namespace and `sol status`
presents an explanation it never obtained.

Per DEC-038 §5 the status contract stays **explicit partial evidence** — the rest of
the diagnosis remains useful — but the two states must be distinguishable:

| State | Must read as |
|---|---|
| read succeeded, no events | zero events |
| read failed (authorization, transport) | **unavailable**, naming `events` and why |

Acceptance:

1. A test using a kubectl stub that fails `get events` asserts the rendered
   diagnosis names events as unavailable, and does **not** render an empty event
   list.
2. A test with a successful read returning no items asserts zero events, and is
   distinguishable from (1).
3. No other read in the diagnostic path collapses a failure into an absence
   silently — audit `fetch_pod_statuses` and the cronjob read at the same time.

## Part B — the operator identity end to end

Per DEC-038 §§1–4:

1. `operator_role_arn` becomes a real variable of the AWS root (today it exists only
   in an output description), and an EKS access entry is created for it with
   `kubernetes_groups = ["sol:operators"]` and **no policy associations** — the same
   shape as the deploy and provisioner entries.
2. A ClusterRole (`sol-operator-diagnostics`) grants exactly the table in DEC-038 §3
   — `pods`, `pods/log`, `services`, `events` (core); `deployments` (apps);
   `cronjobs` (batch); and a cluster-scoped `namespaces` `get`/`list` role. `get`
   and `list` only, no wildcards, no mutating verb, and no `secrets`,
   `pods/portforward` or `pods/exec`.
3. The namespaced resources are bound **per application namespace at runtime**,
   beside the deploy binding in `Sol_cli_substrate.ensure`, because those namespaces
   are created dynamically and a ClusterRoleBinding would read into platform
   namespaces.
4. An offline guard (`internal/ci/check_operator_diagnostics.sh`) asserts all of the
   above **and cross-checks the code**: every resource the read-only diagnostic path
   reads must appear in the operator's grant. A guard test
   (`internal/ci/test_operator_diagnostics_check.sh`) breaks a copy of the role in
   each way and asserts the guard fails — so the guard is demonstrably falsifiable,
   not decorative.
5. The operator identity is documented where the other three are
   (`docs/deployment/production-bootstrap.md`), including what it deliberately
   cannot do.

Acceptance for the capability:

6. Live: `sol status` run through the operator identity against the flapping
   `notify-worker` explains the workload — pod state **and** events.
7. Live: the same identity is refused a mutation (`kubectl auth can-i` negative on
   create/update/patch/delete, and on `pods/portforward`).

## Out of scope

Giving the deploy identity `events` or `portforward`, and any cluster-wide binding
of the namespaced diagnostic role.

## Completion — verified close-out (2026-09-22)

Both parts landed in their own commits and **neither moved the ticket**, so it kept
reporting as actionable:

- **Part A** — #397 (`4385100c`). `fetch_namespace_events`
  (`sol_cli_rollout_diagnosis.ml:452`) returns
  `Events … | Events_unavailable reason` instead of collapsing every failure into
  `[]`, and the sibling reads report through `kubectl_read_failure` (DEC-038 §7).
  Coverage: `test_unavailable_events_are_named_not_empty` (AC1, including the
  denied read), the successful-but-empty case (AC2, asserted to be
  distinguishable), and `test_format_cronjob_diagnosis_unavailable_is_undetermined`
  (AC3's cronjob read).
- **Part B** — #398 (`b0d26e74`) with #401 (`5e07d8b9`). The operator identity
  exists end to end, and `internal/ci/check_operator_diagnostics.sh` plus its
  falsifiability test (`test_operator_diagnostics_check.sh`) are both present and
  wired into CI, which is Part B's ACs 1–5 as written.

**Outstanding, and live:** AC 6 and 7 of the capability — `sol status` through the
operator identity against the flapping `notify-worker`, and the negative
`auth can-i` checks. Those need a real cluster, so `FND-0017` stays
`FIXED_UNQUALIFIED` and the live half belongs to the next qualification run.
