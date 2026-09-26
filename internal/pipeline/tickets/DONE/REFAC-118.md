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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`1e23354b`): `print_outputs` matched `Error _ | Ok { exit_code = 1 | 2 | 127 | 128 }` and then `Ok r when exit_code <> 0` with the same body, discarding the reason, and parsed inside a `try`. REFAC-116 had already reduced the first part to one checked branch.

- `Sol_cli_terraform_outputs` (`cli/lib/cloud`), pure:
  - `displayable : string -> ((string * value) list, string) result`, where `value = Text | Texts | Null`;
  - `line`, which prints each value exactly as before.

  Unchanged rules: an output shows only when marked `sensitive: false`; lists show their string items, and are omitted if they have none; other value types are omitted; a non-object shows nothing.
- `print_outputs` is now: fetch (checked), select, print. When the outputs can't be retrieved or read, it says why (`could not retrieve terraform outputs: <reason>` / `could not read terraform outputs: <reason>`), instead of the old reason-less messages. No `try`: `Yojson.Json_error` is matched as a value.
- Tests (`test_terraform_outputs.ml`): mixed sensitive, unmarked, string, list, list-without-strings, null and number outputs select and print as before, in order; malformed JSON is an `Error`; a non-object shows nothing.
- Verification (with REFAC-117, same branch, after merging `main`): `dune test cli/ --force`, 65 suites, 0 failures; `internal/ci/check_ocamlformat.sh --all` clean.
- Demo/example: not applicable (same output). Language parity: no impact.
