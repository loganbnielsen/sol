---
id: REFAC-048
type: refactor
severity: medium
source: codebase simplification review 2026-06-16
branch: REFAC-048/extract-kafka-base-conf
worktree: ../sun-REFAC-048-extract-kafka-base-conf
---

Extract shared `conf_new`/`set` boilerplate into `Kafka_raw.make_base_conf`

**Depends on:** None.

**Description:**

Both `kafka-eio-producer/lib/kafka_producer.ml` (lines 35–61) and `kafka-eio-consumer/lib/kafka_consumer.ml` (lines 51–76) implement an identical `conf_of_config` skeleton:

1. Allocate conf with `Kafka_raw.conf_new ()`
2. Declare a `first_err ref`
3. Define a local `set k v` closure that gates on `!first_err = None`
4. Call `set "bootstrap.servers" ...`
5. Call `Kafka_security.apply conf security`
6. Return the conf and `first_err`

This is ~20 lines duplicated across two packages. The only difference is consumer-specific keys (`group.id`, `auto.offset.reset`, etc.) added after the shared preamble.

**Remediation:**

1. Add to `integrations/kafka/kafka-eio-core/lib/kafka_raw.ml`:
   ```ocaml
   val make_base_conf :
     brokers:string list -> security:Kafka_security.t ->
     (kafka_conf * (string option ref), string) result
   ```
   It handles `conf_new`, `set "bootstrap.servers"`, `Kafka_security.apply`, and the `first_err` pattern, returning the conf and the `first_err` ref (so callers can continue setting keys with the same guard).
2. Expose it in `kafka_raw.mli`.
3. Refactor `conf_of_config` in both `kafka_producer.ml` and `kafka_consumer.ml` to call `make_base_conf` and only add their own keys on top.

**Acceptance criteria:**

- The `conf_of_config` functions in both files are ≤15 lines each.
- `dune build integrations/kafka/` and `dune test integrations/kafka/` pass.

## Review — automated checks passed
make_base_conf extracted to kafka_security.ml; both conf_of_config callers correctly delegate to it; build clean; cooperative-sticky comment preserved; no ticket files touched in implementation commit
