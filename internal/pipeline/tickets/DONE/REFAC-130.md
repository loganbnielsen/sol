---
id: REFAC-130
type: refactor
severity: medium
title: Read the workspace once into a typed model instead of re-scanning the filesystem per question
source: operator review (2026-09-26, sol-logan-comments), sol_cli_workspace_scan.ml and sol_cli_workspace.ml
---

**Depends on:** None.

## The problem

The operator:

- On `sol_cli_workspace_scan.ml`: "should we update our structure to parse into an AST and use that everywhere instead of sys commands?"
- On `discover_topics`'s `Ok (topics @ acc)`: "we'd parse into an object instead of strings".
- On `discover_migrations`: "think I saw a function for comparing migration counts, maybe that can be part of this / easily computed from the AST?"
- On `Sol_cli_workspace.pending_migration_count`: "pipe into Array.fold_left. Maybe record the function as 'count unapplied migrations' instead of it being anonymous".

Today each question re-reads the disk its own way:

- services: `Sol_cli_manifest.scan_workspace` / `discover_services`;
- topics, schema subjects and migrations: `Sol_cli_workspace_scan.discover_*`;
- pending migrations: `Sol_cli_workspace.pending_migration_count`, a second reader of `db/migrations`;
- targets: `Sol_cli_config.discover_target_paths`.

`git grep` finds 18 call sites of these discovery functions (origin/main, 2026-09-26). A command that asks two of them scans twice and can see two different workspaces. Results are strings and lists of strings, not a model.

## Remediation

- A `Sol_cli_workspace_model.t`, read once per command from the entered workspace root: services with their primitive, language and `sol.toml`; topics; schema subjects; migrations (typed, with their versions and dispositions); the declared targets. Loading is one `result`-returning function whose errors name the file.
- The discovery functions become projections of the model. `pending_migration_count` becomes a named function over the model's migrations; the operator's "count unapplied migrations".
- Commands load the model at the edge, beside `Sol_cli_workspace.enter_cwd`, and pass it down, rather than calling the scanners.

## Acceptance criteria

- One reader of each workspace fact. `git grep` shows the scanners called only by the model loader. List the output.
- The loader has tests over the fixture workspaces (`examples/pluto`, `internal/fixtures/*`), including malformed-file errors that name the file.
- Command behaviour is unchanged: the CLI suites and the offline harness pass.
- Demo/example: not applicable (internal). Language parity: the model carries each service's declared language; no parity impact beyond that.

## Completion notes

**Premise re-verified (2026-09-27, `origin/main` 4fd4a278).** The scanners were
still the readers: `Sol_cli_manifest.scan_workspace` (`sol_cli_manifest.ml:77`),
`discover_services` (`:110`), `Sol_cli_workspace_scan.discover_{topics,
schema_subjects, migrations}`, `Sol_cli_config.discover_target_paths` (`:1232`),
and `Sol_cli_workspace.pending_migration_count` (`:181`) — 18 call sites across
`cli/bin` and `cli/lib`, plus a fifth reader the ticket's list missed,
`cmd_status.ml`'s `discover_domains`, which walked `app/` itself.

**Shape.** `cli/lib/workspace/sol_cli_workspace_model.{ml,mli}` is the one
reader. `load ~root` reads the workspace once and returns typed facts:

- `workloads`: each `Sol_cli_manifest.service` with `has_dockerfile`, the
  `language` its `sol.yml` entry declares, and its parsed `sol.toml`;
- `topics` / `schema_subjects`: `Sol_cli_plan_ids` newtypes;
- `migrations`: `Migration_file.t` with `version` / `name`
  (`Sol_cli_migration.parse_version`) and the authored `disposition`;
- `targets`: the declared `<env>/<provider>/<region>` list;
- `app_dir`, so "there is no `app/`" stays distinguishable from "`app/` is
  empty" (the two `sol check` messages).

`count_unapplied_migrations : t -> int` is the operator's "count unapplied
migrations", the anonymous fold gone — a `.down.sql` reversal is not counted.
`Sol_cli_workspace.pending_migration_count` is deleted.

Each scanner now takes the `~root` it reads (no argument = the old cwd
behaviour, paths spelled identically), and the model loader is its only
production caller. The scanners also kept their policies (a missing `events/`
is not an unreadable one), which is why the model composes them instead of
re-implementing them.

Commands load the model at the edge and pass it down: `cmd_up`, `cmd_deploy`
(in `deploy_context.facts`), `cmd_check`, `cmd_status`, `cmd_logs`, `cmd_fn`,
`cmd_secret`, `cmd_local`, `cmd_target`, `cmd_migrate`, `cmd_rollback`, and
`Sol_cli_check` / `Sol_cli_deployment_plan` / `Sol_cli_factory` /
`Sol_cli_up_execution` / `Sol_cli_substrate` take it as a parameter. The plan
takes its topics/migrations/schema subjects *and each unit's `sol.toml`* from
the model, so a deploy reads no workspace file twice. `ecr_repositories_var`
moved from `Sol_cli_config` to `Sol_cli_terraform_vars` — the config layer is
below the model and must not read the workspace itself.

