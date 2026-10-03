---
id: INFRA-082
type: decision
severity: medium
title: What destroying a target means when the cloud root is already gone but the platform state is not
source: GCP Attempt 8's preserved stale platform state, via the INFRA-079 decision investigation
---

**Depends on:** None.

**Related:** FND-0058 / `INFRA-079` (the cause of the stale state, fixed), DEC-048 (the authority
rule this is deliberately *not* part of), FND-0055, DEC-045,
`internal/qualification/records/2026-09-25-gcp-attempt8.md`.

**Reconciled with `DEC-057` (2026-09-29):** the developer-experience contract fixes
the *scoping* rule this decision sits under — `sol cloud destroy <target>` removes
an environment and leaves the durable installation intact — but it does not answer
the question here, which is about a target whose provider resources and platform
state disagree. The decision stays open. `DEC-057` adds one constraint: whatever
this resolves must never reach installation-level resources.

## Context

Attempt 8's destroy was degraded by FND-0058, so the platform teardown was skipped and the cloud
root was then destroyed. The preserved platform Terraform state still holds 11 resources
(`sol/qual/gcp/us-central1/platform.tfstate/default.tfstate`) whose objects cannot exist: the cluster
that carried them is gone. Today a further `sol cloud destroy` does not examine the platform root at
all in that state — `Substrate_absent` returns `Cleanup_not_needed` because *"Terraform represents
nothing"* — so the stale state is inert, unreported, and self-heals only if the target is applied
again.

## The question (answered 2026-10-03, decision below)

Is that acceptable, or should the supported path be able to establish that the platform's objects
cannot exist and reconcile the state accordingly? The shape matters:

