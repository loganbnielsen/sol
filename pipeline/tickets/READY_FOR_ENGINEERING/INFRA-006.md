---
id: INFRA-006
type: feature
severity: low
source: architecture discussion 2026-09-09 (ingress/egress cost review, Cloudflare edge question)
---

**Depends on:** None.

Prove the self-hosted substrate contract is satisfiable on a cheap Kubernetes provider, and document the recipe end to end — including the credential story for DNS/TLS without cloud IAM.

## Problem

`docs/deployment/self-hosted-substrate-contract.md` promises "any CNCF-conformant cluster", and `sol deploy` consumes whatever substrate exists — but the only *validated* substrates today are the `platform/infra/aws` and `platform/infra/gcp` modules and local k3d. Meanwhile the AWS baseline is expensive for what it buys: EKS control plane ≈ $73/mo per cluster, internet-facing ALB ≈ $16.4/mo plus public IPv4 ≈ $7.3/mo, and ~$0.09/GB egress. Cheap managed-Kubernetes providers have free control planes and nodes from ~$5/mo, and egress allowances that are one to two orders of magnitude larger (Hetzner includes 20 TB per node; Oracle gives 10 TB/mo free).

Nothing in the repo has verified that the contract's required inputs — reachable cluster, registry prefix, Kafka + schema registry, Postgres connection secret, observability endpoints, optional base domain/TLS — can actually be assembled there.

## Goal

A documented, verified recipe: one cheap provider, one real `sol deploy` + `sol migrate` run against it, and an honest cost table, so `sol deploy` on a cheap substrate is a known quantity rather than an assumption.

## Remediation

- Prefer a **Cilium- or Calico-backed** provider (DOKS, Linode LKE, Scaleway Kapsule) for the first recipe. The cheap tier is disproportionately k3s-based (e.g. Civo), and k3s means kube-router, which does not honour the generated `namespaceSelector` policies — see BUG-022. If a k3s-based target is chosen deliberately, say so and note that BUG-022 must land first.
- Stand up the cluster and satisfy each contract input, recording what was easy and what needed a workaround (registry prefix, Kafka/schema registry, Postgres secret, observability endpoints, base domain).
- Pay attention to the **IAM-shaped gap**: the AWS module supplies cert-manager DNS-01 credentials via IRSA. Cheap providers have no equivalent, so document the token-in-Secret path for whichever DNS provider is used.
- Run `sol deploy` and `sol migrate` for real; capture the output.
- Record a cost table (control plane, nodes, load balancer, block storage, egress) next to the AWS baseline above, at a stated scale — not just "cheaper".

## Acceptance criteria

- A reader can stand up the substrate and complete `sol deploy` + `sol migrate` from the recipe alone.
- The recipe states the DNS/TLS credential path in the absence of cloud IAM.
- The recipe includes a cost comparison against the `platform/infra/aws` baseline at a stated size, with the egress assumptions made explicit.
- The BUG-022 interaction is stated if a k3s-based provider is used.

## Notes

- Sol's own non-production environments are the lowest-risk first consumer; a customer-facing hosted shape is a separate decision, made with the hosted platform (DEC-019).
- This is deliberately a recipe plus a verification run, not a new provider Terraform module: user-facing provider breadth is already covered by the bring-your-own-cluster path (`self-hosted-substrate-contract.md`, "Pulumi / CloudFormation / Other IaC").
- Related: BUG-022 (dev-substrate policy gap), DEC-008 (hosted tenancy).
