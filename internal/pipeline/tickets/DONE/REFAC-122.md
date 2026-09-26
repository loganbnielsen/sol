---
id: REFAC-122
type: refactor
severity: low
title: One substring helper -- Sol_cli_string.contains instead of ~45 private copies
source: found while implementing REFAC-116 (2026-09-26); the operator's "hand-rolled" review theme
---

**Depends on:** REFAC-121.

## The problem

Substring search is hand-written repeatedly. On `origin/main` (2026-09-26), `rg -n 'let (string_)?contains' cli --glob '*.ml'`:

- three implementations in library code: `Sol_cli_port_forward.string_contains` (an odd home, with 28 uses across modules unrelated to port-forwarding), `Sol_cli_destruction.contains`, and `Sol_cli_sensitive_vars.contains`;
- about 45 private copies in `cli/test/*.ml`, with three different argument orders (`needle haystack`, `haystack needle`, `~needle s`), plus a few regex-based `contains re s`.

## Remediation

`Sol_cli_string.contains ~needle haystack` (in the REFAC-121 module) is the one implementation. Library code and tests use it; the private copies are deleted, and `Sol_cli_port_forward.string_contains` goes.

## Acceptance criteria

- `rg -n 'let (string_)?contains' cli --glob '*.ml'` finds only `Sol_cli_string`.
- Demo/example: not applicable; state it.

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`24adf07b`): `rg -n 'let (string_)?contains' cli --glob '*.ml'` listed three library implementations and about 45 test copies.

- **Library:** `Sol_cli_port_forward.string_contains` (with its 28 callers across unrelated modules), `Sol_cli_destruction.contains` (also reached through `open` in `sol_cli_gcp_destruction`) and `Sol_cli_sensitive_vars.contains` are deleted. Everything calls `Sol_cli_string.contains ~needle haystack`.
- **Tests:**
  - labelled copies are deleted and their calls go to `Sol_cli_string.contains` directly;
  - positional copies (`needle haystack`, `haystack needle`, `url sub`) are one-line delegations, keeping their argument order so no call site changed meaning;
  - nested copies (`test_release_id`, `test_local_infra`, `test_deploy_event`) and inline `try Str.search_forward (Str.regexp_string …)` blocks (9 in `test_rollout_diagnosis`, and those in `test_check` and `test_loki`) now call it.
- **A hazard handled by hand:** `test_deployment_phases.ml` had a positional helper shadowed by a later labelled one. OCaml allows omitting labels in a total application, so a mechanical rename could have compiled with needle and haystack swapped. The file was restored and edited so each call keeps its original binding. `test_process.ml` (haystack first, labelled) was checked for unlabelled calls; there were none.
- **Left deliberately:**
  - `contains re s` in `test_cloud_destroy`, `test_deployment_plan`, `test_boundary_lease` and `test_rollback`, which take compiled regexes and are called with real patterns (`Str.regexp`), so they are a different operation;
  - `test_manifest_render` (counts occurrences) and `test_deployment` (returns a position), which are not substring tests.
- Verification: as REFAC-121 (same branch).
- Demo/example: not applicable. Language parity: no impact.
