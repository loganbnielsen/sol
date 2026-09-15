---
id: INFRA-018
type: feature
severity: medium
title: Run the first-class TypeScript framework suites in CI (pinned broker)
source: DEC-022 (TypeScript is first-class) — the CI asymmetry surfaced while
  reviewing FEAT-081
---

**Depends on:** None.

**Related:** DEC-022, FEAT-034, FEAT-035, FEAT-038, FEAT-039, FEAT-081.

Run the first-class TypeScript application-framework tests in CI. Today CI runs
**zero** TypeScript tests: the OCaml `test` job is `dune`-only, and
`demo-ts-dockerfile-smoke` only does `docker build`. So the `@sol/kafka` /
`@sol/obs` suites — including FEAT-081's broker-backed retry/DLQ
ownership-transfer tests — are local-only evidence. Under DEC-022 ("OCaml and
TypeScript are both first-class application languages") that is inconsistent
with the decision: a first-class language's tests must gate CI.

The invariant is "first-class language framework tests run in CI". Redpanda is
test *infrastructure* for the broker-backed tests, not the point of the ticket.

## Remediation

Add a `ts-tests` GitHub Actions job (ubuntu, Node 22) with **separate steps**, so
a broker/infrastructure failure is distinguishable from a TypeScript
build/unit failure:

1. `npm ci` (workspace install).
2. Build/typecheck: `npm run build -w @sol/obs -w @sol/kafka -w order-svc -w fulfillment-worker`.
3. Ordinary suites, no broker: `npm test -w @sol/obs -w @sol/kafka` (the three
   broker-backed tests self-skip without `KAFKA_BROKERS`).
4. Start a **pinned** Redpanda container (specific tag — never `:latest`) on
   port 9092.
5. Wait on a **real readiness operation** (e.g. `rpk cluster info` inside the
   container), not merely a TCP accept, with a bounded timeout and a log dump
   on failure.
6. Run `@sol/kafka` with `KAFKA_BROKERS=localhost:9092` to exercise the
   broker-backed tests.

Only Kafka (9092) is needed — the integration tests do not touch the schema
registry.

## Non-goals

- Not a change to FEAT-081 / PR #269 — landed independently (which then
  benefits from the new check on re-run).
- Not a general CI rework; no k3d/Helm.
- Not `@sol/*` publishing or distribution (DEC-023).

## Acceptance criteria

- A CI job runs the `@sol/obs` and `@sol/kafka` suites, including the
  broker-backed retry/DLQ tests, on PRs and pushes to `main`.
- Redpanda is a pinned image version; readiness is a real broker operation with
  a bounded timeout.
- A broker-startup failure is visibly distinct from a TypeScript build/unit
  failure.
- The job is not flaky in normal operation.
