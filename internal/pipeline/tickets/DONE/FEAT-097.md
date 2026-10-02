---
id: FEAT-097
type: feature
severity: medium
source: internal/pipeline/tickets/DONE/SEC-007.md
---

TypeScript: read and require the Kafka transport posture (`KAFKA_SECURITY_PROTOCOL`), matching `config_of_env`

**Depends on:** None.

**Language-parity tracking for:** SEC-007 (DEC-022 capability matrix: Kafka config/security).

## Problem

SEC-007 made the OCaml `Kafka_service.config_of_env` refuse a workload that does
not set `KAFKA_SECURITY_PROTOCOL`, and every Sol-rendered manifest now declares it
(`plaintext` today). The TypeScript path has no equivalent: the reference
`examples/pluto/app/demo_ts/order_svc/src/index.ts` and
`fulfillment_worker/src/index.ts` construct `new Kafka({ clientId, brokers })`
directly from `KAFKA_BROKERS`, and nothing reads `KAFKA_SECURITY_PROTOCOL`,
`KAFKA_SSL_*` or `KAFKA_SASL_*`. A TypeScript workload therefore ignores the
declared posture entirely — it would stay plaintext even when a manifest said
`sasl_ssl`.

Checked 2026-09-24: `rg -n 'KAFKA_SECURITY_PROTOCOL' --glob '*.ts' .` (excluding
`node_modules`) matches nothing, while the same search over `*.ml` matches
`kafka_service_config.ml` (positive control).

## Decision (2026-10-02)

**The helper lives in `@sol-fab/kafka`, as `kafkaConfigFromEnv()`.** The posture
is a Sol convention every TypeScript workload must apply, not an example detail
— an in-example helper is exactly how two workloads drift, and the package is
already the home of the Kafka policy (`registerTopic`, the wire format, DLQ). It
returns the kafkajs `ssl`/`sasl` client options and throws when a required
variable is absent or malformed, naming it, mirroring `config_of_env`.

## Remediation

Provide the env-to-kafkajs mapping with the same contract as `config_of_env`:
required `KAFKA_SECURITY_PROTOCOL` (plaintext | ssl | sasl_plaintext | sasl_ssl),
`KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_MECHANISM/USERNAME/PASSWORD`, an error naming
the variable when absent or malformed; switch both demo_ts workloads to it.

## Acceptance criteria

- Unit test: absent protocol throws, naming `KAFKA_SECURITY_PROTOCOL`.
- Both `examples/pluto/app/demo_ts` workloads build their kafkajs client from it.

## Done (2026-10-02)

**Premise checked.** Re-verified at `sol-kafka@3956fea`: nothing under
`examples/pluto/app/demo_ts` read `KAFKA_SECURITY_PROTOCOL`, `KAFKA_SSL_*` or
`KAFKA_SASL_*` (positive control: the same search over `*.ml` found
`kafka_service_config.ml`). Premise held.

**What landed.**
- `loganbnielsen/sol-kafka#4` (merged `b026ac8`) adds `kafkaConfigFromEnv()`,
  which requires `KAFKA_SECURITY_PROTOCOL` (absent or blank is an error naming
  it, never a plaintext default), reads `KAFKA_BROKERS`, maps the two TLS
  protocols to kafkajs `ssl` (with `KAFKA_SSL_CA_LOCATION` read as the `ca`, and
  an unreadable file failing closed), and the two SASL protocols to kafkajs
  `sasl` from `KAFKA_SASL_MECHANISM`/`USERNAME`/`PASSWORD`. Every error names
  the variable. Released as `@sol-fab/kafka@0.3.1` (tag `v0.3.1`).
- Both `demo_ts` workloads build their client with
  `new Kafka({ clientId, ...kafkaConfigFromEnv() })`, and both pins move to
  `^0.3.1` with the lockfile regenerated.

**Checks run.** `sol-kafka`: `npm run build` (`tsc`) clean; `npm test` → 73
tests, 0 fail (4 skipped: broker-bound integration), including a suite covering
the absent/blank/unknown protocol, missing SASL variables, the CA read and the
unreadable-CA failure. Demo: `npm run build -w order-svc -w fulfillment-worker`
clean against the published `0.3.1`.

**Demo/example coverage.** This ticket *is* the TypeScript example update; both
workloads consume the posture helper. `demo_ts/README.md` already documents the
injected `KAFKA_SECURITY_PROTOCOL=plaintext`.

**Language parity.** This is the parity fix for the Kafka config/security row:
a TypeScript workload now refuses to start without a stated posture, exactly as
`Kafka_service.config_of_env` does (SEC-007).

