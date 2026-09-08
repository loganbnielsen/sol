---
id: AUDIT-053
type: audit-finding
severity: high
source: codebase review 2026-06-14
branch: AUDIT-053/postgres-aware-migration-execution
worktree: /home/lbendtly/Code/sun-AUDIT-053-postgres-aware-migration-execution
---

Fix migration execution so SQL is not split with `String.split_on_char ';'`

**Depends on:** None.

**Description:** The current `integrations/storage/sun-storage/lib/migration.ml` implementation still defines:

```ocaml
let split_statements sql =
  String.split_on_char ';' sql
```

Both `apply` and `rollback` execute the resulting statement list. This is a handcrafted SQL splitter.

**Impact:** PostgreSQL migrations commonly contain semicolons inside function bodies, triggers, procedural blocks, strings, comments, and dollar-quoted sections. Splitting on every semicolon corrupts valid migrations and can make rollback fail in the same way. This is especially risky because migration failures happen during deploy or local onboarding.

**Remediation:**

1. Prefer executing each migration file as a single statement batch inside the existing transaction, if Caqti/PostgreSQL driver behavior supports multi-statement execution reliably.
2. If batch execution is not suitable, use a PostgreSQL-aware parser/lexer rather than raw semicolon splitting.
3. Add regression tests for:
   - semicolons inside string literals;
   - line and block comments;
   - dollar-quoted function bodies;
   - matching `.down.sql` rollback cases.

**Acceptance criteria:**

- A migration containing a PostgreSQL function body with internal semicolons applies successfully.
- The corresponding `.down.sql` rollback succeeds.
- Statement execution remains transactional.
- Existing storage tests continue to pass.

## Review — automated checks passed
Naive semicolon splitting fully replaced with batch execution via ~oneshot:true; all 4 regression tests present and registered; build clean; no ticket files touched.

## Review — automated checks passed
PostgreSQL-aware SQL splitter implemented as a state machine; all 5 unit tests and 3 integration tests pass without POSTGRES_URL; no project/tickets/ changes in diff.
