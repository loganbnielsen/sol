---
id: CODE_LAYER-013
type: code-layer-finding
severity: low
source: project/audits/2026-09-06b_code_layer_audit.md
branch: code_layer-013/terraform-var-formatting-move
worktree: ../sun-code_layer-013-terraform-var-formatting-move
pr: https://github.com/loganbnielsen/sun/pull/133
---

Terraform var-string formatting leaks into the neutral config model

**Depends on:** None.

## Problem

`Sun_cli_config.terraform_vars` (`cli/sun/lib/sun_cli_config.ml:669-690`)
builds literal Terraform CLI var syntax — `"region=" ^ v`,
`"create_rds=" ^ string_of_bool has_postgres`, etc. — directly inside
what is otherwise the neutral `sun.yml`/`sun.toml` parsing/model module
(`Sun_cli_config` has no other awareness of Terraform anywhere else in
the file). The actual Terraform adapter,
`cli/sun/lib/sun_cli_terraform.ml`, already owns the next layer of the
same format one level up (`var_args`: `"-var=" ^ v` /
`"-var-file=" ^ f`, lines 12-15) — so the `key=value` join for a var is
split awkwardly across two files instead of living entirely in the
adapter that already does the rest of the Terraform-specific formatting.

`cmd_cloud_tf.ml:238-273`'s `config_vars` is the only caller: it takes
`Sun_cli_config.terraform_vars cfg`'s `string list` and passes it
straight into `Sun_cli_terraform.plan/apply/plan_destroy/destroy ~vars`
unchanged.

## Goal

All Terraform CLI var-syntax formatting lives in `Sun_cli_terraform`;
`Sun_cli_config` exposes only the neutral key/value data.

## Remediation

- Change `Sun_cli_config.terraform_vars`'s return type from
  `(string list, string) result` to `((string * string) list, string) result`
  — key/value pairs, no `"="` join.
- Move the `k ^ "=" ^ v` join into `Sun_cli_terraform.var_args` (or a new
  helper alongside it) so it composes with the existing `"-var=" ^ v`
  prefixing in one place.
- Update `cmd_cloud_tf.ml`'s `config_vars` to match the new return type
  (it passes the result straight through to `Sun_cli_terraform.plan`/
  `apply`/etc., so this should be a small, mechanical change).
- Update `cli/sun/test/test_config.ml`'s `terraform_vars` test(s) for the
  new return type.

## Acceptance criteria

- `Sun_cli_config.terraform_vars` returns key/value pairs, not
  pre-joined `"key=value"` strings.
- `Sun_cli_terraform.ml` is the only file in `cli/sun` that constructs a
  literal `"-var=..."` or `"key=value"` Terraform CLI argument string.
- `sun cloud plan`/`sun cloud apply` behavior is unchanged — same
  `-var`/`-var-file` arguments reach the `terraform` binary as before.
- Focused tests pass in `cli/sun`.

## Review — automated checks passed
Sun_cli_config.terraform_vars now returns neutral (string*string) pairs instead of pre-joined key=value strings; Sun_cli_terraform.kv_args (new, exported) does the Terraform CLI join, keeping sun_cli_terraform.ml as the sole constructor of literal Terraform var strings. cmd_cloud_tf.ml's config_vars updated to call kv_args once; var_args/plan/apply/destroy's own ~vars:string list signature deliberately unchanged since sun cloud's --var CLI flag is a separate raw-string source concatenated afterward. Two independent fresh adversarial review rounds, both clean: verified config_vars @ vars still type-checks and behaves identically, resolved_var's =-splitting AWS-destroy verification parser is unaffected, terraform_vars pair-ordering is semantically identical to the old joined version, the acceptance criterion (only sun_cli_terraform.ml builds literal Terraform var strings) holds via repo-wide grep, and no other caller of terraform_vars was missed. One cosmetic mli-ordering nit from round two fixed. Full unit+kafka+e2e suite green throughout.
