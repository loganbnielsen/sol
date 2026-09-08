---
id: REFAC-007
branch: REFAC-007/kafka-conf-builder
worktree: /home/lbendtly/Code/sun-REFAC-007-kafka-conf-builder
type: refactor
severity: low
source: codebase simplification review 2026-06-15
---

Deduplicate `conf_of_config` Kafka config builder in producer and consumer

**Depends on:** None.

**Description:**

`kafka_producer.ml` and `kafka_consumer.ml` each implement an identical `conf_of_config` scaffold — the same `first_err ref` accumulator pattern, the same `set k v` helper, and the same `Kafka_security.apply` call:

- `integrations/kafka/kafka-eio-producer/lib/kafka_producer.ml:35–61`
- `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml:51–76`

The only difference is which keys each file sets (`linger.ms`, `acks`, `transactional.id` for the producer; `group.id`, `auto.offset.reset`, `enable.auto.commit`, `partition.assignment.strategy` for the consumer). The error-accumulation scaffold around `Kafka_raw.conf_set` is byte-for-byte the same.

A bug in that scaffold (e.g. missing the `if !first_err = None` guard on the security branch) must be found and fixed in two places.

**Remediation:**

1. Add to `integrations/kafka/kafka-eio-core/lib/` a new file `kafka_conf_builder.ml` (and `.mli`):
   ```ocaml
   (* Returns (set, finalize).
      [set k v] applies the key-value pair to [conf], recording the first error.
      [finalize ()] returns Ok conf or Error <first_error>. *)
   val make : unit ->
     Kafka_raw.kafka_conf *
     (string -> string -> unit) *
     (unit -> (Kafka_raw.kafka_conf, string) result)
   ```
   The implementation is the existing `first_err ref` / `set` / final-match logic extracted verbatim.
2. Register `Kafka_conf_builder` in the `kafka-eio-core` dune library stanza.
3. In `kafka_producer.ml`, rewrite `conf_of_config` to call `Kafka_conf_builder.make ()` for the scaffold, keeping only the producer-specific `set` calls.
4. Do the same in `kafka_consumer.ml`.

**Acceptance criteria:**

- Neither `kafka_producer.ml` nor `kafka_consumer.ml` contains a local `first_err` ref or a local `set` closure.
- `dune build && dune test integrations/kafka/` passes.

## Review — automated checks passed
Deduplication of conf_of_config is clean: kafka_conf_builder.{ml,mli} added to kafka-eio-core, producer and consumer delegate to Kafka_conf_builder.make(), build and tests pass, no ticket-directory changes, (wrapped false) preserved.

## Review — automated checks passed
All acceptance criteria met. kafka_conf_builder.ml and .mli exist and are committed. dune lists kafka_conf_builder in modules. No local conf_of_config in producer or consumer. Both files call Kafka_conf_builder.make() directly. Build clean. project/tickets untouched.
