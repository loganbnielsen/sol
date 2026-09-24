# FND-0032 — A migration is identified by version alone: a second `NNN_` file after `NNN` is applied is never run, and the deploy gate reports OK

- **Classification:** `VERIFIED_DEFECT`
- **State:** `FIXED_UNQUALIFIED` for the version-identity defect (BUG-041, 2026-09-23: Sol and pg-eio refuse shared versions; down files excluded; unit tests + mutation checks). Checksums remain open as FEAT-094.
- **First identified:** 2026-09-23, correctness audit
- **Last verified:** 2026-09-23 (`origin/main @ f3e9480b`; pg-eio from the opam switch sources)
- **Derived ticket:** `BUG-041`, `FEAT-094` (BACKLOG — checksums)
- **Invariant:** AUDIT-069 (`sol_cli_migration.ml:1-14`): *required (from
  db/migrations) ⊆ applied (from schema_migrations)*. Every migration in the directory
  must be applied before the revision deploys.
- **Evidence class:** `MECHANISM` for the Sol gate (probe below); `STATIC` for the
  pg-eio runner.

## What is established

Both halves key a migration on its **integer version** and discard the name:

- **Runner** (pg-eio `lib/migration.ml`, `apply`):
  `pending = List.filter (fun (v, _, _) -> not (List.mem v applied)) migrations`, and
  the tracking table's primary key is `version`.
- **Deploy gate** (`cli/sol/lib/sol_cli_migration.ml:114`):
  `unsatisfied` keeps a required migration only if `not (List.mem p.version applied)`.

A directory holding two files with the same version is not rejected by either side.
The usual way to get there is two branches that each add "the next" migration:
`004_add_refunds.sql` lands and is applied; `004_add_invoices.sql` merges later. The
runner sees version 4 as applied and skips `004_add_invoices`, **forever and without a
message**. The gate compares versions, finds 4 applied, and prints
`Migrations: OK -- N declared migration(s) present in schema_migrations`.

(On a fresh database both files are pending. The second insert of version 4 hits the
primary key and the run fails loudly. The silent case is exactly the one that happens
in practice: the existing environment.)

A second inconsistency in the same model: pg-eio's `parse_filename` excludes
`*.down.sql`, but Sol's `required` (`:60`) does not. `002_x.down.sql` becomes a
required migration `{version = 2; name = "x.down"}`. Only the version-only comparison
makes that harmless, so fixing the identity without fixing this would break every
workspace that has a down file.

### Reproduction (run 2026-09-23)

`db/` holds `001_create_orders.sql`, `001_add_customers.sql`, `002_x.sql`,
`002_x.down.sql`. The probe links `sol_cli`:

```ocaml
let req = Result.get_ok (Sol_cli_migration.required ~dir:"mig/db") in
Sol_cli_migration.unsatisfied ~required:req ~applied:[1; 2]
```

```text
required = [001_add_customers; 001_create_orders; 002_x.down; 002_x]
applied versions = [1; 2]; unsatisfied = []  (001_add_customers never ran)
```

## Also recorded (not in the ticket)

There is no content checksum. Editing an already-applied migration file is silently
ignored by both runner and gate. That is a separate design question (Flyway/sqlx-style
checksum validation). It is recorded here so a fix to the identity does not claim to
cover it.

## Impact

High. Silent schema divergence between environments, with the production gate that
exists to prevent exactly this ("not rolled out against a known-incompatible database
migration state") reporting success.

## Remedy shape

Reject duplicate versions at read time, in both pg-eio's `read_migrations` and Sol's
`required`, with an error that names both files. Make Sol's `required` exclude
`*.down.sql` the way the runner does. Optionally compare `(version, name)` in the gate,
since the table stores `name`.

## Related

AUDIT-069 (the gate); FND-0026 (missing-vs-unreadable migrations dir); INFRA-013's
mention of "same version" is unrelated (a chart pin).
