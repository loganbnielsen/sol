# Third-party components Sol installs and depends on

Sol's own licence (Apache-2.0) says nothing about the software Sol deploys *for*
users. This is the inventory of what the platform modules install, which licences
apply, and where those terms interact with Sol's own product decisions.

**Status:** first pass, covering what `platform/infra/base` and `sol dev up`
install. The opam and npm dependency graphs are not yet inventoried — see
[Not yet inventoried](#not-yet-inventoried).

## Deployed components

| Component | Chart | Software licence | Notes |
| --- | --- | --- | --- |
| cert-manager | `cert-manager` | Apache-2.0 | |
| ingress-nginx | `ingress-nginx` | Apache-2.0 | |
| Argo CD | `argo-cd` | Apache-2.0 | GitOps mode |
| **Redpanda** | `redpanda` *(chart: Apache-2.0)* | **BUSL-1.1** | The chart's licence is not the broker's. See below. |
| PostgreSQL | `postgresql` (Bitnami, Apache-2.0) | PostgreSQL Licence | Chart is open source; the image channel changed in 2025. See below. |
| **Grafana** | `grafana` | **AGPL-3.0** | |
| **Loki** | `loki` | **AGPL-3.0** | |
| **Tempo** | `tempo` | **AGPL-3.0** | |
| Alloy | `alloy` | Apache-2.0 | Grafana's collector, but not AGPL. |
| Prometheus | `prometheus` | Apache-2.0 | |
| Pushgateway | `prometheus-pushgateway` | Apache-2.0 | dev only |
| Thanos | `thanos` (Bitnami) | Apache-2.0 | durable-observability path |

## Three that need a decision, not a footnote

### 1. Redpanda is BUSL-1.1, and the hosted tier may need a commercial licence

Redpanda's Helm chart is Apache-2.0, but the broker it deploys is under the
**Business Source License 1.1** — source-available, not OSI open source. BUSL
permits most internal and production use, but generally **prohibits offering the
software as a hosted or managed service to third parties** without a commercial
agreement.

Sol's event layer is built on it, and DEC-008 has Sol running customer
infrastructure inside Sol's own account — which is exactly the shape BUSL is
written to restrict. **This needs a legal read before the hosted tier is sold.**
The fallback is knowable rather than hypothetical: Apache Kafka (Apache-2.0)
behind the same interface, since Sol's applications talk to Kafka through the
schema registry contract rather than to Redpanda specifically.

### 2. The Bitnami image channel changed in 2025

The Bitnami PostgreSQL *chart* is still Apache-2.0, and PostgreSQL is under the
PostgreSQL Licence — but the free, maintained `bitnami/*` images were retired:
existing tags moved to `bitnamilegacy/*` (unmaintained, no CVE fixes, liable to
disappear) and updated images became subscription-based (Bitnami Secure Images).

That is a **supply-chain and currency risk, not a licence one**: whichever tags
Sol pins today are likely frozen on an unsupported image. Worth deciding
deliberately — the official `postgres` image, CloudNativePG, or Crunchy — rather
than inheriting whatever the chart defaults to.

### 3. AGPL in the observability stack

Grafana, Loki and Tempo are **AGPL-3.0**. Deploying them into a cluster the
customer owns and operates is normally straightforward: Sol does not modify them,
and the customer is the user. **Hosting them on a customer's behalf** is the case
AGPL §13 addresses, so it belongs in the same review as Redpanda — and it is
independent of the licence Sol's own code carries.

## Verifying a component

Chart licence — which is *not* necessarily the software's:

```bash
helm show chart <repo>/<chart> | grep -i license
```

For the software, check the project's own `LICENSE` and how its container image
is distributed and supported. Redpanda is the live example of the two differing.

## Not yet inventoried

- **OCaml (opam) and npm dependencies.** No licence scan runs in CI. This needs
  doing before either is published externally, since distribution is what
  triggers licence obligations.
- **Base images in generated Dockerfiles.**
- **Vendored or adapted code** inside `examples/` or `integration/` that may
  originate elsewhere.
