---
id: HARDEN-004
type: verification
severity: high
title: Realize and qualify the GCP production contract
source: GCP qualification mission 2026-09-18
---

**Related:** HARDEN-002 (the AWS conformance epic, whose scenario list this ticket
mirrors), HARDEN-003 (evidence identity). Detail, per-attempt evidence and the
decision record live in `docs/qualification/gcp-bootstrap-inventory.md`; this ticket
is the workstream's entry point and its current frontier.

## Goal

Take GCP from "Sol has GCP code" to "the same Sol production contract is realized
and qualified on idiomatic GCP infrastructure" — by running live, disposable
qualification attempts against one GCP project, not by porting AWS mechanisms.

The contract is provider-neutral; the mechanisms are not. What must be preserved is
capability parity: one authoritative default block-storage class appropriate to the
target, one authority model in which install privilege exists only for the install
window, one evidence discipline. What must *not* be carried over is AWS shape — ECR,
EBS/gp3, IRSA, Route 53, access entries — where GCP answers the same question
differently. Where GCP exposes a flaw in the provider-neutral model, fix the model.

## Standing constraints (these are the rules of the workstream)

1. **Cost rule, absolute.** Never wait for user input while billable qualification
   resources exist. On any blocker — a defect, a semantic or security decision, a
   missing prerequisite, an external dependency — the order is: preserve evidence →
   tear down → independently verify `Absent`/cost-clean → only then ask. Tearing
   down is part of qualification, and `terraform destroy` succeeding is *not*
   evidence of cost-cleanliness; the project must be inventoried.
2. **`Absent` is the postcondition for a disposable target.** No residual billable
   storage, snapshots, retained buckets, addresses, disks or load balancers, unless
   retention itself is the scenario. Production retention semantics are deliberately
   undecided (DEC-033) and GCP cannot express retention at all, so a GCP target whose
   `destroy_retention` is the `final-snapshot` default is **refused by name** rather
   than destroyed.
3. **Do not build cert-manager or Workload Identity speculatively.** Build them when
   a live attempt has reached the boundary that needs them. TLS issuance is
   **BLOCKED** — the qualification name is not delegated to the qualification
   project — and a blocked row is recorded as blocked, never as qualified. The
   owner controls `sol-fab.dev`, and `DEC-042` is now **decided**: `qual-gcp.sol-fab.dev`
   as its own Cloud DNS zone in `sol-qualification`, created by Sol's cloud root and
   delegated from the Squarespace-managed parent by hand (four `NS` records), with a
   scoped cert-manager identity. So this row is no longer waiting on a decision — it is
   waiting on implementation and the delegation itself. The rest of the workstream does
   not depend on it. (`qual-aws.sol-fab.dev` is reserved for the AWS profile; the
   delegation requirement follows from proving public TLS, not from GCP.)
4. **Never create long-lived service-account JSON keys.** Impersonation and
   short-lived tokens only.
5. **Do not weaken or restructure AWS behaviour to accommodate GCP.** Shared-definition
   changes keep the AWS contract and carry regression coverage.
6. **Preserve Terraform's ownership and dependency graph.** Terraform owns resource
   dependency and state mechanics; Sol owns semantic lifecycle transitions, authority
   boundaries, readiness semantics, evidence and cross-tool orchestration. Do not
   reproduce the resource DAG in OCaml.
7. **Evidence classes.** Static/configuration, mechanism/renderability, and live
   behavioural are different claims. Only the third satisfies a production
   behavioural claim, and a stub written from the implementation is not evidence
   about the tool it models.

## Where the work stands (2026-09-19, `main` @ `8d85c7ce`)

Qualified **behaviourally** (observed live against `sol-qualification`):

- cloud bootstrap through Sol's own lifecycle — VPC/subnet/router/NAT, GKE, Cloud
  SQL, Artifact Registry, Cloud DNS — with the install window open on the cloud root;
- the provisioner identity: creation, the impersonation grant to the *declared*
  caller, `--impersonate-service-account` cluster access, and the window opening and
  being revoked on both the success and failure paths;
- the platform stage running under that identity (424s of real in-cluster work);
- destruction of a **partially installed** platform through the documented lifecycle,
  then the cloud layer, then absence — verified through the provider's API, including
  the service-networking peering;
- the peering abandonment (`deletion_policy = "ABANDON"`) for two observations.

**Not** qualified, and not claimed: platform `Ready` (never reached), readiness and
convergence checks on GCP, any HARDEN capability scenario, certification/TLS,
Workload Identity wiring for the observability components, Cloud SQL regional HA,
production capacity/headroom on the selected GKE mode, and GCS durable-observability
wiring.

