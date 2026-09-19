---
id: INFRA-036
type: bug
severity: high
title: Gate Ready on platform convergence, not on a network probe or an external CA
source: HARDEN-002 Run 5 attempts 3 and 4 — a converged platform reported Unmet,
  and the readiness contract was settled in review
---

**Depends on:** INFRA-035 (the invalid invocations that hid this).

**Related:** ADR 0003 (the phase relation `Ready` licenses), HARDEN-002 (the run),
matrix row I14 (what `Ready` now asserts), INFRA-034 (the single-sample gate that
wrapped this).

## The contract (settled in review)

`sol cloud apply` reporting `Ready` answers one question: **has the platform
converged to its defined operational state?** Capability — *does the job actually
work under realistic behaviour and failure* — is HARDEN's question, answered with
behaviour, not with a route.

Two things the old gate required, and now must not:

- **API-server → pod/service reachability.** Five checks read native readiness
  endpoints through the API server's `/proxy/` path. Nothing in this platform
  creates that route: the EKS module admits the control plane to nodes only on the
  admission-webhook ports (4443/6443/8443/9443), and
  `node_security_group_additional_rules` defaults to `{}`. So `Ready` depended on
  a path the platform never promised, and a fully converged platform reported
  `Unmet`. The remedy is removing the probes — never widening a security group so
  that a test passes.
- **A successful external ACME round trip.** A `ClusterIssuer`'s only condition is
  `Ready` (observed live on attempt 4: one condition, `Ready=False`,
  `reason=ErrRegisterACMEAccount`), and for an ACME issuer cert-manager sets it
  only after registering with the external CA. So an unreachable — or merely
  unwilling — Let's Encrypt made a healthy, fully converged platform "not ready".
  Option (ii) from the review was preferred *provided* cert-manager exposes a clean
  authoritative local condition separating reconciliation from ACME. It does not:
  `Ready` is that same condition. Rather than invent a Sol-specific
  "Ready-lite", the review's fallback applies — remove issuer readiness from the
  gate and qualify real issuance in HARDEN.

## What gates Ready now

Authoritative Kubernetes convergence, and Redpanda's own health API:

| check | why it is convergence |
|---|---|
| cert-manager CRDs `Established` | the objects the platform needs exist |
| cert-manager Deployments `Available` | its own condition |
| nodes `Ready` | the cluster's own statement |
| default StorageClass `gp3` + EBS CSI driver registered | the storage the platform depends on |
| monitoring Deployments `Available` | their own condition |
| monitoring StatefulSets / DaemonSets every declared replica ready | status, per kind |
| monitoring PVCs `Bound` | storage actually attached |
| Redpanda broker-native cluster health (`rpk cluster health`) | the platform's own health API — no third party, and `kubectl exec` uses the kubelet path, not `/proxy/` |
| Redpanda StatefulSet + PVCs | status, per kind |
| ingress-nginx Deployments `Available`; LoadBalancer endpoint assigned | its own condition plus the cloud-side assignment |
| Argo CD Deployments `Available` | its own condition |

The gate is also **backend-independent**: monitoring is checked namespace-wide, so
it asserts "everything installed here converged" whatever the observability
backend installed. That removes the `observability_backend` and `cluster_issuer`
parameters entirely — both were backend-shaped distinctions inside a gate whose
only job is convergence.

Workload convergence is read **per kind**, because kinds differ in what they
declare: a DaemonSet's desired count is derived from the node set, so zero means
nothing matched; a StatefulSet's replicas are declared by its owner, so a declared
zero is a choice, not a failure.

## Acceptance criteria

- No readiness check reads a service or pod endpoint through the API server's
  `/proxy/` path, and none requires a `ClusterIssuer` condition.
- A converged platform reports `Ready` with an unreachable external ACME provider.
- Convergence predicates fail closed on empty output, and the kind distinction
  above is pinned by tests.
- The gate takes no backend/issuer parameters.
- The behaviour the removed probes gesturing at is qualified in HARDEN — a known
  log reaching Loki and being queryable, and the equivalent for metrics, traces,
  ingress, the broker, TLS issuance, alerts, and RDS failover.
- Matrix row I14 states the contract and its evidence; the Run 5 procedure states
  it where an operator will read it.
- Offline gate green: unit tests, the lifecycle harness, the real-kubectl argv
  guard, `dune fmt --preview`, the guard set, `check_production_infra.sh`.

## Deliberately not decided here

`ClusterIssuer` genuinely not being ready is now invisible to `Ready`. That is the
review's explicit trade: readiness must not depend on a third party, and HARDEN
qualifies issuance. The run's evidence should therefore make issuer state visible
*without* gating on it — the read-only inspection the procedure now requires.

**Demo/example coverage:** No example change.

**TypeScript parity:** No language-parity impact.
