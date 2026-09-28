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

## Completion notes (2026-09-28)

- Reverified the literal discovery command at `621b3f9d`: its eight output lines
  represent four constructions (two lines per construction), not eight distinct
  sites. Positive controls are local platform releases/endpoints, configuration
  layer keys, and the assets diagnostic. Extended the search to `platform/` and
  manually inspected CLI commands/libraries, framework, Pluto/examples, copied
  scaffold templates, and internal tooling using the broader collection lens.
- Named Kafka, Postgres, observability, Tempo, Prometheus and ingress release and
  endpoint groups in `Sol_cli_local_platform`; each final list exposes its original
  ordering. Named workload/unexpected domain groups in status discovery, context
  override environment entries in logs, and inclusion/exclusion deployment notes.
- `cmd_assets` is handled separately by REFAC-144. Retained `Sol_cli_config.layer_keys`:
  homogeneous optional key enumeration is already readable with named target keys.
  Retained `Sol_obs.of_env`: backend/renderer/flush collections are already named.
  Retained `Sol_process`'s two pipe-read descriptors: two trivial optional entries
  do not need names. Retained literal HTTP headers/event fields, uniform per-service
  mappings, and template dependency lists; these are not hidden conceptual groups.
- No generic helper, module, dependency, boolean-to-policy change or public API.
  Added the contributing rule with its restraint. Existing local platform tests
  explicitly hold install and endpoint order, declarations, values and port uniqueness;
  deploy selection, status, logs and config tests pass, as do build, formatting and
  no-comments checks.
- Demo/example: not applicable; internal collection construction changes only,
  with unchanged Helm values/argv, CLI text, emitted plans, environment and behavior.
- Language parity: no impact; language-neutral platform and deployment contracts
  remain unchanged, and reviewed OCaml app examples/templates need no edits.
