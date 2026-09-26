---
id: REFAC-123
type: refactor
severity: medium
title: Decode blank to None at the boundary -- an optional string inside Sol is never Some ""
source: operator review (2026-09-26), on the REFAC-121 is_blank helper
---

**Depends on:** None.

## The problem

REFAC-121 gave Sol one spelling of "is this blank?" (`Sol_cli_string.is_blank`, `non_blank`, `non_blank_opt`, `non_empty`). The operator's point is that the question shouldn't be asked at the use sites at all. If `Some ""` and `Some "  "` can reach a consumer, every consumer has to remember that they mean `None`. The helper makes the check shorter; it doesn't make it unnecessary.

`git grep -c 'Sol_cli_string\.\(is_blank\|non_blank_opt\|non_blank\|non_empty\)\b' origin/main -- cli` (2026-09-26) finds 28 use sites across 18 files. They cluster in the consumers of decoded config and process output: `sol_cli_profile_preflight.ml` (3), `sol_cli_aws_destruction.ml` (3), `sol_cli_cluster.ml`, `sol_cli_open.ml`, `sol_cli_provider_capabilities.ml` and `cmd_migrate.ml` (2 each). There are also about 73 hand-written `= ""` comparisons in `cli/**/*.ml`, and some of them are the same check.

## Remediation

Normalise once, where a string enters Sol, so that inside Sol `string option` means "absent or a real value":

- **Config decoder** (`Sol_cli_config`, `Sol_cli_manifest_yaml`, `Sol_cli_toml`):
  - A blank optional scalar decodes to `None`. Unquoted `""`/`~`/`null` already does; quoted `""` and whitespace-only values should too.
  - A blank *required* field is a decode error that names the path, not a `""` passed downstream.
- **Environment**: `Sol_cli_string.env` is the boundary; raw `Sys.getenv_opt` calls for settings go through it.
- **Process output**: adapters that read a value from a command (`kubectl … -o jsonpath`, `aws … --output text`, `terraform output`) return `None` or an `Error` for empty or whitespace output. Consumers must not trim or test the output again.
- **CLI arguments**: Cmdliner converters for names, targets and similar values reject an empty value at parse time (exit 124).
- **A private `Non_empty.t`** only where a value crosses several modules and the type is doing real work, for example identities that end up in names or ARNs. Don't use it everywhere.
- Then remove the use-site checks the boundaries now guarantee. `Sol_cli_string` keeps `env`, `contains`, and whatever the boundaries themselves use. Delete helpers that no longer have callers.

## Acceptance criteria

- Every remaining `Sol_cli_string.is_blank`/`non_blank*`/`non_empty` call is at a decode or adapter boundary. The completion notes list them with `git grep` output.
- Tests at each boundary:
  - a quoted blank optional config value decodes to `None`;
  - a blank required value is a decode error naming its path;
  - an empty process output is `None` or `Error`;
  - an empty CLI argument is refused.
- Consumers pattern-match on `None | Some v` with no re-trimming.
- Demo/example: not applicable (internal; no author-facing change except blank values being refused earlier). State it in the notes.
- Language parity: no impact (CLI-internal).
