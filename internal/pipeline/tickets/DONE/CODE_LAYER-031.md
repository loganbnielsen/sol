---
id: CODE_LAYER-031
type: refactor
severity: low
title: Declare the DEC-031 target axis once instead of eight times
source: internal/pipeline/audits/2026-10-02_code_layer_audit.md
premise: "! rg -q '^let target_arg' cli/bin/cmd_plan.ml"
---

Declare the DEC-031 target axis once instead of eight times

**Depends on:** None.

## Problem

Eight commands declare their own `target_arg`:

| command | form | notes |
|---|---|---|
| `cmd_plan.ml:91` | required positional | `~docv:"TARGET"`, short doc |
| `cmd_cloud_tf.ml:330` | required positional | byte-identical to `cmd_plan` |
| `cmd_deploy.ml:743` | required positional | longer doc |
| `cmd_migrate.ml:319` | **optional** positional | third doc |
| `cmd_alert.ml:45` | `--target` flag | `~docv:"ENV/PROVIDER/REGION"` |
| `cmd_target.ml:178` | `--target` flag | different doc |
| `cmd_logs.ml:410` | `--target` flag | different doc |
| `cmd_destination.ml:5` | `--target` flag | different doc |

DEC-031 says the primary axis takes the positional and every other axis is a
flag, with `sol plan`/`sol deploy`/`sol cloud …` addressed by target and
`sol status`/`sol open`/`sol logs` addressed by scope or view. `AGENTS.md`
states the rule once; the code re-types it eight times, and the copies have
already drifted in `docv` (`TARGET` vs `ENV/PROVIDER/REGION`), in
required/optional, and in the doc text. Nothing makes a new target-primary
command take the positional rather than a flag, so the one convention that
this CLI is most explicit about is the one with no single declaration.

## Remediation

1. Add one small module (`cli/lib/workspace/sol_cli_target_arg.ml`, beside
   `Sol_cli_args`) exposing four builders over `Sol_cli_args.text`:
   `positional : doc:string -> string Cmdliner.Term.t` and
   `required_flag : doc:string -> string Cmdliner.Term.t` — a `required & some`
   argument is *not* optional, which the first draft of this ticket got wrong —
   plus `optional_positional : doc:string -> string option Cmdliner.Term.t` and
   `flag : doc:string -> string option Cmdliner.Term.t`.
2. Migrate the eight sites, keeping each command's own `~doc` text (that is
   product surface) but removing the hand-built `Arg.(required & pos 0 … )` /
   `Arg.(value & opt … )` scaffolding. Decide `cmd_migrate`'s optional
   positional deliberately and record which axis it is on.
3. Do not move a command between the positional and flag form; this is a
   consolidation, not a CLI change.

## Acceptance criteria

- There is one declaration of the positional form and one of the flag form;
  `rg -n 'pos 0 \(some Sol_cli_args.text\)' cli/bin` and
  `rg -n '"target" \]' cli/bin` show the shared builder, not each command.
- `sol <cmd> --help` output is unchanged except for any `docv` the audit showed
  to be inconsistent, and that change is deliberate and noted.
- The `bin` cmdliner wiring still compiles; `cli/test/inline` passes.
- Update a runnable example/demo for application-facing behavior, or record why
  this is an internal-only refactor (help text is user-visible, so state whether
  any wording changed).
- Record the per-language capability verdict for framework/application
  contracts, or explain why language parity is unaffected.

## Completion (2026-10-02)

- **Premise re-verified** at `origin/main` `8e13ce1b`: eight hand-built `target_arg` definitions in `cli/bin`, byte-identical between `cmd_plan` and `cmd_cloud_tf`, with the positional/flag split and the `<env>/<provider>/<region>` grammar re-typed at each site.
- **Fix.** Added `cli/lib/workspace/sol_cli_target_arg.ml` (+`.mli`) with four builders over `Sol_cli_args.text` — `positional` and `required_flag` (which are `string Cmdliner.Term.t`) and `optional_positional` and `flag` (which are `string option Cmdliner.Term.t`). Migrated all eight sites, each keeping its own `~doc` text verbatim. `cmd_migrate` is deliberately the optional positional (omit for the local dev cluster); `cmd_alert` the required flag; `cmd_target`/`cmd_logs`/`cmd_destination` the optional flag. No command changed axis.
- **Help output.** Captured `--help` for `plan`, `cloud apply`, `deploy`, `migrate`, `alert test`, `target show`, `logs` and `status` before and after (`COLUMNS=80 TERM=dumb`); `diff -ru` reports them byte-identical, so no wording, `docv` or usage line changed.
- **Tests.** Full `cli/test/inline` suite runs; the only failures are the two environmental `test_scaffold` "scaffold compiles" cases that run `dune build` in a temp dir, which fail on unmodified `main` in this environment too.
- **Guards.** `check_publisher_deployer_boundary.sh`, `check_workload_release_order.py`, `check_deploy_substrate_order.py` and their mutation suites pass; `check_no_comments.sh` clean.
- Validation: full `dune build`; `dune fmt` clean.
- **Demo/example: not applicable** — internal CLI argument wiring, no app-author surface; help text is byte-identical, as verified above. **Language parity: no impact.**
