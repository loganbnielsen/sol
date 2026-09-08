---
id: REFAC-018
type: refactor
severity: medium
branch: REFAC-018/decode-dispatch
worktree: /home/lbendtly/Code/sun-REFAC-018-decode-dispatch
source: codebase simplification review 2026-06-15
---

Unify four copies of decode-and-handle inside kafka_service.ml

**Depends on:** REFAC-017.

**Description:**

Within `kafka_service.ml`, the wire-decode → JSON-parse → topic-decode → handler dispatch sequence is written out four times:

| Function | Lines |
|----------|-------|
| `decode_and_handle` in `consume` | 422–437 |
| `decode_and_handle` in `consume_partitioned` (in-memory retry) | 484–499 |
| `decode_retry` in `consume_partitioned` (retry-topics) | 572–605 |
| `decode_and_handle` in `consume_partitioned` (retry-topics outer) | 637–666 |

All four do `decode_wire` → `Yojson.Safe.from_string` → `topic.decode` → call handler or `on_decode_error`. The only variation is the type of what the handler returns.

This depends on REFAC-017 because the natural home for a shared helper is `kafka_service_schema.ml` (where `decode_wire` will live after the split).

**Remediation:**

Add one internal helper after the split:

```ocaml
(* Decode [raw_msg] through wire format, JSON, and topic codec.
   Calls [on_ok msg] or [on_error description] — never both. *)
let decode_dispatch ~raw_msg ~topic ~on_ok ~on_error =
  let raw_bytes = raw_msg.Kafka_consumer.value in
  match Kafka_service_schema.decode_wire raw_bytes with
  | Error e -> on_error e
  | Ok (_schema_id, json_str) ->
    match (try Ok (Yojson.Safe.from_string json_str)
           with exn -> Error (Printexc.to_string exn)) with
    | Error e -> on_error ("json parse: " ^ e)
    | Ok json ->
      match topic.decode json with
      | Error e -> on_error ("message decode: " ^ e)
      | Ok msg  -> on_ok msg
```

Replace all four call sites with `decode_dispatch`. Each site passes different `on_ok`/`on_error` callbacks that capture the variables they already have in scope (ack, attempt, trace_ctx, etc.).

**Acceptance criteria:**

- `kafka_service.ml` contains exactly one definition of the wire → JSON → topic-decode pipeline.
- `dune build` passes.
- All Kafka integration tests pass (`KAFKA_BROKERS=localhost:9092 dune test integrations/kafka/ --force`).

## Review — automated checks passed
decode_dispatch helper unifies wire→JSON→topic-decode pipeline; both call sites updated; build clean; no API changes
