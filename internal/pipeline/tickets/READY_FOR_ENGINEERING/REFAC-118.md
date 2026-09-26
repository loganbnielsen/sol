---
id: REFAC-118
type: refactor
severity: low
title: Rewrite sol cloud's print_outputs as a pure, result-returning function with tests
source: operator code-review notes (2026-09-26, sol-logan-comments), cli/bin/cmd_cloud_tf.ml print_outputs
---

**Depends on:** REFAC-116.

## The problem

`print_outputs` matches `Error _ | Ok { exit_code = 1 | 2 | 127 | 128 }`, then `Ok r when exit_code <> 0` with the same body, so the explicit list is redundant, and both discard the reason. It parses with `try` inside a nested `match`, and mixes selecting outputs with printing them. It is hard to read, and untested.

## Remediation

A pure `outputs_to_print : string -> ((string * string) list, string) result` (the sensitive-output filtering included), a printer, and one failure message that carries the reason.

## Acceptance criteria

- Unit tests: sensitive outputs are skipped, string and list values are printed, malformed JSON is an `Error` with a reason.
- Output for a normal apply is unchanged.
- Demo/example: not applicable; state it.
