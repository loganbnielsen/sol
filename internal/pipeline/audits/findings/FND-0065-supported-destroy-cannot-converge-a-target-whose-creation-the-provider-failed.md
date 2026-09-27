---
id: FND-0065
type: audit-finding
severity: high
source: GCP qualification Attempt 15b (2026-09-27), revision a1637841
---

# Supported destroy cannot converge a target whose creation the provider failed

**Depends on:** None.

**State:** `OPEN` — no remediation, and none attempted. This finding records a decision required; the
invariant it touches is correct as it stands, and this unit deliberately does not change it.

## Observed (GCP qualification Attempt 15b, 2026-09-27)

Preflight clean, the plan succeeded, and the cloud apply failed at the provider:

```
Error: Error waiting for creating GKE cluster: Try a different location, or try again later:
Google Compute Engine does not have enough resources available to fulfill the request
  with google_container_cluster.main, on main.tf line 101
```

A **zonal stockout**: the request was accepted and the provider could not satisfy it. Terraform had
already recorded resources, and the cluster was left in `ERROR`. The supported destroy then ran and
**refused**:

```
warning: preparation: refused before apply: guard-preparation phase: replace on
         google_container_cluster.main (google_container_cluster) is not an action this phase permits
warning: a preparation degraded and destruction continued
warning: the platform teardown was skipped because the bootstrap authority it needs could not be
         obtained (refused before apply: bootstrap-access-removal phase: replace on
         google_container_cluster.main (google_container_cluster) is outside this phase's scope)
warning: destruction reached absence with 2 degraded preparation(s)
error: refused before apply: bootstrap-access-removal phase: replace on google_container_cluster.main
       (google_container_cluster) is outside this phase's scope
```

The destroy exited non-zero with the cluster still standing; the qualification harness refused to
call teardown verified and kept the target file. Independent provider state afterwards: the cluster
`ERROR`, its subnet, a service account, a custom role and their bindings, and — because the apply had
created it before the cluster failed — a **billable Cloud SQL instance**.

## Problem

A provider-side failure during creation leaves a target whose Terraform state describes resources the
provider does not have in the shape the configuration asks for. The next plan therefore proposes to
**replace** the cluster. Sol's destroy refuses anything but the actions its phases permit, and
replacement — construction — is not one of them. That refusal is **correct**: destroy must not
construct, and the invariant holds.

What is missing is a *supported* answer for this state. The result is that Sol cannot converge such a
target to absence: the operator must act outside Sol (in this run, an authorized emergency
`gcloud container clusters delete` and `gcloud sql instances delete`, recorded separately and not
counted as Sol destruction), and the state keeps describing the dead resources, so a subsequent run
mismatches again.

## Root cause

Not a defect in the refusal and not a defect in the phases. The gap is that "state describes a
resource the provider has, in a shape the configuration no longer matches" and "state describes
something the provider never finished creating" are the same thing to the current guard, and only
the first has a supported treatment.

This is the territory `INFRA-082` parked from the other direction (a cloud root gone while the
platform state remains); this finding arrives at it from a provider failure.

## Decision required (do not fix in this unit)

Which of these is the product's answer, and on what evidence? All of them are *decisions*, not
patches:

1. **Distinguish the two cases in the destroy guard.** A plan action that Terraform derives from a
   resource it believes exists but the provider does not have is not "construction from nothing";
   the destroy could treat it as the absence it is. This is the narrowest option and the one most
   likely to be right, but it changes the guard's semantics and needs its own evidence.
2. **A supported, explicit "unblock" path** the operator invokes knowingly, which is not state
   surgery performed by an agent and not silent.
3. **Accept it, and document an emergency procedure** as the supported answer for provider-creation
   failure — recording that Sol's destruction is not responsible for it.
4. Something else.

**Explicit non-goals for whoever picks this up:** do not weaken the no-construction-during-destroy
invariant, do not add a silent "forget" path, do not perform state surgery automatically, and do not
add zone fallback or retry logic to provisioning (the stockout is provider-owned and transient).

## Impact

Every provider-side creation failure — a stockout, a quota refusal mid-apply, an API outage — leaves
a target that Sol cannot destroy, requiring an out-of-band cleanup that the qualification ledger
cannot attribute to Sol. The failure is fail-closed and tidy (nothing constructed by the destroy),
but the operator is left with state that lies about the world.

## Acceptance criteria

- The decision is recorded, with the invariant stated unchanged.
- Whichever option is chosen, a target left in this state can be converged to absence **by a
  supported path**, demonstrated offline and then live, and the qualification harness's
  teardown-verified rule holds for it.
- The emergency-procedure evidence from Attempt 15b stays recorded separately from Sol destruction.
