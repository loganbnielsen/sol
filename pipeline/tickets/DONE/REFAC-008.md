---
id: REFAC-008
branch: REFAC-008/deduplicate-decode-handler
worktree: /home/lbendtly/Code/sun-REFAC-008-deduplicate-decode-handler
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
---

Deduplicate decode-and-handle closures inside `kafka_service.ml`

**Depends on:** None.

**Description:**

`integrations/kafka/kafka-eio-service/lib/kafka_service.ml` (679 lines) contains four near-identical `decode_and_handle` closures that implement the same three-stage pipeline — Confluent wire decode → JSON parse → `topic.decode` — with identical error routing to `on_decode_error`:

| Location | Context |
|----------|---------|
| Lines 422–437 | `consume` function |
| Lines 484–499 | `consume_partitioned` / `In_memory` branch |
| Lines 572–605 | `decode_retry` in `Retry_topics` (same 3-stage decode, extra retry routing after `handler`) |
| Lines 637–654 | main handler in `Retry_topics` (same decode, extra Error routing to retry topic) |

In addition, the `on_decode_error` wrapper (metric increment + structured log) and the `consumer_cfg` construction are each duplicated between `consume` (lines 390–418) and `consume_partitioned` (lines 450–478).

Every decode-error message change or new decode stage must be made 4 times.

**Remediation:**

1. Extract a private helper at the top of `kafka_service.ml`:
   ```ocaml
   (* Runs the 3-stage decode pipeline for one raw Kafka message.
      Returns Ok (msg, trace_ctx) or calls [on_err] and returns its value. *)
   let decode_message topic ~on_decode_error raw_msg =
     let trace_ctx = Obs_trace.extract_from_headers raw_msg.Kafka_consumer.headers in
     let raw_bytes = raw_msg.Kafka_consumer.value in
     match decode_wire raw_bytes with
     | Error e -> Error (on_decode_error e ~raw_bytes)
     | Ok (_schema_id, json_str) ->
       match (try Ok (Yojson.Safe.from_string json_str)
              with exn -> Error (Printexc.to_string exn)) with
       | Error e -> Error (on_decode_error ("json parse: " ^ e) ~raw_bytes)
       | Ok json ->
         match topic.decode json with
         | Error e -> Error (on_decode_error ("message decode: " ^ e) ~raw_bytes)
         | Ok msg  -> Ok (msg, trace_ctx)
   ```
   Adjust the return type as needed so all four call sites can use it (the retry sites need to thread `~ack` through separately).

2. Extract a private helper for the `on_decode_error` instrumentation wrapper:
   ```ocaml
   let make_decode_error_handler ~ot ~topic ~on_decode_error_user =
     let decode_err_count = ... in
     fun e ~raw_bytes ~ack ->
       (match decode_err_count with Some c -> c 1 | None -> ());
       (* log *)
       on_decode_error_user e ~raw_bytes ~ack
   ```
   Used by both `consume` and `consume_partitioned`.

3. Extract the consumer config construction:
   ```ocaml
   let make_consumer_cfg svc ~group_id ~topic_name = {
     brokers = svc.brokers; group_id; topics = [topic_name];
     offset_reset = Kafka_consumer.Latest; auto_commit = false;
     on_rebalance = None; security = svc.security;
   }
   ```

4. Replace all four `decode_and_handle` closures and both `consumer_cfg` constructions with calls to these helpers.

**Acceptance criteria:**

- `kafka_service.ml` has at most one place that calls `decode_wire`, `Yojson.Safe.from_string`, and `topic.decode` in sequence.
- No local `consumer_cfg` record literal appears more than once.
- `kafka_service.ml` shrinks by at least 60 lines.
- `dune build && dune test integrations/kafka/kafka-eio-service/` passes.

## Review — automated checks passed
Decode pipeline unified into decode_message helper, consumer_cfg deduplicated via make_consumer_cfg, file shrinks 41 lines (679→638), no ticket directory changes, build clean
