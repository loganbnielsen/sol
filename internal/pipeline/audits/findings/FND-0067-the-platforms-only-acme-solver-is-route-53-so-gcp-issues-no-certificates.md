---
id: FND-0067
type: audit-finding
severity: high
source: GCP qualification Attempt 17 (2026-09-28), revision 30ad9835
---

# The platform's only ACME DNS-01 solver is Route 53, so a GCP cluster issues no certificates

**Depends on:** None.

**State:** `QUALIFIED` (GCP half) — `DEC-055` decided on 2026-09-28 that GCP gets first-class TLS
through Cloud DNS and Workload Identity, and **GCP Attempt 19 observed the whole path**: both issuers
deployed with `dns01.cloudDNS`, the cert-manager pod impersonating its service account through Workload
Identity, both ACME orders `valid`, both platform certificates `Ready=True`, and the ingress serving a
hostname-matching certificate issued by the ACME staging CA (verified by SNI against the LoadBalancer IP,
not inferred from the certificate object). Attempt 18 is the specimen that did not get there — a manifest
type error in the conditional-local version of this change, recorded below and in
`internal/qualification/records/2026-09-28-gcp-attempt18-issuer-manifest-type-failure.md`. Record of the
qualified run: `internal/qualification/records/2026-09-28-gcp-attempt19-tls-path-verified.md`.

The AWS half remains unqualified: no AWS run has reached a platform install.

## Fix (DEC-055, 2026-09-28)

The shared module no longer knows an AWS-only solver. It selects the solver and the cert-manager pod's
identity from `var.cloud_provider`, and each provider root supplies its own values — the shape the module
already used for Thanos's object-store identity:

