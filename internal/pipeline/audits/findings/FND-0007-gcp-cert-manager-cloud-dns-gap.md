# FND-0007 — GCP cert-manager cannot issue: the shared issuers are hard-wired to Route 53

- **Classification:** `QUALIFICATION_GAP`
- **State:** `BLOCKED` (TLS issuance: `sol-qual.dev` is not delegated to the
  qualification project, so DNS-01 cannot complete; the Cloud DNS solver wiring
  itself is unimplemented and would otherwise be `OPEN`)
- **First identified:** 2026-09-18 (`gcp-bootstrap-inventory.md`)
- **Last verified:** 2026-09-19, `main @ 910a59f1`
- **Provider:** GCP / GKE (AWS is fine)
- **Derived ticket:** none — already tracked as `gcp-bootstrap-inventory.md` remaining gap 1
- **Related invariant:** `INV-SUBSTRATE-1`, `INV-SUBSTRATE-2`
- **Related:** matrix row I14; `docs/qualification/gcp-bootstrap-inventory.md` §"Remaining gaps" (gap 1) and §"Proposed GCP capability mapping" (DNS/TLS row)

## Sol claim at stake

The platform installs cert-manager and two `ClusterIssuer`s so that a workload's
`ingress_host` receives a TLS certificate. This is provider-neutral in intent.

## Current implementation evidence

`cli/platform/infra/base/cert_manager_issuer.tf:27-31, 53-58` declares both
`letsencrypt-staging` and `letsencrypt-prod` with a single `dns01` solver:
`route53`. `base-gcp` calls the same `base` definition, so a GCP install gets
Route 53 solvers. No `cloudDNS` solver exists anywhere in `cli/platform/`.

Product mitigation: a GCP target that declares `cluster_issuer` is **refused by
name** rather than handed an issuer that cannot work
(`gcp-bootstrap-inventory.md` §"Remaining gaps", gap 1).

## Verified provider contract

cert-manager natively supports Google Cloud DNS:

> "cloudDNS `ACMEIssuerDNS01ProviderCloudDNS` (Optional) Use the Google Cloud
> DNS API to manage DNS01 challenge records."
> — https://cert-manager.io/docs/reference/api-docs/

The solver takes `project` and an optional `serviceAccountSecretRef`/hosted-zone
configuration, so a Cloud DNS realization needs a scoped identity as well as the
solver swap.

## Evidence available

| Tier | Evidence |
|---|---|
| STATIC | the Route 53-only solver declarations; the shared definition and `base-gcp` module call; the refusal path |
| MECHANISM | none for GCP TLS (Attempts 3 and 4 never reached platform readiness) |
| BEHAVIORAL | AWS Route 53 issuance is exercised by the platform path; GCP issuance has never been attempted, and cannot be as written |

## What is established

GCP cannot issue a certificate through the shared issuers, and the product
refuses the configuration rather than pretending. The gap is recorded in the
GCP inventory and owned by the GCP agent.

## What is NOT established

- The Cloud DNS solver + scoped Workload Identity wiring (unimplemented).
- A delegated qualification hostname and a real DNS-01 round trip (external
  prerequisite: `gcp-bootstrap-inventory.md` §DNS and TLS).

## Impact

A GCP workload requiring public TLS is not deployable under the profile until
the solver is replaced. This is a capability gap in the GCP path, not a
correctness defect in AWS.

## Why no ticket

It is not double-ticketed because the GCP inventory already tracks it as its
first remaining gap and the GCP agent owns the implementation; creating an
`INFRA-*` ticket here would duplicate that ledger. If the GCP agent wants a
tracked engineering ticket, the finding is the evidence body for it.

## To move to qualified

Implement a Cloud DNS (or operator-selected external DNS) solver with a scoped
identity; delegate a test hostname; issue a real certificate. Matrix row I14
explicitly does **not** gate `Ready` on external ACME, so this is a separate
capability row, not a `Ready` row.

## Reconciliation (2026-09-19)

Attempt 4 confirms both halves and adds a boundary. The platform prerequisites
apply stopped at `helm_release.cert_manager`'s post-install `startupapicheck`
Job, which failed (`BackoffLimitExceeded`) while cert-manager itself was healthy
(three pods `1/1 Running`, six CRDs installed). So the install never reached
issuance, and the inventory records "TLS issuance remains BLOCKED, not
qualified". The next boundary (why the startup check fails) is owned by the GCP
agent and is a platform-install issue, not this finding's subject. Unchanged: no
Cloud DNS solver exists, and a GCP target declaring `cluster_issuer` is refused
by name.

## Supersession

None.
