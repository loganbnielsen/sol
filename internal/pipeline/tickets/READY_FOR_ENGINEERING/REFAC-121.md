---
id: REFAC-121
type: refactor
severity: low
title: One helper for "absent or empty" -- stop spelling None | Some "" and trim-equals-empty by hand
source: operator code-review notes (2026-09-26, sol-logan-comments), cli/bin/cmd_deploy.ml
---

**Depends on:** None.

## The problem

Optional strings are normalised by hand wherever they are read. On `origin/main` (2026-09-26):

- `rg -c 'Some ""' cli --glob '*.ml'` counts 11 sites in 9 files. Five are `| None | Some "" ->` arms (`cmd_up.ml`, `cmd_deploy.ml`, `sol_cli_boundary_lease.ml`, `sol_cli_scaffold_templates.ml` ×2).
- `rg -n 'String.trim [a-z_.]+ (=|<>) ""' cli --glob '*.ml'` finds 28 blank checks.

fp-ts treats null, undefined and empty alike when building an `Option`. Sol has no equivalent, so each site re-decides whether whitespace counts, and some trim while others don't.

## Remediation

A `Sol_cli_string` module in `cli/lib/base`:
- `non_blank : string -> string option`: `None` for empty or whitespace-only, else the trimmed value;
- `non_blank_opt : string option -> string option`: `Option.bind` of the same;
- `is_blank`.

Apply it codebase-wide (library, commands, and tests where they normalise).

## Acceptance criteria

- `rg 'Some ""' cli --glob '*.ml'` matches only places where the empty string is data, each listed with its reason in the completion notes.
- Unit tests for the helpers.
- Demo/example: not applicable; state it.
