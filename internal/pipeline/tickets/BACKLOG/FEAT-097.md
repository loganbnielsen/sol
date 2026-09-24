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

## Decision Required

Where the helper lives: `@sol-fab/kafka` (github.com/loganbnielsen/sol-kafka)
exporting a `kafkaConfigFromEnv()` that returns kafkajs `ssl`/`sasl` options and
throws on an absent protocol, or a thinner in-example helper until the package
grows a config surface.

## Remediation

Provide the env-to-kafkajs mapping with the same contract as `config_of_env`:
required `KAFKA_SECURITY_PROTOCOL` (plaintext | ssl | sasl_plaintext | sasl_ssl),
`KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_MECHANISM/USERNAME/PASSWORD`, an error naming
the variable when absent or malformed; switch both demo_ts workloads to it.

## Acceptance criteria

- Unit test: absent protocol throws, naming `KAFKA_SECURITY_PROTOCOL`.
- Both `examples/pluto/app/demo_ts` workloads build their kafkajs client from it.
