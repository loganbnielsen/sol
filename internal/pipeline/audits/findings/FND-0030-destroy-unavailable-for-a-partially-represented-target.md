# FND-0030 — Destroy is unavailable for an interrupted target, because PreparingDestroy reconciles constructively first

- **Classification:** `VERIFIED_DEFECT` — the behaviour is observed; the *mechanism* is an
  open design question
- **State:** `FIXED_UNQUALIFIED` — mechanisms 1 and 2 landed 2026-09-24 (HARDEN-004 steps 2–4),
  the convergence half was **withdrawn** by DEC-045, and this finding's own closing condition —
  INFRA-076 removing the Sol-caused route — is met. See the 2026-09-25 transition at the end of
  this file.
- **First identified:** 2026-09-23 (GCP Attempt 6)
- **Last verified:** 2026-09-25, `main @ 146eb90c` (the restated criterion against the code;
  no provider call)
- **Provider:** GCP observed (GKE); the shape is in shared lifecycle code — see "NOT established"
- **Derived ticket:** the ownership half is `DEC-044` (undecided) → the implementation that
  decision authorizes; the verification half is FND-0055
- **Related invariant:** **ADR 0003 invariant 6** — destruction is an abort edge available
  from every phase, including a half-built one
- **Related:** `INFRA-067` (the same family, a different manifestation), `FND-0028`,
  `docs/qualification/2026-09-23-gcp-attempt6.md`

## The invariant this violates

ADR 0003 invariant 6 states that destruction is an abort edge available from **every**
phase that can hold infrastructure, including a half-built one. The implication that
matters here: for a partially created target, **absence is progress toward the destroy
postcondition.** A destroy path must never require reality to first look like a
successfully applied target.

## The observed failure

An apply was interrupted after the provider had created resources but before Terraform's
state recorded all of them (the GKE cluster existed and was absent from state). Then:

| Step | Result |
|---|---|
| `sol cloud destroy … --apply` | `gcp-destroy-prepare` runs a **constructive** targeted apply (`-target=google_container_cluster.main`) to lower deletion guards |
| that apply | **fails**: `googleapi: Error 409: Already exists` — Terraform plans to *create* the cluster that exists but is not in state |
| the destroy | aborts before destroying anything |

So the only supported path to zero refused to run because the target was half-built — the
state in which it is most needed. Recovery required, in order: an attempted
`terraform import` (which hung on the cluster, then `PROVISIONING`), direct provider
deletion of Cloud SQL and of the cluster (refused until the orphaned GKE creation
operation cleared, then driven through a retry loop), removal of three stale SQL entries
from state, and a final `terraform destroy` (11 resources). None of that is a product
contract, and the user-facing consequence is the one the cost rule exists to prevent.

## Why this is separate from INFRA-067

`INFRA-067` fixed destruction being refused by **install-time validation**
(`PreparingDestroy` evaluating a capability guarantee). This finding is about
**reconciliation semantics**: the destroy path performs constructive reconciliation
before destructive reconciliation, so a divergence between state and provider reality
blocks teardown. Both are instances of one architectural statement — *a destruction path
must not depend on logic whose purpose is creation* — but they are different mechanisms
with different fixes, and `INFRA-067`'s fix remains correct on its own.

## Acceptance criterion (behavioural, deliberately not prescriptive)

> Given an apply interrupted after provider resources have been created but before the
> target is fully represented or reconciled, Sol provides a supported path to converge
> target-owned infrastructure toward **absence** without first creating missing target
> resources.

Whether that is achieved by bypassing constructive preparation, by refreshing/adopting
resources, by invoking Terraform differently, or by an explicit recovery operation is a
design decision. Today's manual procedure **must not** be encoded as the product contract.

## Design (2026-09-23) — smallest change consistent with invariant 6 and the acceptance criterion

Three mechanisms, in increasing cost. The first two are strictly local to the destroy path and
become the implementation; the third exists because adoption is the only thing that converges
a *divergence*.

**1. The destructive preparation is a means, not a gate.** `prepare_destruction`
(`cmd_cloud_tf.ml`, the `rds-destroy-prepare` and `gcp-destroy-prepare` phases) lowers
deletion guards so the destroy can proceed. A failed preparation must not block the destroy:
report it and continue. Today a failure to *prepare* becomes a refusal to *attempt* the very
operation whose failure it was trying to avoid — the inversion ADR 0003 invariant 6 forbids.
The destroy's own error is the accurate signal, and it names the real cause.

