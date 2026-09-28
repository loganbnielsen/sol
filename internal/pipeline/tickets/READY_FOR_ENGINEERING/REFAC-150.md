---
id: REFAC-150
type: refactor
severity: low
title: Name conceptual collection groups before combining them
source: Logan code review (2026-09-27), generalized from cmd_assets checks
---

Name conceptual collection groups before combining them

**Depends on:** None.

**Premise verified (2026-09-27):**
`rg -n -U 'List\.concat[[:space:]]*\n[[:space:]]*\[' --glob '*.ml' cli framework examples internal`
finds eight seed lines on `origin/main` at `52c01e21`, including provider/component/
template/observability groups in `cmd_assets.ml`, conditional component groups in
`sol_cli_local_platform.ml`, and configuration groups in `sol_cli_config.ml`.

## The principle

When one expression constructs and immediately combines several collections that mean
different things, name the conceptual groups first and let the final expression read as
the high-level summary. Preserve useful pipelines inside a group. Do not expand a short
homogeneous literal or name every trivial intermediate.

This applies beyond literal `List.concat`: nested `List.map`/`concat_map`, partial
applications, and collection literals inside constructors are candidates when the
reader must mentally execute several transformations to discover the structure.

## Remediation

- Record the rule and its restraint in `CONTRIBUTING.md`.
- Manually audit collection construction across the full OCaml tree, using the eight
  literal matches and Logan's `cmd_assets` example as positive controls.
- Name only real concepts; prefer deletion or a direct fixed list over a helper or
  abstraction.

## Acceptance criteria

- High-confidence dense collection constructions read as named conceptual groups plus a
  simple final combination.
- Completion notes list the whole-tree folders reviewed, changed sites, and representative
  candidates deliberately retained as already clear.
- No new generic collection helper or dependency is introduced.
- Behavior and collection order are unchanged and covered by existing or focused tests.
- Demo/example and language-parity impact are recorded per changed surface.

