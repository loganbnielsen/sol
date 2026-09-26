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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`24adf07b`): the counts above held (11 `Some ""` sites, 28 blank checks).

- `Sol_cli_string` (`cli/lib/base`):
  - `is_blank`;
  - `non_blank`, which trims;
  - `non_blank_opt`, for an optional setting;
  - `non_empty`, which treats only `""` as absent and trims nothing (for values where whitespace is data, e.g. a `resourceVersion` or a supervision record field);
  - `env`, for an environment variable where `""` counts as unset, since `Unix.putenv` cannot unset.
- **Converted, codebase-wide:**
  - the `None | Some ""` arms (`cmd_up`/`cmd_deploy` `POSTGRES_URL` via `env`, `sol_cli_supervised`, `sol_cli_boundary_lease` via `non_empty`);
  - every `Some v when String.trim v <> "" -> … (String.trim v)` (`non_blank_opt`: provider capabilities, cloud lifecycle, kube destination, AWS credentials, observability URL, profile preflight);
  - every `String.trim x (=|<>) ""` (`is_blank`/`non_blank`).
- **Deduplicated along the way:** `Sol_cli_cloud_lifecycle.required` was a copy of `Sol_cli_provider_capabilities.required`; it is now that function, which is exported.
- **Deliberate small change:** four values that were checked for blankness but kept untrimmed (`sol_cli_cluster` optional outputs, the AWS destruction region ×2, the observability base domain) are now trimmed. Surrounding whitespace in those values could only ever break the lookup they feed.
- **What remains:** `rg -n 'String.trim [a-z_.]+ (=|<>) ""|Some ""' cli --glob '*.ml' --glob '!cli/test/**'` finds only `sol_cli_scaffold_templates.ml:1030,1034`. That is OCaml *emitted into a generated workspace*, which cannot call Sol's library.
- Tests: `cli/test/test_string.ml` covers blank, `non_empty` keeping whitespace, `env` treating `""` as unset, and `contains`. Full `dune test cli/ --force`: 63 suites, 0 failures. Format clean.
- Demo/example: not applicable. Language parity: no impact.
