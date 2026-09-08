---
id: REFAC-004
type: refactor
severity: low
source: codebase simplification review 2026-06-13
branch: REFAC-004/lookup-table
worktree: ../sun-REFAC-004-lookup-table
---

Replace the dual 125-branch pattern matches in `kafka_error.ml` with a single lookup table

**Depends on:** None.

**Description:**

`integrations/kafka/kafka-eio-core/lib/kafka_error.ml` is 396 lines. After the variant type declaration (~75 lines), the file contains two near-symmetric functions:

- `of_int` (lines ~126–249): 124-line `match code with | -1 -> Unknown | 1 -> Offset_out_of_range | ...`
- `to_string` (lines ~251–375): 125-line `match t with | Unknown -> "unknown" | Offset_out_of_range -> "offset_out_of_range" | ...`

Adding a new librdkafka error code requires editing both match arms. The two functions can diverge silently (wrong integer for a variant in one direction, wrong string in the other). The pattern is a textbook candidate for a table.

**Remediation:**

Replace the two match expressions with a single association list:

```ocaml
(* (variant, int_code, string_name) *)
let table : (t * int * string) list = [
  Unknown,                        -1,  "unknown";
  Offset_out_of_range,             1,  "offset_out_of_range";
  (* ... *)
]

let of_int code =
  match List.find_opt (fun (_, c, _) -> c = code) table with
  | Some (v, _, _) -> v
  | None           -> Unknown

let to_string t =
  match List.find_opt (fun (v, _, _) -> v = t) table with
  | Some (_, _, s) -> s
  | None           -> "unknown"
```

If linear scan performance matters (it shouldn't — error paths are not hot), convert to a pair of `Hashtbl` built once at startup from the same table.

The `to_string` function currently delegates to `rd_kafka_err2str` via FFI for some variants (verify before removing the FFI call). If so, the table stores the canonical string only for cases where the FFI isn't called, and the fallback to FFI is preserved.

**Acceptance criteria:**

- `kafka_error.ml` is under 150 lines after the refactor.
- `of_int` and `to_string` are derived from the same source-of-truth table.
- All existing `kafka_error` unit tests pass.
- `dune build` succeeds.

## Review — automated checks passed
Build succeeds, all kafka-eio-core unit tests pass, only kafka_error.ml is modified, and a single lookup table now drives both of_int and to_string with no duplicate match arms
