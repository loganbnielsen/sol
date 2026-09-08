---
id: REFAC-073
type: refactor
severity: low
source: architecture discussion with user, 2026-09-08
---

**Depends on:** REFAC-072 (work in sequence, not concurrently — see REFAC-071 for the full sequencing note and the four-part decision this belongs to).

Rename `tools/` to `devtools/`

## Decision

`tools/` is heavily used, not random — it holds `soldev` (the pipeline CLI that every ticket move in this repo runs through), `perf` (the perf baseline this repo's own test runner tracks and enforces on every commit), `ci` (a platform-component drift checker), `hooks` (this repo's pre-commit/post-commit hooks), and `sol_process` (a shared process-execution library used by the others). The name "tools" doesn't communicate that distinction, though — it reads like a junk drawer, and next to `cli/sol` (the product) it's ambiguous whether these are also user-facing. Renaming to `devtools/` makes the "repo-internal, never shipped" boundary explicit.

## Remediation

- `git mv tools devtools`.
- Update every `dune`/`dune-project` reference to `tools/soldev`, `tools/perf`, `tools/ci`, `tools/hooks`, `tools/sol_process`.
- Update `tools/hooks/pre-commit` and `post-commit` themselves (their own internal path references, and wherever `.git/hooks/` or a setup script points at them).
- Update `.claude/CLAUDE.md`, `README.md`, and any doc that names these paths.
- Grep the whole repo for `tools/soldev`, `tools/perf`, `tools/ci`, `tools/hooks`, `tools/sol_process`, and bare `tools/`.
- Run the full local test suite before submitting, and confirm the git hooks still fire correctly post-rename (make a throwaway commit in the worktree and check the hook output).
