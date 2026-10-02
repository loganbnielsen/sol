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

1. Add one small module (e.g. `cli/lib/workspace/sol_cli_target_arg.ml`, or a
   `cli/bin` module if the `bin` layer is the right owner) exposing
   `positional : doc:string -> string option Cmdliner.Term.t` and
   `flag : doc:string -> string option Cmdliner.Term.t`, both built on
   `Sol_cli_args.text`, declaring the `<env>/<provider>/<region>` grammar and
   each command's `~docv` once for its axis.
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
