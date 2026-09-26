---
id: REFAC-111
type: refactor
severity: medium
title: Parse at the CLI edge -- one or_exit, a workspace record, and a validated selection
source: operator code-review notes (2026-09-25, sol-logan-review), cli/bin/cmd_up.ml
---

**Depends on:** REFAC-108.

## The problem

Three patterns in `cli/bin/` recur in every command. Each is hand-written, and each
leaves validation to the middle of `run` instead of the CLI edge:

1. **Result-to-exit by hand.** `| Ok x -> x | Error msg -> Printf.eprintf ...; exit 1`
   is written out at each site. `rg -c 'exit 1' cli/bin/*.ml` reports 130 occurrences
   across 18 files (run 2026-09-25 on `cf6737b0`). OCaml has `Result.map_error`
   (fp-ts `mapLeft`) and `Result.fold`. What the codebase lacks is one
   `getOrElse`-style helper for "print and exit".
2. **Workspace entry returns half a value.** After REFAC-108,
   `Sol_cli_workspace.enter_or_exit ()` returns the root. Commands then call
   `workspace_name ~root` separately (e.g. `cmd_up.ml`), so "where am I" is two
   calls every time.
3. **Scope is re-derived instead of parsed once.** `cmd_up.run` receives the raw
   request, then works with `req.scope`, `selected.request`, and `requested_scope`
   (`Sol_cli_deployment_scope.request_to_string selected.request`, `cmd_up.ml:423`):
   three views of one thing. The "no services selected" check is an `if` after
   resolution, not part of the resolved type.

## Remediation

- Add `Sol_cli_exit.or_exit : ('a, string) result -> 'a`, plus an `_err` variant
  taking an `error_to_string`, to `cli/lib/base`. Replace the hand-written sites.
  The exit code stays 1, and existing distinct exit codes are kept (audit them; do
  not flatten).
- `enter_or_exit` returns a `workspace = { root : string; name : string }`, and
  callers stop re-deriving the name.
- Resolve the Cmdliner scope once, into a `selection` value carrying the parsed
  request, its display string, and the resolved services. For mutating commands the
  resolver returns `Error "no services selected..."` instead of an empty list
  (non-empty by construction), so `run` never checks for it.

## Acceptance criteria

- [ ] `or_exit` exists and is used. The remaining `exit 1` sites in `cli/bin` are
      listed in the completion notes, each with why it stays (e.g. a different
      exit code, or an exit after partial output).
- [ ] No `workspace_name ~root` call follows an `enter_or_exit` in `cli/bin`.
- [ ] `cmd_up` and `cmd_deploy` take a `selection`; `requested_scope` is not
      recomputed in `run`.
- [ ] A test that resolving an empty selection for a mutating command is an
      `Error`.
- [ ] Error text and exit codes unchanged for existing CLI tests (golden output).
- [ ] Demo coverage: internal refactor, no app-author surface. Say so in the notes.
