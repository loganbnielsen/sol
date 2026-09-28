---
id: FND-0068
type: audit-finding
severity: high
source: GCP qualification Attempt 17 (2026-09-28), revision 30ad9835
---

# Sol reports `Ready` while the platform's own certificates never issue

**Depends on:** None.

**State:** `OPEN` — the observation is established and the choice is put to `DEC-056`. Nothing was
changed: the readiness contract is a product semantic, and this unit deliberately did not move it.

## Observed (GCP qualification Attempt 17, 2026-09-28)

The lifecycle reported **`lifecycle phase: Ready`** while both certificates the platform had created for
itself were `READY=False`, their ACME challenges pending and permanently failing:

```text
kubectl get certificates -A
argocd      argocd-tls    False   argocd-tls    14m
monitoring  grafana-tls   False   grafana-tls   14m
```

`sol cloud apply` had completed its whole readiness gate before reporting `Ready` — the phase line is
printed only after every check passes, and the command *refuses* otherwise:

```ocaml
let summary = Sol_cli_cloud_lifecycle.readiness_summary (deps.await_readiness env) in
let* () = if summary = "Ready" then Ok () else Error (Refused ("platform readiness " ^ summary)) in
```

## What `Ready` currently promises, and where

The executable contract is `Sol_cli_cloud_lifecycle.readiness_checks ~provider`, run by
`await_platform_readiness`: every 15 s, up to `SOL_PLATFORM_READINESS_TIMEOUT_S` (default 900 s), and
refused if any check is still `Unmet` at the deadline. The checks are:

| check | what it asserts |
|---|---|
| cert-manager CRDs, cert-manager controllers | the CRDs are Established and controller/webhook/cainjector run |
| nodes | every node is `Ready` |
| default StorageClass, block-storage CSI driver | the provider's storage mechanism is present |
| monitoring deployments / statefulsets / daemonsets / PVCs | the observability stack runs and its volumes bind |
| Redpanda, Redpanda statefulset, Redpanda PVCs | the broker executes `rpk cluster health` successfully and its replicas and volumes are up |
| ingress-nginx | the controller runs **and its LoadBalancer has an assigned endpoint** |
| Argo CD | its controllers run |

So `Ready` promises *"the platform's components are installed, running, and addressable"*. Nothing in
that list is about a certificate being issued, or about the platform's own HTTPS endpoints serving a
trusted chain.

## Why this is a product-semantic choice and not a missing check

Three facts, each observed or executable:

1. **The platform always asks for certificates.** The shared module sets
   `cert-manager.io/cluster-issuer = var.cluster_issuer` on the Argo CD and Grafana ingresses
   unconditionally, and the GCP root's `cluster_issuer` defaults to `letsencrypt-prod`. Attempt 17's
   target declared no issuer and the platform still created `argocd-tls` and `grafana-tls`.
2. **There is no supported "no TLS" mode.** The GCP driver's refusal used to tell operators to
   *"remove `cluster_issuer` from the target to provision the platform without public TLS"*, but removing
   it changes only which issuer name the ingresses reference — the ingresses, the certificates and the
   issuer dependencies are all still created. That sentence described a mode the platform does not have.
3. **Certificate issuance depends on the outside world.** With `create_dns_zone = true` the platform
   creates the zone and publishes its nameservers, and DNS-01 cannot validate until the operator
   publishes those NS records at the registrar. A readiness check that waited for a certificate would
   refuse `Ready` for a platform that is correctly installed and waiting on a human — a different failure
   from the one this finding is about.

Making `Ready` require the platform's certificates therefore means deciding *how much of the outside
world the lifecycle waits for*, and it interacts with (2): the honest version of "no TLS" is a platform
that creates no TLS ingresses at all, which does not exist yet.

## The alternatives (for `DEC-056`)

1. **Leave `Ready` as it is, and report certificate state separately.** `Ready` keeps meaning "components
   installed and addressable"; a `sol status`/`open` view and the qualification ledger carry the TLS
   claim, and the "without public TLS" sentence in the driver is either removed or made true. Cheapest,
   and keeps the lifecycle's promise exactly what it already is.
2. **Include the platform's declared certificates in `Ready`.** Add a readiness check that every
   Certificate the platform declares becomes `Ready=True` within the gate's budget. A cluster that cannot
   issue is then never `Ready`, which is what attempt 17's operator would have wanted — at the cost of
   refusing `Ready` while a delegation is still propagating (fact 3), and of making the platform's
   external dependency part of the lifecycle's failure surface.
3. **Make "without public TLS" real, then gate on it.** Introduce a supported configuration in which the
   platform creates no TLS ingress at all; then `Ready` requires certificate readiness exactly when the
   target asks for TLS. This is the only option that makes the old refusal sentence accurate, and it is
   the largest change: it alters what the shared module renders.

**Explicit non-goal for whoever picks this up:** do not make certificate issuance a precondition of the
*install* (the platform apply), only of the readiness claim, and do not weaken the existing checks —
attempt 17's `Ready` was correct about every component it already covers.

## Impact

A platform can be reported `Ready` — and an operator can act on that — while every HTTPS endpoint it
declares serves an untrusted certificate. In Attempt 17 that was `argocd.qual-gcp.sol-fab.dev` and
`grafana.qual-gcp.sol-fab.dev`, i.e. the platform's own operator-facing surface.

## Acceptance criteria

- The decision is recorded with its rationale and the evidence above.
- Whichever option is chosen, a lifecycle claim of `Ready` and the platform's own certificate state can
  no longer disagree without the run saying so, and the choice has executable coverage (a readiness
  check, or a reported status, or a supported no-TLS configuration).
- If option 2 or 3 is chosen, the delegation case is handled explicitly: an operator's unpublished NS
  records must not read as a broken platform.
