---
id: AUDIT-047
type: audit-finding
severity: medium
source: codebase review 2026-06-13
branch: AUDIT-047/sql-migration-parser
worktree: /home/lbendtly/Code/sun-AUDIT-047-sql-migration-parser
---

Replace semicolon-splitting migration execution with a PostgreSQL-aware migration runner

**Depends on:** None.

**Description:** `integrations/storage/sun-storage/lib/migration.ml` splits migration files with:

```ocaml
String.split_on_char ';' sql
```

and then executes each trimmed segment with a semicolon appended. This is a handcrafted SQL statement splitter.

**Impact:** PostgreSQL migrations commonly contain semicolons inside function bodies, triggers, procedural blocks, strings, comments, and dollar-quoted sections. Splitting on every semicolon will corrupt valid migrations such as `CREATE FUNCTION ... $$ BEGIN ...; END; $$ LANGUAGE plpgsql;`. The failure may appear only when a startup adds a realistic migration, and rollback uses the same splitter for `.down.sql` files.

**Remediation:**

1. Prefer executing each migration file as a single statement batch inside the existing transaction, if Caqti/PostgreSQL driver behavior supports multi-statement execution reliably.
2. If batch execution is not suitable, integrate a PostgreSQL-aware migration/parser approach instead of raw semicolon splitting. Options include using a maintained SQL parser if available in the OCaml stack, invoking `psql` only through the shared process abstraction from AUDIT-043, or implementing a small lexer that correctly handles PostgreSQL strings, comments, and dollar-quoted bodies.
3. Add regression tests with:
   - semicolons inside string literals;
   - line and block comments;
   - dollar-quoted function bodies;
   - matching `.down.sql` rollback for the same cases.

**Acceptance criteria:**

- A migration containing a PostgreSQL function body with internal semicolons applies successfully.
- The corresponding `.down.sql` rollback also succeeds.
- Statement execution still happens transactionally.
- Existing simple migration tests continue to pass.

## Review — automated checks passed
PostgreSQL-aware split_statements lexer fully replaces naive semicolon splitting; mli exposes the function; unit tests cover all required edge cases; build is clean.
