---
id: AUDIT-068
type: audit-finding
severity: high
source: pipeline/audits/2026-09-16_audit.md
---

**Depends on:** None.

# Refresh the TypeScript showcase's deprecated and vulnerable dependencies

`npm ci` for `examples/pluto/app/demo_ts` installs deprecated
`prom-client@15.1.3`; npm directs users to `@prometheus-io/client`. `npm audit`
also reports 11 OpenTelemetry advisories (9 moderate, 2 high), including the
malformed-Jaeger-header denial of service. The fixed OTel graph requires moving
from the 1.30/0.55 generation to the current compatible 2.x/0.22x generation,
so `npm audit fix --force` is not an acceptable unreviewed fix.

## Acceptance criteria

- Both demo units use `@prometheus-io/client`; no `prom-client` dependency,
  import, lock entry, comment, or README claim remains.
- OpenTelemetry packages are upgraded as one compatible set and `npm audit`
  reports no high-severity production vulnerability.
- `npm ci` and both workspace builds pass without deprecation warnings.
- Metric exposition/Pushgateway behavior and cross-service trace propagation
  are exercised by the existing focused checks or the TS golden-path smoke.
- CI runs a dependency advisory check so future high-severity drift fails visibly.

## Demo/example coverage

This ticket directly updates the runnable TypeScript showcase.

## TypeScript-parity note

TypeScript-only dependency maintenance; the cross-language metric and tracing
contracts must remain unchanged.

## Completion (2026-09-22)

`prom-client` → **`@prometheus-io/client@^0.16.1`** in both demo units (the
deprecation npm reports is literal: "prom-client has been replaced by
@prometheus-io/client"), and OpenTelemetry moved as **one compatible set**:
`api ^1.9.1` (the peer range on `sdk-trace-node` is `>=1.0.0 <1.10.0`, so 1.9.x is
the ceiling), `sdk-trace-base`/`sdk-trace-node`/`resources ^2.11.0`,
`semantic-conventions ^1.43.0`, `exporter-trace-otlp-http ^0.222.0` — the
2.x/0.22x generation the ticket named.

**The upgrade needed exactly one source change, and typecheck found it rather than a
guess.** OTel 2.x turned `Resource` into a type: `new Resource({...})` in both
`tracing.ts` files became `resourceFromAttributes({...})` (TS2693 — "only refers to
a type, but is being used as a value"). Everything else — `spanProcessors`,
`provider.register()`, `shutdown()`, `OTLPTraceExporter`, the `ATTR_SERVICE_NAME`
constant — is unchanged in 2.x. Nothing else needed editing in the metric or trace
paths, so the cross-language contract is untouched.

**Verified, each with the command that shows it:**

| Check | Result |
|---|---|
| `npm ci` from the regenerated lock, in a clean tree | passes, **zero deprecation warnings** in the output |
| both workspace builds (`tsc --noEmit`) | pass |
| `npm audit` | **0 vulnerabilities** (was 11 advisories, 2 high) |
| `npm audit --omit=dev --audit-level=high` | 0 — the bar CI now enforces |
| `rg prom-client` across the demo (deps, imports, lock, comments, README) | no hits; the README never claimed it (checked, not assumed) |
| runtime smoke of the exposition API | `Counter`/`Histogram` render in Prometheus text format under the Sol metric names, and `Pushgateway` constructs with `pushAdd` |

The runtime smoke was run locally on purpose: the types could agree while the
exposition path misbehaved, and that path is what the metric contract rests on. The
lockfile shrank by ~476 lines — the 2.x graph is consolidated, not larger.

**AC5 — CI now fails on high-severity drift.** A `Dependency advisories (AUDIT-068)`
step sits in the `ts-tests` job after the build, running `npm audit --omit=dev
--audit-level=high`. Production dependencies only, and only high or above, both
deliberately: that is the bar this ticket was filed against, and gating on *all*
severities would let a moderate advisory in a devDependency block unrelated work.

**AC4 — behavioural coverage.** The metric and trace paths are exercised end to end
by the CI golden path (`golden-path-smoke-ts`: deploy `demo_ts` to a real cluster,
assert `Ready` and `/healthz`, run one real transaction through Kafka into Postgres,
with trace propagation across the two services). Because this change touches
`demo_ts`, that job runs on this PR rather than being argued from the diff.
