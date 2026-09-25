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

## Decision Required

Which of these is the intended semantics? Each implies a different fix, and the choice is a
design decision, not an implementation detail:

1. **The window's binding is destruction machinery.** A destroy may create *only* the binding it
   is about to remove, declared in its own preparation, and the plan-assert still refuses any
   other create. Fix: a scope refinement in the destroy's reconciliation.
2. **The platform root is subordinate to the cloud root.** Destroying the cluster is understood
   to have removed the platform, so the platform state is reconciled as *absent* rather than
   destroyed. Fix: a reconciliation rule (and a state-truth question: how does Sol record
   "gone" without raw state surgery?).
3. **An explicit recovery path.** A flag or subcommand that reopens the window for destruction,
   with the same confirmation semantics as other destructive acts, and a documented operator
   step. Fix: a new surface plus documentation.

## Remediation

To be written once the decision above is made. Whatever is chosen must not weaken DEC-045: no
provider resource may be created outside the destroy's own declared preparation, and the
plan-assert must still refuse an undeclared create.

## Acceptance criteria

- A target left in `failed PlatformInstalling` is destroyed by `sol cloud destroy` alone — no
  manual provider deletion, no raw state surgery, no `terraform import` — and afterwards both
  root states are empty and agree with the provider, queried class by class.
- `internal/ci/test_cloud_lifecycle_offline.sh` covers the degraded case with a **positive
  control**: a destroy whose plan asks to create the window binding, and the resulting
  platform-state reconciliation.
- The destroy reports the same evidence it reports today (the degradation line stays honest if
  it still occurs in any path).
- Completion notes name the chosen option and why the other two were rejected.
