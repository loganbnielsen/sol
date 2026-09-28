---
id: FND-0067
type: audit-finding
severity: high
source: GCP qualification Attempt 17 (2026-09-28), revision 30ad9835
---

# The platform's only ACME DNS-01 solver is Route 53, so a GCP cluster issues no certificates

**Depends on:** None.

**State:** `OPEN` — a decision is required and no remediation was attempted: a Cloud DNS solver for GCP,
an explicit statement that the profile's TLS row is unsupported there, or a refusal. This finding
records the first live exercise of the boundary.

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
