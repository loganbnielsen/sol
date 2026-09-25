# FND-0029 — A target `apply` accepts is refused by `destroy --apply`

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` — fixed by `INFRA-067` (#445); the fix survives the
  provider-boundary refactor, and the live observation (apply accepted an issuer-declaring
  target, then destroy completed on that unedited target) has not been made. See the
  2026-09-25 transition at the end of this file.
- **First identified:** 2026-09-22 (GCP Attempt 5)
- **Last verified:** 2026-09-25, `main @ 146eb90c` — the fix's presence and its install-only
  scope, read from the code; the behaviour itself is unobserved live
- **Provider:** GCP observed (GKE); the mechanism is provider-neutral — see "What is NOT established"
- **Derived ticket:** `INFRA-067`
- **Related:** `FND-0007` (the refusal's wording), `FND-0028` (durable prerequisites),
  `HARDEN-004`, `docs/qualification/2026-09-22-gcp-attempt5.md` (the run chronology)

## Invariant

**Any target Sol permits to create billable infrastructure must retain a supported
destruction path without requiring undocumented configuration surgery.**

## The observed fact

A GCP qualification target declaring `cluster_issuer: letsencrypt-staging` was
accepted for creation and refused for destruction, through the documented lifecycle:

| Step | Command | Result |
|---|---|---|
| Create | `sol cloud apply qual/gcp/us-central1 --apply` | **accepted** — `terraform-apply ok (592.2s)`; the root's state lists 17 managed resources (plus 2 data sources) — GKE, Cloud SQL, VPC/subnetwork, router+NAT, address, peering, Artifact Registry, provisioner SA + IAM |
| Destroy (read-only) | `sol cloud destroy … --plan` | **accepted** — `terraform-plan-destroy ok (1.8s)` |
| Destroy (mutating) | `sol cloud destroy … --apply` | **refused** in `PreparingDestroy` |

The refusal, verbatim:

> error: this GCP target declares cluster_issuer, but Sol cannot yet wire a
> certificate issuer on GCP: the shared platform definition's ClusterIssuers use the
> Route 53 DNS-01 solver and there is no qualified Cloud DNS solver or scoped
> Workload Identity for cert-manager yet. Remove cluster_issuer from the target to
> provision the platform without public TLS, or qualify the GCP issuer path first

## What the evidence narrows

Three facts together say where the fault is, and they are worth keeping distinct from
the wording of the refusal:

1. **Creation accepted the field.** `CloudBootstrap` applied with it and created the
   infrastructure. So this is not a globally-invalid declaration.
2. **Read-only destruction accepts the field.** `destroy --plan` runs the same target
   through `terraform plan -destroy` and succeeds, both with and without
   `cluster_issuer`. So the target is parseable and destroyable *as configuration*.
3. **Only `destroy --apply` refuses it**, at the `PreparingDestroy` phase, in that
   phase's **reconciliation apply** — the log shows
   `[gcp-destroy-prepare] ok (9.5s)` → `lifecycle phase: PreparingDestroy` →
   `[destroy-reconciliation-apply] ok` (after guards were lowered) → the refusal. The
   same validation that is appropriate when *installing* the platform is therefore
   reachable from the destruction path, where it is not actionable.

The unblock used the correction the refusal itself prescribes (removing
`cluster_issuer` from the untracked target), which is what made the documented destroy
path available again. That is evidence about severity, not about the fix: an operator
tearing down infrastructure should not have to edit the declaration to satisfy a phase
that is not installing anything.

## Call path (localized 2026-09-23)

The guard is in `Sol_cli_cloud_lifecycle.platform_terraform_vars`'s GCP branch
(`sol_cli_cloud_lifecycle.ml:363-372`), reached from
`cmd_cloud_tf.ml:739-744` — which every platform phase calls, including
`platform-destroy` (`cmd_cloud_tf.ml:2669`). The destroy sequence lowers the cloud
guards, reconciles, and then computes the platform's variables to remove it, and that
computation is where a creation-time capability requirement is enforced against a
teardown. `destroy --plan` plans the cloud root only and never reaches it, which is the
whole of the plan/apply disagreement. Recorded in full in `INFRA-067`.

## What is established

- A real, reproducible asymmetry in the lifecycle contract: accepted for creation,
  refused for destruction.
- The refusal's location: `PreparingDestroy`'s reconciliation, not the CLI's target
  parsing and not the destroy plan.
- Consequence when it happens: the only supported destruction path is unavailable, and
  the resources stay billable until the declaration is edited or an out-of-band
  mechanism is used. In this instance that window was ~20 minutes of live GKE + Cloud
  SQL before the workaround took effect, and only because an operator recognised the
  refusal as the fix.

## What is NOT established

- **The shape of the fix.** The fault could be that `PreparingDestroy` runs install
  validation it should not, that the platform-definition check is evaluated against a
  phase it does not apply to, or that creation should have refused the configuration
  instead. The invariant above is the requirement; `INFRA-067` chooses the mechanism,
  and it must not weaken install-time validation to get there.
- **Whether AWS is affected.** The check in question is in the shared platform
  definition, so the mechanism is provider-neutral, but no AWS run has been observed
  in this state.
- **How many other install-only validations are reachable from the destruction path.**
  This finding establishes one; a fix should ask whether the class exists.

## The stale lock is not part of this defect

The teardown's first attempt was SIGKILLed mid-flight, which left a Terraform state
lock; it was cleared with `terraform force-unlock` after confirming no Terraform
process remained. That is normal recovery after killing a process, recorded in the run
chronology, and deliberately **not** counted as a defect here.

## Supersession

None.

## Transition (2026-09-25) — `OPEN` → `FIXED_UNQUALIFIED`

The fix merged in #445 (`4a9db5e5`) and this finding was never updated with it, so its `OPEN` state
described work that had already landed. Verified on `main @ 146eb90c` that the mechanism is present
and still *install-only*:

- `Sol_cli_gcp_cluster.platform_vars` matches on `cluster_issuer, context` and refuses only
  `Some _, Install`; `Some _, Destruction | None, _` is accepted.
- `Sol_cli_cloud_lifecycle.platform_terraform_vars` takes `?context` (default `Install`, so
  installation stays as strict as it was) and the destroy path passes `Destruction`
  (`cli/sol/bin/cmd_cloud_tf.ml:1278,1371`).
- The refactor kept the fix: the branch moved from the lifecycle module into the provider module
  (REFAC-095/096) with the same `Install`/`Destruction` distinction, and `INFRA-067` moved to `DONE`
  on this date with its remaining acceptance item named there.

**Not `QUALIFIED`, and the qualifying observation is deliberately not Attempt 8's.** The shape this
finding needs is: `sol cloud apply` accepts a target that *declares* `cluster_issuer` (the cloud root
is applied; the platform stage is then refused, as in Attempt 5), and `sol cloud destroy --apply`
completes on that same, unedited target. GCP Attempt 8 removes the field on purpose — with it
declared, the run cannot reach cert-manager at all, which is the one thing the attempt exists for —
so Attempt 8 does not produce this shape. A dedicated, cheap run (cloud root only, then destroy)
would; until one happens this stays `FIXED_UNQUALIFIED`, exactly as the ticket's AC1 says.
