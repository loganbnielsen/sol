---
id: DOCS-018
type: docs-finding
severity: medium
source: pipeline/audits/2026-09-16_docs_audit.md
---

**Depends on:** None.

# Update the remaining reusable audit procedures to current Sol

`UX_AUDIT.md`, `STYLE_AUDIT.md`, and `SCAFFOLD_AUDIT.md` still target the old
Sun product: `sun` commands, `cli/sun`, `Sun.*` modules, removed hosted code,
and obsolete `sun dev`/`sun cloud init` workflows. `STYLE_AUDIT_FINDINGS.md` also
routes future passes through removed paths. The procedures cannot be followed
literally against this checkout.

## Acceptance criteria

- All reusable audit templates name current `sol` commands, modules, and paths.
- Checklist items for removed product surfaces are deleted, not renamed into
  fictional current features.
- Scaffold and UX procedures cover both language paths, with explicit verdicts
  for still-open TypeScript gaps rather than silence.
- `rg -n 'Sun|cli/sun|framework/sun|sun dev|sun cloud init' docs/audits` returns
  only deliberate historical findings, not active procedure text.

## Completion (2026-09-22)

**The ticket's premise had partly aged, and the criterion's own search could not
have caught the part that hadn't.** `rg 'Sun|cli/sun|framework/sun|sun dev|sun cloud
init' docs/audits` returns **0** — the rename to `sol` landed with the repository
information-architecture refactor (`ce3726d1`, #311). But the same tree still cited
`cli/sol/lib/sun_cli_scaffold.ml`, because neither `Sun` nor `cli/sun` matches
`sun_`. The criterion passed while the defect it was written for was present.

The check that actually finds this class is *does every path these procedures cite
exist*, which is what produced the six leftovers below. Any future pass should use
that, not the string search.

**Stale references, fixed (all in `internal/pipeline/audits/`):**

| Where | Was | Now |
|---|---|---|
| `SCAFFOLD_AUDIT.md` §1 | `cli/sol/bin/cmd_new.ml`, `sun_cli_scaffold.ml` | `cli/sol/lib/sol_cli_cmd_new.ml`, `sol_cli_scaffold.ml`, `sol_cli_scaffold_templates.ml` |
| `STYLE_AUDIT.md` §2 and its findings table | `sun_cli_deployment_render.ml` | `sol_cli_deployment_render.ml` |
| `STYLE_AUDIT.md` §1 examples | `release_status_of_string` in `sun_cli_registry.ml` — function and module both gone | `Sol_cli_release.apply_mode_of_string`, which does the same job (returns `Error` for an unknown value) |
| `STYLE_AUDIT.md` §1 examples | `Kafka_security.protocol_of_string`, "tests in `test_kafka_security.ml`" — that test file is not in this repository | `Kafka.Security.protocol_of_string`, with the citation saying the module is the standalone `kafka-eio` opam package (as `AUDIT.md` already documents) so the tests' real home is clear |
| `UX_AUDIT.md` Stage 3 | `sun_worker_messages_total` | `sol_worker_messages_total` |
| `STYLE_AUDIT.md` "Areas noted for future improvement" | `param_int` in `sun_cli_control_plane.ml` | deleted. Neither the function nor the module exists, and the control-plane API it belonged to is not in this repository — re-pointing it at whatever module looks closest would have been the "fictional current feature" this criterion forbids. The section now says why it is empty. |

**The TypeScript criterion was entirely unmet** — no audit procedure mentioned
TypeScript anywhere. Added, with verdicts that a later pass is forced to record:

- `SCAFFOLD_AUDIT.md` §9 **Language Coverage** — five items: OCaml is the scaffolded
  path; `sol new` has no `--language` flag so the TypeScript scaffolding gap is
  FEAT-084 (record it as a known gap with an owner, neither as a defect nor as
  coverage); the TypeScript path is audited against `examples/pluto/app/demo_ts` and
  the four published `@sol-fab/*` packages; `@sol-fab/worker`'s missing `on_ready`
  equivalent (DEC-028) is one of the DEC-026 §2 profile triggers and must not go
  unstated; and no scaffold may claim a TypeScript equivalent exists.
- `UX_AUDIT.md` **Language Coverage** (the same verdicts from the UX side) plus a
  TypeScript verdict item in Stage 2, whose gate is OCaml-only.

Both sections are written to *expire*: each says what makes it stale if FEAT-084
lands, so the procedure cannot quietly become wrong.

**Verification:** every repository path and bare `*.ml` filename cited in
`internal/pipeline/audits/*.md` now resolves; the criterion's search returns 0; and a
case-insensitive search for `sun` returns exactly one hit — the deliberate historical
note in `STYLE_AUDIT.md` explaining why the improvement section is empty, which is
the "deliberate historical findings" the criterion allows.

**Demo/example coverage:** documentation-only; no application behavior changes.

## Demo/example coverage

Documentation-only; no application behavior changes.
