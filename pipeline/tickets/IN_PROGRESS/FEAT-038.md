---
id: FEAT-038
type: feature
severity: medium
source: dogfood pass following FEAT-034/035, 2026-09-08
branch: FEAT-038/dogfood-ts-packages
worktree: ../sol-FEAT-038-dogfood-ts-packages
---

**Depends on:** FEAT-034 (done), FEAT-035 (done).

Dogfood `@sol/kafka` and `@sol/obs` by migrating `examples/pluto/app/demo_ts` onto them, and iterate on the packages based on real friction.

## Why

`@sol/kafka` and `@sol/obs` were built against FEAT-033's findings (a hand-rolled TS port's real bugs), but neither has actually been used by a real consumer yet — they've only been tested in isolation. The whole point of building them in-tree first (matching this repo's kafka-eio/obs-eio/pg-eio precedent) is to prove the API against a real consumer before it's considered settled. `examples/pluto/app/demo_ts/{order_svc,fulfillment_worker}` is that consumer: it already hand-rolls exactly what these packages are meant to replace (`schemaRegistry.ts`, `metrics.ts`, `tracing.ts`, `loki.ts`, `wire.ts` in both services).

## Scope

1. Migrate `order_svc` and `fulfillment_worker` to import from `packages/sol-kafka` and `packages/sol-obs` instead of their own hand-rolled equivalents. Delete the hand-rolled files once the migration is confirmed working — don't leave dead duplicate code alongside the new imports.
2. Resolve the known open interim state: `@sol/kafka`'s `tracing.ts` currently duplicates `@sol/obs`'s traceparent helpers (documented on both sides as temporary, pending this exact migration). Decide and implement the real answer — most likely `@sol/kafka` depends on `@sol/obs` and re-exports/re-uses its helpers rather than keeping its own copy.
3. Run the full demo live, end to end, against real local infrastructure: svc → Kafka (schema registry + trace propagation) → worker → Postgres → Loki/Prometheus/Tempo/Grafana. This is the actual proof the packages work in practice, not just against their own unit tests.
4. Treat any real friction found during migration or the live run as legitimate grounds to revise the packages (API awkwardness, a missing convenience, a bug the package didn't actually prevent) — don't just work around problems in the demo code. Document what changed and why.
5. Once migrated and live-verified, do an adversarial/showcase-quality pass (the `demo-review` skill fits this, or a straightforward critical read) — the bar is "would we actually show this off to demonstrate the framework," not just "does it technically run."

## Acceptance criteria

- `order_svc`/`fulfillment_worker` import Sol's conventions from `packages/sol-kafka`/`packages/sol-obs`, not hand-rolled per-service files.
- No duplicate/dead hand-rolled convention code left behind once the migration is confirmed working.
- Traceparent-helper duplication between the two packages is resolved, not left open.
- A real live run of the full demo (not a mocked/unit-test-only check) is exercised and its outcome documented — screenshots/logs are not required, but the ticket should record what was actually run and what it showed (e.g. Grafana panels populated correctly, traces linked svc→worker, DLQ/retry behavior observed if exercised).
- Any real packages-level fix found during dogfooding is implemented (small ones inline; anything larger gets its own follow-up ticket, referenced here).
