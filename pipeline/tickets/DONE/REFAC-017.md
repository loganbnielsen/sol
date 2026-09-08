---
id: REFAC-017
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-017/decompose-kafka-service
worktree: /home/lbendtly/Code/sun-REFAC-017-decompose-kafka-service
---

Decompose kafka_service.ml (679 lines, 6 concerns) into focused sub-modules

**Depends on:** None.

**Description:**

`integrations/kafka/kafka-eio-service/lib/kafka_service.ml` is 679 lines and mixes six unrelated concerns. Any change to one area requires reading past unrelated code, and the file shows up as a single monolith in editor navigation:

| Concern | Approximate lines |
|---------|------------------|
| HTTP client helpers (`http_do`, `http_do_json`) | 99–148 |
| Schema registry client (register, lookup, `decode_wire`) | 150–291 |
| Environment-based config (`config_of_env`) | 297–311 |
| `consume` — simple no-retry path | 313–441 |
| `consume_partitioned` — in-memory retry variant | 443–570 |
| `consume_partitioned` — retry-topics variant | 571–679 |

**Remediation:**

Split into focused files within `integrations/kafka/kafka-eio-service/lib/`:

1. **`kafka_service_http.ml`** — `http_do` and `http_do_json` (the two internal HTTP helpers). No public signature needed; used only within the service package.

2. **`kafka_service_schema.ml`** — Schema registry client: `register_schema`, `lookup_schema`, `decode_wire`. Confluent wire format codec (`Confluent_wire`) is already a sub-module; move it here too.

3. **`kafka_service_config.ml`** — `config_of_env` and related environment-variable reading.

4. **`kafka_service.ml`** — Keep only the public `consume` and `consume_partitioned` functions (~150 lines). They call into the above modules.

No public API changes — all exported names stay the same. This is a pure file split.

**Acceptance criteria:**

- `kafka_service.ml` is ≤200 lines after the split.
- Each new sub-module file has a single clear responsibility.
- No changes to the public `.mli` (if one exists) or to any module signatures visible outside `kafka-eio-service`.
- `dune build` passes.
- All Kafka integration tests pass (`KAFKA_BROKERS=localhost:9092 dune test integrations/kafka/ --force`).

## Review — returned for revision
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:442` — kafka_service.ml is 442 lines, exceeding the ≤200-line acceptance criterion
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml:64` — config_of_env and env-var reading remain in kafka_service.ml; the spec requires them extracted to kafka_service_config.ml
- `integrations/kafka/kafka-eio-service/lib/:0` — kafka_service_config.ml was not created; the remediation explicitly requires this file for config_of_env

## Review — automated checks passed
kafka_service.ml decomposed to 196 lines with four focused sub-modules; build clean, mli unchanged, no ticket dir touched
