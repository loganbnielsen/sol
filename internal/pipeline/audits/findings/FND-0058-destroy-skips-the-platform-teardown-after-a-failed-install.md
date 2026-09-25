# FND-0058 — After a failed platform install, the supported destroy cannot tear the platform down: it needs to *create* the install window and refuses itself

- **Classification:** `VERIFIED_DEFECT` (live: GCP Attempt 8, 2026-09-25 — the destroy
  reported the degradation itself, and the platform state snapshot agrees), against
  DEC-045's destroy-authority contract and `INV-DESTROY-1`'s failed-`PlatformInstalling` case
- **State:** `FIXED_UNQUALIFIED` (fixed 2026-09-25; offline evidence only — see the correction at the end)
- **First identified:** 2026-09-25, GCP Attempt 8 (`docs/qualification/2026-09-25-gcp-attempt8.md`)
- **Provider:** GCP (mechanism is provider-neutral; observed on GCP)
- **Derived ticket:** `INFRA-079`
- **Evidence class:** `BEHAVIORAL`. Observed live; the bundle is
  `/tmp/sol-gcp-qual-8-attempt` (`destroy.log`, `state/platform.tfstate`,
  `inventory-post.tsv`).

## What is established

Attempt 8 failed at the platform install (`platform-prerequisites-apply` FAILED, 416.7 s),
closed the install window on the failure path (`provisioner-bootstrap-access-remove` ok,
12.9 s), and then the harness's own teardown ran the supported path,
`sol cloud destroy qual/gcp/us-central1`. The destroy reported, verbatim:

```
warning: a preparation degraded and destruction continued -- the platform teardown was skipped
because the bootstrap authority it needs could not be obtained (refused before apply:
destroy-reconciliation phase: create on kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]
(kubernetes_cluster_role_binding) is outside this phase's scope)
warning: destruction reached absence with 1 degraded preparation(s)
```

and then:

```
terraform state (disposable root): empty -- Terraform destroyed every resource it manages
```

Read afterwards, read-only, straight from the backend object
(`gs://sol-qualification-tfstate/sol/qual/gcp/us-central1/platform.tfstate/default.tfstate`):
**11 resources still recorded** — 6 `kubernetes_namespace`, 1 `helm_release`, 2
`kubernetes_cluster_role`, 1 `kubernetes_cluster_role_binding`, 1 `kubernetes_role_binding` —
while the cluster those resources described had been destroyed by the cloud root. The cloud
root's state is empty (0 resources, serial 47); the platform root's state is stale at serial 4.

Every billable class is gone (independently queried at 22:37Z), so this is not a cost defect.
It is a **completeness** defect: the target that could not finish installing can no longer be
finished *or* unwound through the supported path, and its state no longer describes reality.

## Why it happens

Tearing the platform down requires the bootstrap authority (in-cluster cluster-admin) to
uninstall the Helm releases. The window is opened by a *constructive* step — creating
`kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]` — and the destroy's own
phase scope refuses creates (`destroy never constructs`, DEC-045). With nothing able to
grant the authority, the platform teardown is skipped and the phase continues, by design,
degraded.

The two policies are individually correct and jointly unsatisfiable here:

- destruction must not construct anything (DEC-045), and
- the platform teardown needs an authority that only a construction can grant.

Note what was **not** a problem: the refusal itself is the safety working. Sol declined to
create a cluster-admin binding during a destroy, and said so, rather than proceeding.

## Open questions for the decision

1. Is reopening the install window a legitimate *preparatory* step for destruction — i.e. is
   the window's binding part of the destruction's own machinery rather than an act of
   construction (it is created and then removed within the same run, and it is already
   created-and-removed during apply)? If yes, the fix is a scope refinement, not a policy
   exception.
2. Or should the platform teardown be re-expressed so it needs no in-cluster authority —
   e.g. by treating the platform root as subordinate to the cloud root's lifecycle, so that
   destroying the cluster is understood to have removed it, with the platform state
   reconciled as *gone* rather than destroyed?
3. Or is the honest answer a documented, operator-visible recovery path (a flag or a
   subcommand) that reopens the window explicitly for destruction, with the same
   confirmation semantics as any other destructive act?

## Acceptance criteria (for whichever decision is taken)

- A target left in `failed PlatformInstalling` can be destroyed by `sol cloud destroy` alone
  — no manual provider deletion, no raw state surgery — and afterwards **both** root states
  are empty and agree with the provider (queried class by class).
- The chosen mechanism does not weaken DEC-045: no resource is *created* in the provider
  outside the destroy's own declared preparation, and the run's plan-assert still refuses a
  create it did not declare.
- A failed-install destroy is covered by the offline harness
  (`internal/ci/test_cloud_lifecycle_offline.sh`) with a **positive control** for the
  degraded case (today the harness fakes exit codes; this needs a plan that asks to create
  the window during destroy).
- The completion notes record which of the three options was taken and why.

## What this finding does not claim

- It does not claim any provider residue remains: nothing billable is left.
- It does not claim the refusal is wrong; the refusal is what kept the destroy honest, and
  the degradation was reported rather than hidden.
- It does not claim the same shape occurs on a target destroyed from `Ready` — untested.

## Correction (2026-09-25) — the capability existed; the declaration could not express the address

The INFRA-079 investigation established that this finding's first framing ("the destroy refuses the
create it needs to reach the platform") was right about the symptom and incomplete about the cause.
**FACT:** the capability and its exception already existed — REFAC-094 recorded *"no CREATE/REPLACE
except the bootstrap-authority operation"*, and `reconciliation_policy` carries that rule with the
reason *"the temporary bootstrap-access mechanism may be created or updated to obtain destruction
authority"*, bracketed by `with_elevated_access`.

The GCP declaration named the mechanism with `Exact`, which compares strings, while
`cli/platform/infra/gcp/main.tf` declares it `count = var.provisioner_bootstrap_admin ? 1 : 0`, so
Terraform's plan address is `kubernetes_cluster_role_binding.provisioner_bootstrap_admin[0]`. The
permission was granted and unreachable. AWS never showed it because its mechanism is matched by
`Type`.

**Fix:** `Sol_cli_terraform_plan.Resource` — this resource, any instance — declared by GCP, with the
unit fixture and the offline authority fixture repaired to use the addresses Terraform emits (both
had been written with the declaration's own index-less string, which is why neither could detect it).
Decision recorded in `DEC-048`; ticket `INFRA-079`.

Still `FIXED_UNQUALIFIED`: the fix is proven offline (unit + the offline lifecycle suite + mutations)
and **not** live. Qualification requires a target actually left in failed `PlatformInstalling` to be
destroyed by `sol cloud destroy` alone with both root states empty afterwards. The preserved Attempt 8
state cannot demonstrate it (its substrate is already gone) and is `INFRA-082`'s subject; it was left
untouched.
