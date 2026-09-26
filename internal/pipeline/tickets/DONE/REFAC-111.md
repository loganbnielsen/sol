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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`85731f78`): `enter_or_exit` returned a bare root and `cmd_status`/`cmd_logs`/`cmd_fn` re-derived the name with `Filename.basename`; `cmd_up.run` and `cmd_deploy.run` both computed `requested_scope` from `selected.request` and checked `services = []` afterwards; `rg -c 'exit 1' cli/bin/*.ml` summed to 128.

- **`Sol_cli_exit.or_exit` / `or_exit_with`** (`cli/lib/base/sol_cli_exit.ml`): print `error: <msg>`, exit 1. 32 hand-written print-and-exit `match`es in `cli/bin` are converted, through three shapes whose equivalence is structural:
  - `Ok x -> x` becomes `or_exit e`;
  - `Ok x -> f x` becomes `f (or_exit e)`;
  - `Error … exit | Ok x -> body`, with `Ok x` the last branch, becomes `let x = or_exit e in body`. A later branch would be an unused-case compile error, so the build confirms the shape.
- **What stays** (`exit 1` sites: 128 → 93). The sites fall into these groups:
  - policy refusals that print multi-line guidance naming the next step (e.g. the undeclared-target, migration-gate and plaintext-secret refusals);
  - `match`es whose `Ok` side has several cases (`Ok []` vs `Ok records`) or whose `Error` side prints more than one line;
  - `if cond then (…; exit 1)` guards and `None -> exit` option cases;
  - the `"\nerror:"` sites, which deliberately print a blank line first.

  None of these is a result-to-exit conversion that `or_exit` would express better. `cmd_cloud_tf`'s own `lifecycle_error` is the one near-duplicate; it's left as is because it sits in the lifecycle's own error path.
- **Workspace record:** `Sol_cli_workspace.enter_or_exit : unit -> t` with `t = { root; name }`. The per-command `workspace_name ()` wrappers in `cmd_fn`/`cmd_status`/`cmd_logs` are gone (`cmd_open` borrowed `Cmd_logs`'s), and `cmd_up` destructures the record. `sol deploy`, `releases`, `deployments`, `rollback` and `cloud` still use `current_name` because they deliberately don't `chdir` (REFAC-110 owns that).
- **Selection:** `Sol_cli_workload_selection.resolved` carries `requested_scope`, computed once in `resolve`. `resolve_nonempty ~none` refuses an empty selection as part of resolving, and `up`, `deploy` and `local` use it. In `cmd_deploy`, the post-omission check no longer needs `&& excluded <> []`, and the second, generic "no services" check is gone: a non-empty selection emptied by omission always has exclusions.
- **Where resolution happens:** at the top of `run`, immediately after entering the workspace, not in the Cmdliner term. Discovery reads the workspace from the cwd, and the workspace is only entered inside `run`. Moving both into the term would make `--help` and argument errors depend on being inside a workspace.
- **Checked with the real binary** in a workspace with an empty `app/`, run from a subdirectory: `sol up --dry-run --tag t` and `sol deploy prod/aws/us-east-1 --dry-run --image-tag t` both print `error: no services found in app/ with a Dockerfile` and exit 1.
- **User-visible text:** `sol up`/`sol deploy` over a workspace with no services now print `error: no services found in app/ with a Dockerfile` (previously capitalised, without the `error:` prefix). No test or script matched the old text (`rg -n 'No services found' --glob '!_build' .` finds only a dogfood record quoting it). `sol local up`'s message is unchanged apart from being one line.
- **Verification:** `dune build`, `dune test cli/ --force` (59 suites, 0 failures), `internal/ci/check_ocamlformat.sh --all` clean, after merging `main` with REFAC-109. Its `Sol_cli_config.target cfg` matches, which this branch had converted to `or_exit`, now read `cfg.target` directly.
- **Tests:** `test_deployment_scope.ml` gains tests that `requested_scope` matches the request, that `resolve_nonempty` refuses an empty selection with the caller's message, accepts a real one (positive control), and passes selector errors through unchanged. `test_workspace.ml` checks `enter_or_exit`'s `name`.
- Demo/example: not applicable (internal refactor; the only text change is the error line above).
- Language parity (DEC-022): no impact (CLI internals).
