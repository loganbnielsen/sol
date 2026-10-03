---
id: INFRA-094
type: bug
severity: high
source: GCP qualification Attempt 15b (2026-09-27)
---

# INFRA-094 — converge a target whose creation the provider failed

**Depends on:** None.

**Reconciled with `DEC-057` (2026-09-29):** the destroy semantics this concerns
are now stated at product level — environment destroy must converge the target to
absence without constructing, and must not touch the durable installation. That
strengthens the constraint rather than answering the question here, which is how
to converge a target whose creation the provider failed. Non-construction stays
the invariant; `DEC-057` adds that installation resources are out of scope for
any resolution.

Attempt 15b: a zonal GCE stockout failed the cluster creation after Terraform had recorded
resources; the supported destroy then planned a **Replace** of `google_container_cluster.main` and
Sol correctly refused it (destroy must not construct). The destroy exited non-zero with the cluster
standing, and the target could not be converged to absence — see `FND-0065` for the verbatim
evidence and the run record
`internal/qualification/records/2026-09-27-gcp-attempt15b-provider-stockout-and-partial-create.md`.

## The question (answered 2026-10-03, decision below)

The answer is a decision about destroy semantics, not a patch, and it must not weaken the
no-construction invariant. `FND-0065` lists the options: distinguish "state describes a resource the
provider never finished creating" from "state describes a resource that exists but no longer matches
configuration"; a supported explicit unblock path; or documenting an emergency procedure as the
supported answer. Resolve that decision (in this ticket or a DEC) before any implementation.

## Was blocked on (resolved 2026-10-03)

The decision above. This ticket was in `BACKLOG` on purpose and must not be picked up as actionable
until the decision is recorded.

## Non-goals

- Do not weaken the no-construction-during-destroy invariant.
- Do not add a silent forget path or automatic state surgery.
- Do not add zone fallback, retry or any provisioning-behaviour change: the stockout is
  provider-owned and transient.

## Disposition (2026-10-03) — decision required

Smallest decision: how the supported destroy converges a target whose provider-create failed mid-apply — distinguish "never finished creating" from "exists but diverged", a supported explicit unblock path, or a documented emergency procedure. Consequence: must not weaken no-construction-during-destroy; zone fallback/retry stay out of scope.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — reconcile provable absence

Operator decision (the same rule as INFRA-082): **extend the INFRA-042 "forget
what provably cannot exist" rule to the provider-failed-create case.**
Reconciliation is permitted only when provider absence is positively established
through the authoritative provider boundary; UNKNOWN — authorization, transport,
malformed response, or inability to inspect — is never ABSENT. Distinguish
"state describes a resource the provider never finished creating" from "state
describes a resource that exists but diverged", and keep no-construction as the
invariant: reconciliation may remove stale state but never create infrastructure.
Promoted to `READY_FOR_ENGINEERING`.

## Reconciliation (2026-10-03, ADR 0005)

ADR 0005 bounds this work the same way as INFRA-082: reconciliation covers state
Sol owns, and it never becomes a licence to discover, import or mutate resources
the user manages outside Sol.


## Sequencing (2026-10-03)

This ticket reuses the provable-absence reconciliation INFRA-082 introduces (the
INFRA-042 extension); it is not an independent mechanism. INFRA-082 lands first.
They form one reconciliation unit across two tickets.

## Completion (2026-10-02) — a substrate the provider lost is reconciled, and the phases that need it say so