**2. The preparation targets only resources present in the target's state.** Terraform's
`apply -target=<x>` **creates** `x` when it is in the configuration but absent from state —
exactly the `409 Already exists` of Attempt 6. The targeted list must come from
`terraform state list` (the resources the target's state actually holds). A resource absent
from state is not a resource to un-guard; for a half-built target the preparation then has
nothing to do, and it cannot create anything. This is the part that makes **zero create
operations during recovery** observable rather than hoped for: the targeted apply is the only
constructive step in the destroy path.

**3. Adoption, because convergence needs it.** With 1 and 2, destroy *proceeds* on a
divergence — and then honestly reports residue, because a resource present in the provider
and absent from state is neither created nor destroyed by Terraform. Converging it requires
adopting it and then destroying it: a Sol-driven import from an inventory of target-owned
resources. That is a **new capability**, not a repair of this defect, and it is the piece that
makes "Sol, not the operator, owns getting back to zero" true for divergence. Not designed
here beyond this paragraph.

### Evidence plan

- Pure, offline: the target-selection function takes state entries plus the desired targets
  and returns the targeted list — unit-tested for the three cases (present, absent, mixed),
  because that is where the `409` came from. Plus a regression that a failed preparation does
  not abort the destroy.
- Attempt 7 (live, gated): controlled half-built target, then **positive** — reproduction via
  the supported path converges to absence; **negative** — zero target-owned create operations,
  no declaration edited, no Terraform state surgery, no provider-native deletion, not by the
  operator and not by the harness.

## What is NOT established

- The mechanism, and therefore whether it is a phase-boundary change or a recovery
  operation (needs a decision; `INFRA-067`'s context distinction is a precedent for the
  former).
- Whether AWS is affected: the destructive preparation is provider-shaped
  (`google_container_cluster` here), but the *constructive reconciliation before destroy*
  is a shared-lifecycle property.
- The complete set of divergence shapes. One is observed (resource created, absent from
  state). Others — resource deleted out of band, partially recorded attributes — were not
  exercised.

## Supersession

- **2026-09-23 — correction to the Design section's claim that "the targeted apply is the
  only constructive step in the destroy path."** It is not: after preparation, `cloud_destroy`
  runs `destroy-reconciliation-apply` and `provisioner-bootstrap-access-remove`, both
  `whole_root` applies (`cmd_cloud_tf.ml:2906-2925` at `f3e9480b`), which would plan to create
  the very resource the preparation skipped. The design text above is left as written (it is
  the record of what was believed); the "zero create operations during recovery" criterion
  must be tested against the real sequence. See **FND-0044** / `INFRA-068`; the precision
  issues in the #451 implementation are **FND-0048** / `REFAC-091`.

## Transition (2026-09-24) — mechanisms 1 and 2 landed; the convergence half is what remains

Verified at `origin/main @ 2775d5b1`, pre-live (no provider call was made).

**Mechanisms 1 and 2 of the Design section are implemented, and the "destroy is unavailable"
half of this finding is fixed.** Mechanism 1 (the destructive preparation is a means, not a
gate) — `Sol_cli_cloud_destroy.execute` decides the consequence of a preparation failure from
the typed `preparation_outcome`, and only `Block_destroy` stops destruction. Mechanism 2 (the
preparation targets only resources present in the target's state) — eligibility is
`configuration INTERSECT state` (`preparations_eligible`,
`cli/sol/lib/sol_cli_cloud_lifecycle.ml:411-421`), and **every** apply reachable from destroy is
now planned to a saved plan, classified from Terraform's own resource changes, and refused
before it runs when a change is outside that phase's allowlist
(`cli/sol/lib/sol_cli_terraform_plan.ml`; the phase policies are in
`cli/sol/lib/sol_cli_cloud_destroy.ml:626-711`). The reconciliation apply is no longer
`whole_root`. So the specific failure of Attempt 6 — a `-target` on the cluster planning a
**create** of something that already exists — is refused rather than attempted.

**The acceptance criterion is nevertheless still not met, because convergence is mechanism 3
(adoption), and mechanism 3 does not exist.** A resource present in the provider and absent
from state is neither created nor destroyed by Terraform, so with mechanisms 1–2 the destroy
*proceeds and completes on everything state owns* while the divergent resource survives. That
is what the design text above says, and it is confirmed on current `main`:

- `destroy_substrate` is state-driven only (`cli/sol/lib/sol_cli_terraform.ml:85-92`, called from
  `cli/sol/bin/cmd_cloud_tf.ml:3590-3612`), and no `terraform import` wrapper exists anywhere in
  the CLI;
- the divergence is reported as a **warning** over the guarded set only
  (`cmd_cloud_tf.ml:2213-2273`, helper at `sol_cli_cloud_lifecycle.ml:411-421`) and never
  reaches the verification verdict.

**Attempt 7 was opened under explicit authorization and stopped before any live resource was
created**, because the positive postcondition it requires cannot be reached for a divergent
resource without adopting it — the mechanism this finding's design point 3 names as "a new
capability". The pre-live falsification is recorded as **FND-0056**, the verification blind spot
it exposed as **FND-0055**, and the undecided design question as **`DEC-044`**. A provider
*cascade* (a parent's deletion removing the child) can make a particular orphan disappear, but
that is provider behaviour, not this contract, and it is explicitly not being reported as a
qualification.

Nothing in this finding's classification changes: the behaviour was observed (Attempt 6), and
the remaining work is still a mechanism decision.

## Correction and restatement (2026-09-24, DOCS-022)

**The causal premise is falsified.** "An apply was interrupted after the provider had created
resources but before Terraform's state recorded all of them" is true, but it omits *who*
interrupted it and *how*: the operator force-unlocked the live apply's lock, then SIGTERM'd
Terraform and its provider plugin (corrected Attempt 6 record). Nothing in Sol's supported lifecycle
produced the divergence. The only Sol-caused route to that shape is Sol's own death SIGPIPE-killing
Terraform: reproduced locally, fix pending (INFRA-076).

**Design point 3 (adoption) is withdrawn** with DEC-044's A1 (DEC-045; plan § Decisions 6).

**What remains required, restated:** (1) destroy never constructs: every destroy-path apply is
saved-plan asserted (landed); (2) a half-built target is always destructible: preparation targets
only what state represents, and preparation failure is a degradation unless a declared guarantee
blocks it (landed); (3) divergence Sol cannot vouch for **fails closed and is named**. It is not
converged by Sol. Reconciling it is the operator's job, using Terraform's own tools. Under that
restatement the acceptance criterion is met by mechanisms 1–2 plus the fail-closed report, and
convergence is out of contract. State stays `OPEN` only until INFRA-076 removes the Sol-caused route;
the plan (`internal/pipeline/audits/2026-09-24_cloud_lifecycle_simplification_plan.md`) tracks it.

## Transition (2026-09-25) — `OPEN` → `FIXED_UNQUALIFIED`

This finding's own 2026-09-24 correction ended with a condition rather than a state: *"State stays
`OPEN` only until INFRA-076 removes the Sol-caused route"*. That condition is now met:

- **INFRA-076 is `DONE`.** The supervisor runs in a session of its own (`Unix.setsid ()`,
  `cli/sol/lib/sol_cli_supervised.ml:405`), writes Terraform's output to durable files, records an
  `exit` completion record, and Sol forwards exactly one SIGINT to Terraform's pid — so Sol's death
  no longer kills Terraform by SIGPIPE, which was the only Sol-caused route to a
  provider-present/state-absent resource.
- **The convergence half is withdrawn** (DEC-045; A1 withdrawn, plan § Decisions 6): reconciling a
  divergence is the operator's job with Terraform's own tools, and the product's duty is
  mechanisms 1–2 plus the fail-closed report. Under that restatement the acceptance criterion is met
  by the landed mechanisms and the report, which is why this moves to `FIXED_UNQUALIFIED` rather than
  staying `OPEN` for work that is out of contract.

`FIXED_UNQUALIFIED`, not `QUALIFIED`: the fail-closed behaviour (a divergence is named, never
converged, never silently passed) has offline evidence only. GCP Attempt 8 exercises the destroy path
on a partially-installed target, but its target has no divergence by construction, so it cannot turn
this into a live qualification of the divergence report.
