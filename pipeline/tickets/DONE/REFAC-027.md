---
id: REFAC-027
type: refactor
severity: low
source: codebase simplification review 2026-06-15
branch: REFAC-027/kafka-test-helpers
worktree: /home/lbendtly/Code/sun-REFAC-027-kafka-test-helpers
---

Consolidate Kafka test broker config into a shared test utility module

**Depends on:** None.

**Description:**

The producer and consumer integration test files independently implement the same test infrastructure:

**`kafka-eio-producer/test/test_producer_integration.ml` lines 5–20:**
```ocaml
let brokers =
  match Sys.getenv_opt "KAFKA_BROKERS" with
  | Some b -> [b] | None -> ["localhost:9092"]

let make_config () : Kafka_producer.config = {
  brokers;
  delivery_mode = Kafka_producer.At_least_once;
  linger_ms = None;
  security = Kafka_security.Plaintext;
}
```

**`kafka-eio-consumer/test/test_consumer_integration.ml` lines 6–11:**
```ocaml
let brokers =
  match Sys.getenv_opt "KAFKA_BROKERS" with
  | Some b -> [b] | None -> ["localhost:9092"]
```

Both are copy-pasted. Any new Kafka package test (e.g., `kafka-eio-service/test/`) will add a third copy.

**Remediation:**

Create `integrations/kafka/kafka-eio-core/test/kafka_test_helpers.ml`:

```ocaml
let brokers () =
  match Sys.getenv_opt "KAFKA_BROKERS" with
  | Some b when b <> "" -> [b]
  | _ -> ["localhost:9092"]

let default_producer_config () : Kafka_producer.config = {
  brokers = brokers ();
  delivery_mode = Kafka_producer.At_least_once;
  linger_ms = None;
  security = Kafka_security.Plaintext;
}

let default_consumer_config ~group_id () : Kafka_consumer.config = {
  brokers = brokers ();
  group_id;
  offset_reset = Kafka_consumer.Earliest;
  security = Kafka_security.Plaintext;
}
```

Add a dune `(library (name kafka_test_helpers) ...)` or `(modules kafka_test_helpers)` stanza in `kafka-eio-core/test/`. Update the producer and consumer test dune files to depend on it.

**Acceptance criteria:**

- `grep -rn "KAFKA_BROKERS\|localhost:9092" integrations/kafka/kafka-eio-producer/test/ integrations/kafka/kafka-eio-consumer/test/` returns zero hits.
- `dune test integrations/kafka/` passes with a live broker.
