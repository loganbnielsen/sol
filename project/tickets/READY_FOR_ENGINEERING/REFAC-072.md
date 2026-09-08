---
id: REFAC-072
type: refactor
severity: medium
source: architecture discussion with user, 2026-09-08
---

**Depends on:** REFAC-071 (work in sequence, not concurrently — see its ticket for the full sequencing note and the four-part decision this belongs to).

Rename `project/` to `pipeline/`

## Decision

`project/tickets`, `project/audits`, and `project/dogfood` are this repo's own engineering-process record (ticket state, audit reports, dogfood run logs) — administrative data, not code, and not anything an app built on Sol ever touches. "project" is generic and reads as if it might hold app/workspace content; the directory is already operated on exclusively by a tool literally named `soldev pipeline` (`tools/soldev`, itself being renamed in REFAC-073). Renaming to `pipeline/` names it after what it actually is and ties it to the existing command vocabulary.

## Remediation

- `git mv project pipeline`.
- Update every reference in `tools/soldev/` (this is the biggest surface — the pipeline CLI reads/writes `project/tickets/**` paths directly; grep `soldev_*.ml` and update all literal path constants).
- Update `.claude/CLAUDE.md`'s ticket-system section (the directory-per-status diagram, the "only ever modified in the main checkout" rule, all path examples).
- Update every skill doc that references `project/tickets/` or `project/audits/` or `project/dogfood/` (`audit`, `ux-audit`, `scaffold-audit`, `docs-audit`, `dogfood`, `work`, `review-worktree` skill files — this is a wide but mechanical find-and-replace).
- Update `docs/planning/ROADMAP.md`/`WORK_SUMMARY.md` and any other doc referencing the old path.
- Update CI workflows or hooks (`tools/hooks/pre-commit`, `tools/hooks/post-commit`, `tools/ci/*`) if they reference `project/` paths.
- Grep the whole repo for `project/tickets`, `project/audits`, `project/dogfood`, and bare `project/` to catch anything missed.
- Run the full local test suite before submitting, and specifically exercise `soldev pipeline submit/review/merge` end-to-end against a scratch ticket to confirm the rename didn't break the pipeline CLI's own path handling.