Attempts 1–4, their first meaningful failures and their evidence:
`docs/qualification/gcp-bootstrap-inventory.md`. Attempts are numbered and recorded
distinctly; a failed attempt is not a wasted one, and nothing is repaired into
conformance mid-attempt.

## Current frontier — what the next attempt is for

**A fresh disposable target, whose first objective is to get past
`helm_release.cert_manager` and reach platform `Ready`, exercising the readiness and
steady-state checks that no GCP run has ever reached.**

Attempt 4 stopped there: the platform prerequisites apply failed with

```
Error: failed post-install: 1 error occurred:
  * timed out waiting for the condition
  with module.platform.helm_release.cert_manager,
```

while cert-manager itself was healthy — `cert-manager`, `cert-manager-cainterjector`
and `cert-manager-webhook` all `1/1 Running` for 9m, six CRDs installed. The failing
thing is the chart's post-install **`startupapicheck` Job**: `Failed 0/1` after
7m49s, `BackoffLimitExceeded` at 117s.

**The next attempt's first task is to establish *why* that check fails, from the
check container's own output** — before helm deletes the Job and its reason with it.
Capture the Job's pod logs (or reproduce the check by hand against the cluster's
webhook) early, while the target is up.

The decision that follows is explicitly **not** "disable the check to make the
release pass": that would discard the only signal about whether the webhook is
reachable, which is what issuance depends on. The fix is either a GCP-shaped values
override justified by the evidence, or a real GKE/Autopilot incompatibility worth
fixing properly.

After that boundary, in order: platform `Ready` and its readiness semantics → the
provisioner RBAC steady-state checks → behavioural capability scenarios that GCP can
honestly support → destruction and `Absent` (again, and measured).

## Required scenarios (GCP counterpart of HARDEN-002's list)

Recorded honestly as they are reached; inapplicable or blocked rows stay visible
rather than being dropped.

| scenario | status |
|---|---|
| cloud bootstrap, ready substrate, documented destroy, `Absent` | qualified |
| provisioner impersonation, install window open/revoke | qualified |
| platform installation under the provisioner | **partially — stops at cert-manager** |
| platform `Ready` (readiness/convergence) | not reached |
| workload deploy + request | not reached |
| observability: log→Loki, metric→Prometheus, trace→Tempo | not reached |
| ingress | not reached |
| TLS issuance | **BLOCKED — decided, not yet implemented** (`DEC-042`: `qual-gcp.sol-fab.dev` delegated as its own Cloud DNS zone, created by the cloud root; the Cloud DNS solver swap is the other half of `FND-0007`) |
| Kafka produce→consume, broker-loss durability | not reached |
| database HA/failover, node-loss recovery | not reached |
| failed deploy, rollback, credential rotation, drift | not reached |

## Acceptance criteria

1. The same Sol lifecycle contract (ADR 0003) runs on GCP end to end: `Absent` →
   `CloudBootstrap` → `PlatformInstalling` → `Ready` → destruction → `Absent`,
   through `sol cloud`'s own commands, with no out-of-band repair.
2. Every production behavioural claim made about GCP rests on live evidence from a
   disposable target, and every row that is not qualified says so.
3. Steady-state identities hold no install privilege: the authority required to
   install privileged components exists only during the stage that requires it.
4. A disposable target reaches literal `Absent`, verified independently of
   Terraform's exit status.
5. AWS behaviour is unchanged, and every place GCP forced the provider-neutral
   model to be sharper is recorded (the abstraction audit).

## Progress

- **Attempt 1** — cloud-only path; three defects; teardown non-conformant
  (service-networking peering). Superseded but kept as evidence.
- **Attempt 2** — scoped-authority work landed; the authority model could not be
  entered (`--kubeconfig` does not exist; impersonation was never granted).
- **Attempt 3** — provisioner impersonation and ephemeral cluster access worked; the
  host lacked `gke-gcloud-auth-plugin`, discovered inside a billable apply;
  `INFRA-042` filed (a partially installed platform was not destroyable).
- **Attempt 4** — `INFRA-042` merged and exercised live; the platform stage ran as
  the provisioner; the documented destroy completed a partial install; the
  peering abandonment was qualified by observation. Sol's own absence verification
  was found to be unable to recognise gcloud's actual 404 wording, and fixed.
- **Attempt 5 (next)** — past cert-manager to platform `Ready`, per "Current
  frontier" above.
- **GCP invariant matrix (offline)** — the provider-neutral invariant inventory is
  expressed as GCP scenarios in
  `docs/qualification/gcp-production-single-region-v1-matrix.tsv`; the checked-in
  verifier makes missing, failing, or insufficiently evidenced rows non-conformant.
  This is an executable contract only and does not promote any row to qualified.
