---
id: REFAC-024
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-024/extract-kafka-conf-builder
worktree: /home/lbendtly/Code/sun-REFAC-024-extract-kafka-conf-builder
---

Extract Kafka config builder to eliminate near-duplicate `conf_of_config` in producer and consumer

**Depends on:** None.

**Description:**

`kafka_producer.ml` and `kafka_consumer.ml` each implement a `conf_of_config` function with the same structure: create a `Kafka_raw.kafka_conf`, accumulate the first error in a `ref`, define a local `set` helper that short-circuits on error, apply a list of `(key, value)` pairs, then return `Ok conf | Error msg`:

| File | Lines | Unique keys set |
|------|-------|-----------------|
| `kafka-eio-producer/lib/kafka_producer.ml` | 35–61 | `bootstrap.servers`, security, `linger.ms`, `acks` |
| `kafka-eio-consumer/lib/kafka_consumer.ml` | 51–76 | `bootstrap.servers`, security, `group.id`, `auto.offset.reset`, `partition.assignment.strategy` |

The scaffolding (22 of the ~26 lines) is identical. Only the key list differs.

**Remediation:**

Add a builder to `integrations/kafka/kafka-eio-core/lib/kafka_conf.ml` (new file):

```ocaml
(* Apply a list of key-value pairs to a fresh Kafka conf object.
   Returns Error on the first failed set. *)
val build : (string * string) list -> (Kafka_raw.kafka_conf, string) result
```

Implementation:
```ocaml
let build pairs =
  let conf = Kafka_raw.conf_new () in
  let first_err = ref None in
  let set k v =
    if !first_err = None then
      match Kafka_raw.conf_set conf k v with
      | `Ok -> ()
      | `Err msg -> first_err := Some (Printf.sprintf "Kafka conf_set %s: %s" k msg)
  in
  List.iter (fun (k, v) -> set k v) pairs;
  match !first_err with
  | Some msg -> Error msg
  | None     -> Ok conf
```

Then `kafka_producer.ml` and `kafka_consumer.ml` each build their specific `(key, value)` list (including the `Kafka_security.to_pairs` output) and call `Kafka_conf.build`.

Add `kafka_conf` to `kafka-eio-core`'s dune `modules` stanza. Both producer and consumer already depend on `kafka-eio-core`.

**Acceptance criteria:**

- `kafka_producer.ml` and `kafka_consumer.ml` contain no local `conf_of_config` definitions.
- `Kafka_conf.build` is the single place that calls `Kafka_raw.conf_new` and `Kafka_raw.conf_set`.
- `dune build` passes.
- Integration tests pass with a live broker.

## Review — automated checks passed
conf_of_config boilerplate extracted to Kafka_conf.build; producer and consumer delegate cleanly; build passes