**Premise verified on `main @ 90e5bd1e`** (INFRA-082 merged, this ticket's case still open). The
reconciliation exists but only fires when the cloud root represents *nothing*:

```console
$ git show origin/main:cli/lib/cloud/sol_cli_cloud_wiring.ml | rg -n -A8 'let provable_absence_reconciliation'
820:let provable_absence_reconciliation
...
832:  match substrate_presence state with
833:  | Substrate_present | Substrate_unknown -> Ok Nothing_to_reconcile
834:  | Substrate_absent ->
```

So a state that still represents `google_container_cluster.main` (the attempt-15b shape: the
create failed mid-apply, Terraform recorded the cluster and the resources inside it) is
`Substrate_present`, the reconciliation returns immediately, and the ordinary path re-plans the
cluster. The offline harness shows both halves of the defect against the binary built from that
commit — no `state rm`, and a preparation plan that still targets
`-target=google_container_cluster.main` with `-var=gke_deletion_protection=false` — while this
branch forgets four addresses and plans `-target=google_sql_database_instance.postgres` alone.

**Implemented.**

- The reconciliation's trigger is now *the state represents something the cluster carries*:
  entries whose address is one of the provider's `substrate_addresses` (newly shared by the
  registry, so the declaration the post-destroy inventory uses and the reconciliation uses
  cannot drift), or whose Terraform kind lives inside the cluster (`kubernetes_*`, `helm_*` —
  `Sol_cli_cloud_destroy.in_cluster_kind`), or a cloud root that represents nothing at all
  (INFRA-082's case, unchanged). The provider is asked only then, and only a positively
  established absence permits forgetting anything.
- On that evidence the cloud root's substrate and in-cluster entries are forgotten first
  (`destroy-forget-absent-substrate`), then the platform root's entries
  (`platform-destroy-forget-absent-substrate`), and every address is named in the report with
  the query the judgement rested on.
- `execute` re-reads the state after a reconciliation, because Terraform changed it: the
  postgres instance that is still standing keeps the substrate `Substrate_present` for the
  destroy's own accounting, but the phases that would have to reach the cluster are told what
  happened — the workload release is not attempted (and says why), and the platform teardown is
  skipped with the same evidence instead of being wired to install outputs the reconciliation
  just removed. A state that cannot be re-read is a degradation, not a refusal.

**The distinction the decision asked for, and what it means in practice.** "The provider never
finished creating it" is expressed as *the provider does not have it*: attempt 15b's cluster was
in `ERROR`, which is a cluster the provider holds — the absent-substrate branch is not reached,
the ordinary path runs, and a plan that would construct or replace `google_container_cluster.main`
is still refused. Reconciliation removes stale bookkeeping; it never constructs, and it never
touches installation-level resources (`ADR 0005`, `DEC-057`). Zone fallback and retry remain out
of scope as this ticket's Non-goals say: attempt 15b's stockout is provider-owned.

**Evidence.**

- `internal/ci/context/test_cloud_lifecycle_offline.sh` — scenario `gcp-lost-substrate`: the
  cloud state represents the cluster, the bootstrap ClusterRoleBinding and the SQL instance, the
  provider reports the cluster absent, and the platform root carries two stale entries. It
  asserts the evidence line, all four `state-rm` addresses, a preparation plan that targets
  postgres and *not* the cluster, no platform teardown, no bootstrap acquisition, no workload
  release (and the report that says so), the substrate destroy, and verified absence at exit 0.
  Against the binary from `origin/main @ 90e5bd1e` the same scenario fails at its first
  assertion — the defect the ticket describes, reproduced.
- The harness scenarios for INFRA-082 were adjusted to the fixtures' new, more faithful default:
  the provider lists the substrate unless a scenario says otherwise or the run already destroyed
  it, so "the provider still holds it" is the default shape and
  `SUBSTRATE_ABSENT_AT_PROVIDER=1` is the explicit one. Those scenarios pass unchanged in meaning
  (and pass against the `origin/main` binary too, which is what shows the fixture change itself
  is behaviour-preserving).
- `cli/test/inline/test_cloud_destroy.ml` — a substrate the provider lost skips the release and
  the platform teardown and verifies against the re-read state; a state that cannot be re-read
  degrades and the substrate teardown still runs; `in_cluster_kind` classifies `kubernetes_*` and
  `helm_*` and not a cloud object. The first fails when both skips are neutralised, which is what
  pins the branch rather than the fixture.
- `internal/ci/check_workload_release_order.py` and its mutation suite: the guard's release-rule
  table now records the provably-absent carve-out, and the mutation that removes the
  already-absent carve-out was re-anchored to the new expression (`if !substrate = …`), which the
  suite catches rather than aborting.

**Demo/example coverage.** No app-author surface changed — no `sol.toml` field, no scaffold, no
generated manifest, no runtime contract. The runnable behaviour is the destroy lifecycle, and the
offline harness scenario above is what a reader can run. `docs/guides/operations.md` § 7 now
describes the failed-create reconciliation beside INFRA-082's.

**Language parity (DEC-022).** No language-parity impact: the destroy lifecycle is CLI/provider
behaviour, with no application-facing convention involved.

**Limitations, recorded.** GCP and AWS share the code path, but only the GCP scenario is
driven end to end; the AWS fixtures list the substrate and model `state rm` the same way, and the
ordinary AWS destroy scenarios pass. The reconciliation still refuses when the target's
`cluster_name` is neither declared nor resolved, and when the provider's answer is anything but
`Absent` — an absence Sol cannot establish is never assumed.
