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
