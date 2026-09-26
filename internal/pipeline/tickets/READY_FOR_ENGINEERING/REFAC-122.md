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
