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