1. **Accept it.** Record that a target whose substrate is absent has no platform obligations, and
   that stale platform state is bookkeeping whose only consequence is a destroy postcondition that
   cannot be met (`INV-DESTROY-4`'s "both destroys return success"). Cheapest; leaves the state
   object as an artifact.
2. **Extend the existing "forget what provably cannot exist" recovery** (INFRA-042:
   `platform-destroy-forget-unserved` already forgets state entries for kinds the cluster
   demonstrably does not serve, reasoning *"the objects, not the objects' absence, is what Terraform
   cannot address"*) to the absent-substrate case, with the same rule that only a *provable*
   absence qualifies — never an unreadable one.
3. Something else, if the review finds a smaller honest shape.

## Explicit non-goals

No provider discovery, no adoption/import, no ownership reconstruction, no generic state-truth
layer. If the answer is 2, the result must still be an explicit, reported act with its own evidence
rule, and FND-0055's "UNKNOWN is not ABSENT" must hold.

## Acceptance criteria

- Whichever option is taken, the preserved Attempt 8 state is accounted for: either declared inert
  with the consequence named, or reconciled by the supported path with evidence.
- No `terraform state rm`/`import`/provider deletion outside the chosen mechanism; the preserved
  bundle stays as it is until then.

## Disposition (2026-10-03) — decision required

Smallest decision: accept stale platform state as inert bookkeeping with the unmet destroy postcondition documented, or extend the INFRA-042 "forget what provably cannot exist" rule to the absent-substrate case with an explicit evidence rule. Consequence: accepting leaves `INV-DESTROY-4` unmet; reconciling adds an explicit, reported state-truth mechanism.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.


## Decision (2026-10-03) — reconcile provable absence

Operator decision: **Extend the existing INFRA-042 "forget what provably cannot
exist" rule to the absent-substrate and failed-create cases.**

Reconciliation is permitted only when provider absence is positively established
through the authoritative provider boundary. UNKNOWN — including authorization
failures, transport failures, malformed responses, or inability to inspect the
provider — must never be treated as ABSENT. The non-construction invariant is
preserved: reconciliation may remove stale Sol state but must never create
infrastructure to make destroy possible. Promoted to
`READY_FOR_ENGINEERING`.

## Reconciliation (2026-10-03, ADR 0005)

ADR 0005 bounds this work: the reconciliation it authorises covers state Sol
owns (its own platform root), and it never becomes a licence to discover,
import or mutate resources the user manages outside Sol.


## Sequencing (2026-10-03)

INFRA-082 and INFRA-094 share one mechanism — extending INFRA-042's "forget what
provably cannot exist" reconciliation to a broader positively established
provider absence. Implement INFRA-082 first; INFRA-094 reuses that mechanism
rather than inventing a second one. They are one reconciliation unit across two
tickets.

## Completion (2026-10-02) — reconciled, on positively established absence

**Premise verified on `main @ aecff578`.** The destroy's decision layer cannot address the
platform root at all, so the stale state of Attempt 8 is unreachable from a supported path:

```console
$ git show aecff578:cli/lib/cloud/sol_cli_cloud_destroy.ml | rg -c 'platform_dir|platform_backend'
(no match; exit 1)
$ git show aecff578:cli/lib/cloud/sol_cli_cloud_wiring.ml | rg -n 'platform_dir' | head -3
61:  ; platform_dir : string
75:  ; platform_dir =
392:  let { provider; pname; infra_dir; platform_dir; platform_backend; _ } =
```

Positive control for that search: `sol_cli_cloud_wiring.ml` matches `platform_dir` 12 times,
and `cmd_cloud_tf.ml`, `sol_cli_environment_stage.ml` and the lifecycle unit test carry it
too — it is the destroy's own decision layer that has no such handle. Reproduced end to end
against a binary built from `origin/main @ aecff578`, with the branch's new offline scenario
(`CLOUD_STATE_EMPTY=1 PARTIAL_INSTALL=1`): the baseline destroy reaches Terraform only in the
**cluster** root — no `cloud/gcp/platform show`, no `state-rm` — and exits 0 with both stale
platform entries untouched. The next `sol cloud apply` is what would have repaired it.

**Implemented.** `sol cloud destroy` now runs one reconciliation step before it prepares
anything. When the cloud root's state represents no substrate, it identifies the substrate by
the target's declared or resolved `cluster_name` (a target that declares none is left alone
with a warning rather than queried by a guessed name), asks the provider whether that
substrate is absent, and — only on a positive absence — reads the platform root's state and
forgets every entry with `terraform state rm`, naming each address and the query the
judgement rested on. Everything else leaves the state untouched and says so:

- a cloud root that still represents a substrate → the step does nothing and makes no
  provider query at all;
- the platform root represents nothing, or the provider still holds the substrate, or the
  query could not be answered (authorization, transport, malformed answer) → nothing is
  forgotten; the last two are reported as a warning naming the observation, and an absence
  Sol could not positively establish is never read as one (`FND-0055`, `DEC-040`);
- the platform root's state cannot be read, or a `state rm` is refused → a degradation, and
  the destroy still converges (a teardown is not blocked by Sol's own bookkeeping, ADR 0003
  invariant 6).

The evidence rule is one query per provider, by name, through the same authoritative
boundary the destroy verification already uses: `gcloud container clusters list` /
`aws eks list-clusters`, extracted into a named check that both the pre-destroy
reconciliation and the post-destroy inventory share, so the two cannot drift. Nothing is
constructed, imported or discovered, and no installation-level root is reached (`ADR 0005`).

**Evidence.**

- `cli/test/inline/test_cloud_destroy.ml` — the act is reported without becoming a
  degradation and runs before the substrate destroy; a failed reconciliation degrades and
  still converges; a destroy with nothing to reconcile claims nothing.
- `internal/ci/context/test_cloud_lifecycle_offline.sh` — `gcp-stale-platform-state`: the
  reconciliation names its evidence, issues `state rm` for both platform addresses, examines
  the platform root but runs **no** platform teardown, and reaches verified absence;
  `gcp-stale-platform-state-present`: a substrate the provider still holds refuses the
  reconciliation, issues no `state rm` and says why; and
  `gcp-stale-platform-state-unidentified`: a target that declares no `cluster_name` cannot
  identify the substrate at all, so the provider is never asked and nothing is forgotten.
- Before/after: the same scenario against a `aecff578` binary fails on the first assertion
  and shows the stale state left in place; against this branch it passes.

**Demo/example coverage.** No app-author surface changed — no `sol.toml` field, no scaffold
or generated manifest, no runtime contract — so no `examples/` or tutorial sample applies.
The runnable demonstration is the offline lifecycle scenario above, which drives the real
binary against Terraform/`gcloud` stubs.

**Language parity (DEC-022).** No language-parity impact: this is provider lifecycle
behaviour in the OCaml CLI, with no application-facing convention or framework primitive
involved.

**Limitations, recorded.** A substrate the provider still holds — including the Attempt-15b
shape, where a create failed and left the cluster in `ERROR` — is the *"exists but diverged"*
case the decision distinguishes from this one; the reconciliation does not fire for it, and
`INFRA-094` is where its supported treatment is decided and built. A `state rm` fails closed
on the entry it could not remove but does not by itself stop the destroy, which is deliberate:
the destroy's own provider verification still decides whether the target is absent.