| concern | AWS | GCP |
|---|---|---|
| solver | `dns01.route53`, with the endpoint region now passed by the AWS root (`us-east-1`, unchanged) instead of hardcoded in the shared module | `dns01.cloudDNS`, with the project passed by the GCP root |
| identity input | `cert_manager_irsa_role_arn` (the cluster root's IRSA role) | `cert_manager_workload_identity_sa_email` (a new GSA) |
| pod wiring | `eks.amazonaws.com/role-arn` on the cert-manager service account | `iam.gke.io/gcp-service-account`, bound to `cert-manager/cert-manager` through `roles/iam.workloadIdentityUser` |
| least privilege | inline policy scoped to the workspace's hosted zone (unchanged) | two custom roles: record/changes authority bound **on the managed zone**, zone discovery at project level |

Both ClusterIssuers carry a `precondition` that refuses an empty provider identity: a solver that runs
without credentials must fail the apply rather than create certificates that can never issue.

**Workload Identity itself is now enabled**, because none of it was: the repo declared
`iam.gke.io/gcp-service-account` annotations and `roles/iam.workloadIdentityUser` bindings for Loki and
Thanos but never set the cluster's `workload_identity_config` or the node pool's
`workload_metadata_config`, so the pool served *node* credentials and every one of those annotations was
dead. That is a prerequisite of the mechanism `DEC-055` chose, and it is guarded now: the check refuses a
GCP cluster without the Workload Identity pool and a node pool that is not on `GKE_METADATA`. The Loki and
Thanos paths were never exercised live (`enable_durable_observability = false` in qualification), which is
why this had not surfaced.

The GCP cluster root also reads the managed zone when it pre-exists (`create_dns_zone = false`, the
qualification's case) so the record binding has a zone to scope to, and exports both the zone and the
identity. The GCP driver's install-time refusal — *"Sol cannot yet wire a certificate issuer on GCP …
or qualify the GCP issuer path first"* — is removed, which is the gate it existed to be: a GCP target that
declares `cluster_issuer` now installs the issuer path instead of being refused.

**A first live attempt at this failed in a way worth recording** (Attempt 18): the solver had been built
from a provider-conditional local, and Terraform's `kubernetes_manifest` provider could not convert the
unified object type against the CRD schema (`Failed to transform Tuple element into Tuple element type`).
The same config is re-read on refresh, so the *destroy* failed on it too — the substrate stood until the
module was fixed and Sol's supported destroy could run. The fix is that each provider now has its own
gated ClusterIssuer resources with literal manifests, exactly the shape that had already applied.

`internal/ci/check_provider_tls_path.py` and its sixteen mutations hold the contract: each provider has a
solver and an identity, each root supplies its own scope, each cluster root owns a zone-scoped permission
set, the pod carries the provider's annotation, an empty identity fails closed, and no driver refuses a
target that asks for TLS.

**One observation from implementing this, recorded rather than acted on:** the AWS path declared an IRSA
role for cert-manager but never annotated the pod, and that role's trust policy is the cluster's OIDC
provider — so the declared identity was arguably unreachable there too (node instance credentials cannot
assume an OIDC-scoped role). The annotation is now set for both providers, which completes the mechanism
the AWS root already declared rather than changing its solver; the AWS path stays unqualified until an AWS
run reaches a platform install and its certificates issue.

## Observed (GCP qualification Attempt 17, the first run to reach `Ready`)

The platform installed and the lifecycle reported **`lifecycle phase: Ready`** — the first time on GKE
Standard (`platform-apply ok (166.6s)`, 72 of 73 pods `Running`, all six PVCs `Bound`). The run then
waited for the DNS delegation and observed it, which is the boundary this harness deliberately keeps the
substrate up for:

```text
[18:54:45] delegation observed: ns-cloud-c1.googledomains.com. ns-cloud-c2.googledomains.com. …
[18:54:45] not tearing down: the delegation boundary is deliberate, not a leak
```

The harness writes its target **without** `cluster_issuer` (a GCP target that declares one is refused at
install time), so the platform's own default issuers are what is in play. Both deployed with exactly one
solver:

```yaml
solvers:
- dns01:
    route53:
      region: us-east-1
```

The ACME side works as far as the account: `kubectl get clusterissuer -o yaml` shows
`lastRegisteredEmail: qualification@sol-harden-qualification.dev` and
`reason: ACMEAccountRegistered`. The order and challenge are then created, and every challenge **fails**:

```text
monitoring  3m43s  Warning  PresentError  challenge/grafana-tls-1-2732564143-2203992144  Error presenting challenge: failed to determine Route 53 hosted zone ID: NoCredentialProviders: no valid providers in chain. Deprecated....
argocd      3m39s  Warning  PresentError  challenge/argocd-tls-1-3929449845-4183606240   (same)
```

`kubectl get certificates -A` after 14 minutes: `argocd/argocd-tls` and `monitoring/grafana-tls` both
`READY=False`, both challenges `pending`.

## Problem

`platform/cloud/modules/platform/cert_manager_issuer.tf` is the **shared** platform module, and it
declares the Route 53 solver unconditionally for both `letsencrypt-staging` and `letsencrypt-prod`, with
`region = "us-east-1"` hardcoded and `roleArn` coming only from `cert_manager_irsa_role_arn` — a variable
whose own description says *"IAM role ARN for cert-manager DNS01 Route53 access (AWS only). Leave empty on
GCP."* Nothing in the module, the GCP platform root, or the GCP cluster root offers a Cloud DNS solver,
so on GCP cert-manager falls back to the ambient AWS credential chain, and there is none.

The platform therefore reaches `Ready` — Sol's readiness does not depend on ACME — while **no ingress on
the cluster can obtain a certificate**. Every ingress `sol deploy` renders carries
`cert-manager.io/cluster-issuer: letsencrypt-prod` by default, so this is not limited to the platform's
own dashboards: it is the application TLS path on GCP.

## Decision required (do not fix in this unit)

1. **Implement a Cloud DNS DNS-01 solver for GCP** — `solvers: [{dns01: {cloudDNS: {project: …}}}]` with
   the Workload Identity binding that lets cert-manager write the zone, mirroring the AWS IRSA path — and
   select the solver *per provider* so the shared module stops assuming AWS. This is the option that
   makes the profile's TLS row reachable, and it needs its own live evidence (a certificate that issues).
2. **Declare the TLS row unsupported on GCP**, in the profile's capability record, so the harness and the
   matrix do not read "delegation observed" as a pass, and so the limitation is stated rather than
   discovered per-run.
3. **Refuse the profile on a provider with no solver** — a target that can never issue certificates
   should say so before installing, the way the Autopilot refusal does.
4. Something else.

**Explicit non-goals:** do not give a GCP cluster AWS credentials, do not switch the platform's
ingresses to HTTP-01 (they are DNS-validated by design and not all of them are publicly reachable), do
not weaken the issuer, and do not make `Ready` depend on certificate issuance — the current separation
is deliberate.

## Impact

The GCP TLS rows (`H2`/`H7`'s boundary) cannot pass, and neither can the application-deploy rows that
depend on an ingress serving a trusted certificate. A GCP run appears healthy — `Ready`, every pod
running, every volume bound — while the cluster silently cannot serve TLS, which is the state a
`Ready`-only check would report as success.

## Acceptance criteria

- The decision is recorded with its rationale.
- Whichever option is chosen, a GCP cluster either issues a certificate for a platform ingress (and the
  run records the issuance), or the profile states the limitation where a target's author reads it.
- The AWS path is unaffected: `cert_manager_irsa_role_arn` still drives the Route 53 solver there.
- The next GCP specimen's matrix gains a row that would have failed here, so this cannot regress
  silently.