**Acceptance: the scanners called only by the model loader.** `git grep` over
the production tree (`git grep -n <pattern> -- cli/lib cli/bin`):

```
cli/lib/workspace/sol_cli_workspace_model.ml:99:    match Sol_cli_manifest.scan_workspace ~root () with
cli/lib/workspace/sol_cli_workspace_model.ml:109:    Sol_cli_workspace_scan.discover_topics ~root ()
cli/lib/workspace/sol_cli_workspace_model.ml:113:    Sol_cli_config.discover_target_paths ~root ()
cli/lib/workspace/sol_cli_workspace_model.ml:126:    Sol_cli_workspace_scan.discover_migrations ~root ()
cli/lib/workspace/sol_cli_workspace_model.ml:138:    ; schema_subjects = Sol_cli_workspace_scan.discover_schema_subjects ~root ()
```

Those five lines are the only production *calls*; every other hit for those
names is a definition, an `.mli` declaration, or prose (`sol_cli_status.ml:187`,
`sol_cli_toml.mli:101`). `Sol_cli_workspace.pending_migration_count` has no
hits — it is gone. `discover_services` is called by `scan_workspace` only, so
it is absent from the list above. The remaining `app/` walkers are the model's
consumers: `cmd_status.discover_domains` and `Sol_cli_check` are projections of
`workloads` + `unexpected`, and `reader`-style reads of *specified* directories
stay where they belong (`Sol_cli_migration.required ~dir` for the deploy gate,
`Sol_cli_migration_disposition.read_file` for a file's own header, `read_migration_files`
for `sol migrate`'s `--dir`) — none of those reads the workspace's own layout.

**Acceptance: loader tests.** New `cli/test/test_workspace_model.ml` (registered
in `cli/test/dune`), 9 cases: `examples/pluto` (five workloads with their
primitives and declared OCaml/TypeScript languages, `payments.Charged`, the one
migration with version 1 / name `notifications` / no disposition, four declared
targets, `count_unapplied_migrations = 1`); `internal/fixtures/venus` (two
domains, two schema subjects, no targets); `internal/fixtures/local-demo` (no
`sol.yml`, no `app/` — an empty workspace, not an error); a malformed `sol.yml`,
`sol/environments.yml` and `events/*/sol.toml` each failing with the file named;
and a malformed workload `sol.toml` carried as a finding rather than failing the
load (it is what `sol check` reports).

**Acceptance: behaviour unchanged.** `dune test cli/test/ --force` passes (70
suites, including the 9 new cases); the framework unit suites
(`sol-env sol-fn sol-obs sol-runtime sol-svc sol-worker`) pass; and the offline
CI guard harness passes: `test_classify_changes`, `test_support_refs`,
`test_examples_self_contained`, `test_platform_assets_owner`,
`test_workflow_paths`, `test_authority_check`, `test_hook_install`,
`test_ticket_move`, `test_ticket_transitions`, `test_ocamlformat`,
`test_cloud_lifecycle_offline`, `test_framework_doc_signatures`,
`test_no_account_artifacts`, `test_public_cloud_lifecycle`, `test_provider_roots`,
`test_provider_dispatch_check`, `test_operator_diagnostics_check`,
`test_readiness_invocations_check`. One deliberate test change:
`test_deployment_plan`'s "surfaces TOML parse error" asserted the relative path
`app/payments/charge_svc/sol.toml`, which `Sol_cli_workspace.at_root` produced
only because that fixture has no `sol.yml`; the plan now takes the parsed
`sol.toml` from the model, which knows its root, so the message names the same
file by its root-joined path. The assertion now checks the file is named rather
than the spelling.

Two consequences of reading once, stated rather than discovered later:

- This is a *strict* loader for malformed content (the ticket asks for that:
  "errors name the file"). A command that never used to read `events/` or
  `sol.yml` — `sol rollback`, `sol target`, `sol secret`, `sol logs` — now fails
  closed on a malformed one, naming it, instead of acting on a workspace it
  could not fully read. That is deliberate: a diagnostic or recovery command
  acting on a half-read workspace is the confusion this ticket removes. The CLI
  suites (including the command-level ones) pass unchanged.
- A workspace with no `app/` is not a failure: an infra-first workspace loads
  with no workloads, and `ecr_repositories_var` still answers `[]` for it
  (INFRA-074 keeps a *failure* an error, never "no repositories").

**Demo/example: not applicable (internal) — no user-facing surface changed.**
Generated manifests, `sol.toml`/`sol.yml` fields, CLI grammar and command output
are unchanged; the scanners' own messages keep their spelling (a `~root`-less
call passes paths exactly as before).

**Language parity: no impact.** The model carries each service's declared
language (`Sol_cli_compat.language option`, read from `sol.yml`, never inferred)
where the plan previously looked it up itself; nothing about the cross-language
contract, the Confluent wire format, trace propagation or the metric vocabulary
changes.

