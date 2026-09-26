---
id: INFRA-079
type: bug
severity: high
title: A failed platform install leaves a target the supported destroy cannot unwind (it refuses the create it needs to reach the platform)
source: GCP Attempt 8 (2026-09-25) — the destroy reported the degradation itself
---

**Depends on:** None.

**Finding:** `internal/pipeline/audits/findings/FND-0058-destroy-skips-the-platform-teardown-after-a-failed-install.md`.

**Related:** DEC-045 (destroy never constructs), INV-DESTROY-1 (the failed-`PlatformInstalling`
case), `docs/qualification/2026-09-25-gcp-attempt8.md`.

## Problem

After `sol cloud apply` fails while installing the platform, `sol cloud destroy` cannot tear the
platform down. Uninstalling the Helm releases needs the bootstrap authority, opening the window
is a *create* (`kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]`), and the
destroy's own phase scope refuses creates. The destroy therefore reports a **degraded**
preparation and completes with the platform Terraform state still holding 11 resources that no
longer exist in the provider.

Both policies are individually right; together they are unsatisfiable for this target state.

## Decision taken (2026-09-25) — recorded in `DEC-048`

**Candidate 1, clarified.** Destruction may construct authority, and only authority. The
investigation established that this semantic already existed: REFAC-094 recorded it and
`reconciliation_policy` implements it, bracketed by `with_elevated_access`. Attempt 8 did not expose
a missing capability — it exposed a **matcher defect**. The GCP declaration named the authority
resource with `Exact`, which compares strings, while the mechanism is `count`-indexed and Terraform's
plan address is `...[0]`, so the rule that *permits* the authority create could never match the plan
that acquires it.

| Candidate | Disposition |
|---|---|
| 1 — the mechanism is destruction machinery | **Adopted**, and implemented as an explicit instance-aware matcher (`Sol_cli_terraform_plan.Resource`) plus the GCP declaration change. The investigation's considered phase split (`Acquire`/`Reconcile`/`Release`) was rejected: it adds a bracketing failure sequence for no safety the authority rule does not already provide. |
| 2 — reconcile the platform state as gone | **Separate decision**, filed as `INFRA-082`. It addresses state that is *already* stale; it is neither the cause nor a fix for it, and bundling it would have hidden the fault. |
| 3 — an explicit recovery flag or subcommand | **Rejected.** The supported path already means to do this automatically; a flag would leave the default broken for exactly the half-built target it exists for, and it puts a GCP-shaped switch on the user surface that AWS never needs. |

The same investigation found an adjacent defect of the same class (declared addresses compared as
strings where eligibility and reporting are decided): `FND-0059` / `INFRA-081`. The
no-authority-mechanism declaration gap — a provider cannot say "no mechanism" — is `INFRA-083`; it
was deliberately left unimplemented, because the only two registered providers have a mechanism and
the change would add an untested branch to the bracket FND-0047 hardened.

This ticket was later corrected by `INFRA-083`: an earlier revision of it referred to that gap as
"`INFRA-080`'s sibling item", which was not a real reference. `INFRA-080` is the harness verdict
refinements ticket and does not cover it.

## What landed

- `Sol_cli_terraform_plan.matcher` gained `Resource of string` — *this resource, any instance* — with
  its matching rule stated and tested in both directions (matches `x`, `x[0]`, `x[37]`,
  `x["key"]`; does not match `x_suffix`, `x.extra`, `module.other.x`, a sibling resource, or a
  sibling of the same type).
- The GCP capability declares its authority mechanism with `Resource`, so the create the policy
  permits is expressible; AWS is unchanged (its `Type` matcher is already instance-insensitive) and
  the generic lifecycle gained no provider branch.
- The unit fixture that could not detect this (it used the declaration's own index-less string as the
  plan address) now uses the addresses Terraform emits, and the offline suite's authority fixture
  does too — it had the same defect.
- The offline suite now asserts the destroy's phase order end to end (acquire → platform teardown →
  release → substrate destroy) and that no refusal or degradation occurred on that path.

## Acceptance criteria

- **Met, offline:** the authority create is permitted for an instance-qualified address while every
  unrelated `CREATE`/`REPLACE` stays refused (unit fixtures + the offline scenario, both
  mutation-controlled: making the matcher instance-blind fails the unit suite *and* the offline
  scenario; broadening it to the sibling type fails the precision test; permitting a generic create
  in the reconciliation fails the negative controls).
- **Met, offline:** the offline Attempt-8 shape reaches the acquisition apply, the platform teardown,
  the release and the substrate destroy in order, and the `PLAN_CREATES_MISSING_CLUSTER` scenario
  still refuses unchanged.
- **Awaiting live evidence (hence `FIXED_UNQUALIFIED`):** a real target left in failed
  `PlatformInstalling` is destroyed by `sol cloud destroy` alone, with both root states empty
  afterwards. The preserved Attempt 8 state cannot demonstrate it — its substrate is already gone;
  that state is `INFRA-082`'s subject and was left untouched.

## Completion notes (2026-09-25)

Landed with the matcher fix, `DEC-048`, `FND-0059`/`INFRA-081` and `INFRA-082`. Demo/example: not
applicable (cloud lifecycle internals). Language parity (DEC-022): no application-facing impact. The
preserved Attempt 8 Terraform state, worktree and target were not modified, and no cloud resource was
touched.
