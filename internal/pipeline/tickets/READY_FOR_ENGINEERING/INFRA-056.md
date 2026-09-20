---
id: INFRA-056
type: bug
severity: medium
title: Give the profile an identity that can run its own diagnostic instruction
source: audit finding FND-0017
---

**Audit finding:** `internal/pipeline/audits/findings/FND-0017-no-identity-can-follow-sols-own-diagnostic-instruction.md`

## The defect

`sol deploy` prints `Run 'sol status' to check pod health.` — and no identity the
production profile provides can complete that command's diagnosis. Verified live
against the Run 8 target:

| Identity | `get pods` | `get events` |
|---|---|---|
| `sol-qual5-deploy` | ok | **forbidden** |
| `sol-qual5-cluster-access` | **forbidden** | **forbidden** |
| `sol-qual5-operator` | **Unauthorized** — no access entry exists | — |
| AWS SSO administrator | **Unauthorized** | — |

`sol status` renders unhealthy pods *with their last events*
(`rollout_diagnosis.render_unhealthy_pods`), so the deploying identity can list pods
but not explain them, and the identities meant for a human cannot authenticate.

## Two problems, delivered separately

**1. The missing read access.** `sol-qual5-operator`'s generated contract is AWS-side
only — `eks:DescribeCluster`, `eks:ListClusters`, `s3:GetObject`, `s3:ListBucket`
(`bootstrap/main.tf:234-241`), enough to *obtain* a kubeconfig and read state. But
`operator_role_arn` appears in exactly one place in the tree — an output description
— and **no EKS access entry and no RBAC binding is ever created for it**. So the
declared operator identity cannot reach the cluster at all.

Settle first, then implement: **which identity should hold the read access** — the
operator (needs an access entry plus a namespaced read-only Role) or the deploy
identity (already reaches the pods, lacks `events`)? A split answer is plausible:
the deploy reports events as part of its own failure output, while the operator
needs standing read access for later inspection. Frame the minimum:

| Resource | Verbs | For |
|---|---|---|
| `pods` | `get`, `list`, `watch` | `sol status` |
| `pods/log` | `get` | `sol open logs` |
| `deployments`, `replicasets` | `get`, `list`, `watch` | live image, rollout state |
| `events` | `get`, `list`, `watch` | the explanation |

Scoped to the workspace's own namespaces. Explicitly not: `secrets`, `pods/exec`,
`pods/portforward`, or any mutating verb. **Do not grant anything until the
intended-operator-contract question is answered.**

**2. The failure is invisible.** `fetch_namespace_events`
(`sol_cli_rollout_diagnosis.ml:397-404`) turns every failure into `[]`, so a denied
read is indistinguishable from a quiet namespace: `sol status` prints an unhealthy
pod with no events and no indication the evidence was unobtainable. This is the same
silent-degradation shape as FND-0014, and it should be fixed regardless of the access
decision — a diagnosis that could not read its evidence must say so, and should name
`events` as the thing it could not read.

## Acceptance criteria

1. The identity decision is recorded (a `DEC` if it changes what the profile
   promises), then the minimum read-only access is implemented as reviewed
   Terraform, and `internal/ci/`'s verb guards are updated deliberately rather than
   bypassed.
2. A workload that cannot become ready produces a diagnosis that includes the
   events explaining it, run through the identities the profile provides.
3. When events cannot be read, `sol status` says so explicitly instead of printing
   an empty diagnosis — with a regression test using a failing kubectl stub.
4. Events expire (about an hour by default). Decide and record whether the profile
   captures them at deploy time or accepts the window.

## Not in scope, and not to be inferred

**The `notify-worker` replica's failure is not classified by this ticket.** One
replica is ready, the other is not, logs are empty, and the event stream is
unreadable; `exit 137` is consistent with a liveness kill and with an OOM kill. It
is the case that exposed the gap, not evidence of a workload defect.
