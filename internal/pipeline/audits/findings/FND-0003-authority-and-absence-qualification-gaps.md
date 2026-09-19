# FND-0003 — Post-revocation effective authority and four-identity permissions are not behaviourally qualified

- **Classification:** `QUALIFICATION_GAP`
- **State:** `OPEN`
- **First identified:** 2026-09-19 (authority audit, this pass)
- **Last verified:** 2026-09-19, `main @ 910a59f1` (reconciled after Runs 4 and 7)
- **Providers:** AWS and GCP
- **Derived ticket:** none
- **Related invariant:** `INV-AUTH-1`, `INV-AUTH-3`, `INV-AUTH-5`, `INV-DESTROY-4`
- **Related:** FND-0001, FND-0002; ADR 0002 ("Finding 6 owns comprehensive
  effective-permission qualification across all four identities"); matrix rows
  F5, I3, H6

## The gap

Sol proves parts of its authority and absence model by probe, but has not
behaviourally established several of the rows its own contract names. This
finding records the *qualification* state; it is not a defect claim.

### 1. Bootstrap capability after closure (both providers)

- **AWS.** After de-escalation, `sol cloud apply` runs
  `provisioner_authorization_established` — twelve live `kubectl auth can-i`
  checks (`sol_cli_cloud_lifecycle.ml:421-437`): positives for platform-namespace
  and cluster-scoped operations, negatives for workload mutations in `default`
  and for `bind`/`escalate` cluster roles. The checks run **after** the
  de-escalate apply, using the ephemeral kubeconfig that authenticates as the
  provisioner, so a successful Run 5/6 apply is **behavioural** evidence that the
  API server denied/authorized those twelve operations for that identity — the
  probes are not masked by the install window, because the window is closed
  first. What is *not* established:
  - the **capability** boundary (FND-0002's cloud-API path) is invisible to a
    `can-i` probe, so "bootstrap capability is gone" is not proven;
  - the negative probes are confined to the `default` namespace; an application
    namespace is not probed;
  - the raw probe outputs are not retained per run, so the observation's identity
    is inferred from the code path rather than recorded with the evidence
    (HARDEN-003); the ability of the probe to fail has not itself been
    demonstrated against a deliberately re-opened window.
- **GCP.** **Attempt 4 advanced this materially**: the platform stage ran as the
  *declared* GCP provisioner for 424.2s of real in-cluster work (namespaces,
  CRDs, RBAC) via impersonation, and the install window was then revoked
  (`provisioner-bootstrap-access-remove`, 8.1s). So the open/close pair is now
  observed on a run that actually did platform work, not only on a failed install
  (Attempt 3). What is still *not* established: the **post-closure**
  positive/negative boundary. Attempt 4 stopped at `helm_release.cert_manager`'s
  post-install check, so it never reached the intended steady-state probe, and no
  run has demonstrated that a bootstrap-only operation is denied after the window
  closes.

**What would qualify it.** A run that, after closure and with the target's own
scoped credential, (a) records each probe's raw output and the identity it ran
as, (b) demonstrates a denied operation in a non-`default` namespace, and (c)
attempts the provider's cloud-API escalation path and records the result
(denied after a fix, or explicitly accepted).

### 2. Four-identity effective permissions (AWS) — matrix row F5

ADR 0002 assigns "comprehensive effective-permission qualification across all
four identities" to finding 6. Today the evidence is:
- Run 1: deploy identity allowed `eks:DescribeCluster`/`ListClusters`, denied
  `ec2:*`, `iam:*`, `eks:CreateCluster` (a real negative proof).
- Run 5 Attempt 5: the corrected negative `can-i` for `bind`/`escalate`.
- INFRA-026's publisher policy and INFRA-025's deploy access entry were verified
  **offline**; the publisher deny/allow has never been asserted against a live
  account (HARDEN-002 explicitly leaves this "open for Run 5").
- The operator identity's read-only contract is unqualified.

Run 7 added a live data point in the opposite direction: the **deploy identity
was refused** an operation it should have been allowed —
`configmaps "sol-boundary-lease-…" is forbidden` (`INFRA-043` on `origin/main`).
A refusal is evidence the identity is bounded, but it is a *missing grant*, not a
demonstration that the intended grants are complete.

### 3. Absence coverage — matrix row H6

- **AWS.** `production-bootstrap.md:293-301` records that `verify_aws_destroy`
  covers EKS, RDS, ECR and load balancers, while **elastic IPs, NAT gateways and
  EBS volumes are only manually swept**. Every AWS run's "cost-clean" claim
  therefore rests partly on an operator sweep, not on the verifier. Run 7's
  independent verification did sweep EIP/LB/EBS/VPC/ECR and found none, but that
  is the harness's check, not `verify_aws_destroy`'s — the code gap is unchanged.
- **GCP.** Attempt 4 found a defect in the opposite direction: `verify_gcp_destroy`
  recognised `NOT_FOUND`/`was not found` while gcloud answers `code=404 … Not
  found:` and `HTTPError 404: … does not exist`, so a destroy that had removed
  everything was reported as a failure. That is fixed (#363), with the harness
  stub corrected to gcloud's real wording and mutation-tested. It is recorded
  here because it shows the same theme: absence verification is where a
  qualification instrument is most likely to be silently wrong.

## What is established

The probes that do exist are real and fail closed in code. The gap is coverage
and instrument identity, not absence of mechanism.

## What is NOT established

That a fresh actor holding the steady-state identities is denied every
capability the design says it is denied, and that a destroyed target has no
residual billable resource without an operator sweep.

## Impact

A conformance claim for the authority or teardown rows would rest on
configuration and partial probes. The qualification index marks these rows
unqualified so no reader mistakes them for passed.

## Derived engineering work

None directly. The matrix already names these rows; the work is to run them and
retain the evidence. FND-0002 may add a probe once the AWS decision is made.

## Reconciliation (2026-09-19)

Rebased onto `origin/main` and re-read against Runs 4 and 7: GCP install-window
authority strengthened (Attempt 4); GCP absence-recognition defect found and
fixed (#363); AWS absence-verifier coverage gap unchanged. No state change — the
post-closure boundary and the four-identity rows remain open on both providers.

## Supersession

None.
