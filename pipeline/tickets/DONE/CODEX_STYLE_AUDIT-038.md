---
id: CODEX_STYLE_AUDIT-038
type: refactor
severity: high
source: style audit
---

Validate storage table and column identifiers before SQL construction.

**Depends on:** none.

branch: CODEX_STYLE_AUDIT-038/storage-identifiers
worktree: /home/lbendtly/Code/sun-CODEX-038

**Problem:** `integrations/storage/sun-storage/lib/table.ml:3-5` accepts `table`,
`id_column`, and `columns` as raw strings, then interpolates them into SQL at
`table.ml:17-34`. Caqti parameters protect values, not identifiers.

**Goal:** Introduce a validated SQL identifier type for schema modules.

**Acceptance criteria:**

- Add an identifier constructor that rejects empty or unsafe table/column names.
- Change `SCHEMA` to expose validated identifiers or validate once when the
  functor is applied.
- Add tests for invalid table and column names.

## Review — automated checks passed
Implementation satisfies CODEX_STYLE_AUDIT-038: adds Table.Identifier, validates schema table/id/columns once when Table.Make is applied, rejects empty/unsafe identifiers, keeps SCHEMA strings ergonomic, includes invalid table/column tests, focused storage tests and dune build passed. Independent reviewer unavailable due usage limit; no baseline changes accepted.
