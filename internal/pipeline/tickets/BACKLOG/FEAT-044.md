---
id: FEAT-044
type: feature
severity: low
source: architecture discussion 2026-09-09 (workspace direction review)
---

**Depends on:** None.

Explore adding a caching primitive (e.g. Redis-compatible) as a first-class platform component, if and when a real workload demonstrates the need.

## Problem

There is no cache of any kind in the stack (`rg -i "redis|memcached|elasticache" docs cli framework packages` → no hits). The framework's shared-state story is Postgres plus Kafka, so a latency-sensitive read path has to hand-roll a cache together with its connection config, security, and observability. That is exactly the "DevOps expertise, not engineering judgment" work Sol exists to remove.

However, caching is only worth building against a measured need, and adding a component touches config, transport security, metrics/logs/tracing, the local dev substrate, and the Helm/infra modules — a medium-sized change with no current evidence behind it.

## Goal

Decide whether and when a cache component is warranted, and if so, scope it consistently with the existing platform components.

## Remediation

- Gather demand evidence: a concrete workload or benchmark showing Postgres latency/load is the bottleneck before adding a component.
- If built, model it like the other platform components (config, TLS/auth, metrics, Loki/Tempo labels, `sol dev up` provisioning, durable-storage toggle) plus a small framework client.
- Respect "explicit over implicit": no automatic caching of database calls; caching is something the developer asks for.
- File a DEC ticket if the answer is ambiguous.

## Acceptance criteria

- Either demand evidence exists and a scoped implementation ticket is filed, or a DEC ticket documents why caching is deferred.
- No component is added under this ticket.

## Disposition (2026-10-03) — decision required

Smallest decision: is a Redis-compatible cache primitive in scope for the alpha, and against what demand evidence? Options: the ticket's own gate — demand evidence before adding a component — or declare it out of scope. Consequence: a component touches config, transport security, observability, local dev substrate and Helm/Terraform.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
.


## Decision (2026-10-03) — out of the alpha

Operator decision: **None — declare all out of the alpha.** No cache primitive is
added for the current alpha. Deferred with a trigger rather than closed:
reconsider when a concrete workload or benchmark shows Postgres latency or load
is the bottleneck and a cache is the demonstrated fix.

Reconsideration trigger: measured demand evidence (a workload/benchmark) that a
cache is required, at which point the component is scoped like the other
platform components (config, TLS/auth, metrics, Loki/Tempo labels, `sol dev up`
provisioning, durable-storage toggle) plus a small framework client.
