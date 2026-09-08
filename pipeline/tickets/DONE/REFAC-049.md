---
id: REFAC-049
type: refactor
severity: medium
source: codebase simplification review 2026-06-16
branch: REFAC-049/eliminate-kafka-error-int-table
worktree: ../sun-REFAC-049-eliminate-kafka-error-int-table
---

Eliminate parallel integer-mapping table in `kafka_error.ml`

**Depends on:** None.

**Description:**

`integrations/kafka/kafka-eio-core/lib/kafka_error.ml` contains two complete parallel tables mapping all 100+ error codes:

- `of_int` (lines 126–249) — `int → variant`
- `to_string` (lines 252–375) — `variant → int → Kafka_raw.err2str`

The `to_string` function converts a variant back to an integer only so it can call `Kafka_raw.err2str code`. This means every variant appears three times in the file (type declaration, `of_int`, `to_string`) and the two integer tables must stay in sync manually. A mismatch (e.g., `Partition_eof` mapped to `-191` in `of_int` but `-190` in `to_string`) would silently produce wrong error messages.

**Remediation:**

1. Add a private `to_int : t -> int` function with the current `to_string` match body (variant → int).
2. Simplify `to_string` to:
   ```ocaml
   let to_string err = Kafka_raw.err2str (to_int err)
   ```
3. Delete the 120-line match table currently inside `to_string`.

**Acceptance criteria:**

- `to_string` is a one-liner in the source.
- `wc -l integrations/kafka/kafka-eio-core/lib/kafka_error.ml` reports ~130 fewer lines.
- `dune build integrations/kafka/` and `dune test integrations/kafka/` pass.

## Review — automated checks passed
to_int extracted as private function; to_string is a one-liner delegating to Kafka_raw.err2str; build and tests clean; mli does not expose to_int
