---
id: AUDIT-067
type: audit-finding
severity: low
source: project/audits/2026-09-08_audit.md
---

`pg-eio`'s unused `Migration.default_table` default still says `sun_schema_migrations`

**Description:** `~/Code/pg-eio/lib/migration.ml:240` sets `default_table = "sun_schema_migrations"`, a leftover from before the `sun` → `sol` rename. It causes no live bug today: `sol`'s CLI (`cli/sol/bin/cmd_migrate.ml`) always passes an explicit `~table` computed as `sol_<workspace>_schema_migrations`, so the workspace-isolation invariant holds at the `sol` layer regardless of this default.

**Impact:** Low — cosmetic today, but a landmine for any future direct `pg-eio` consumer (or a new `sol` call site) that forgets to pass `~table` explicitly: they'd silently get a table named after a product that no longer exists, and it wouldn't be namespaced to their workspace either.

**Remediation:** Rename `default_table` to `"sol_schema_migrations"` in `~/Code/pg-eio/lib/migration.ml`. No deprecated alias or migration path needed (pre-alpha, no backwards-compatibility constraint per `~/Code/CLAUDE.md`) — change the literal and re-pin `pg-eio` into `sol`'s opam switch.

## Progress (2026-09-08)

Fixed in `~/Code/pg-eio` — commit `9dcfb86` on branch `fix/default-table-sol-rename`, opened as pg-eio PR #20 (https://github.com/loganbnielsen/pg-eio/pull/20). Build + full pg-eio test suite pass locally. Did not merge that PR myself — it's a separate repo outside this session's merge authorization for `sol`'s own ticket pipeline. Left `sol`'s `pg-eio` opam pin untouched (still points at the pre-fix commit) since re-pinning to an unmerged feature branch is fragile; re-pin once PR #20 merges to `pg-eio`'s `main`, then move this ticket to DONE.

Note: found and cleaned up an unrelated slip — my fix commit initially landed on `~/Code/pg-eio`'s pre-existing `codex/create-pool-of-env` branch (someone else's in-progress work, 2 commits ahead of `main` at the time) instead of a fresh branch off `main`. Caught it before pushing, reset that branch back to exactly match `origin/codex/create-pool-of-env`, and moved the fix to its own branch. No impact on that other work.

## Resolution (2026-09-08)

pg-eio PR #20 merged (`16d8c66` on `pg-eio`'s `main`). Re-pinned via `opam pin add pg-eio ~/Code/pg-eio -y` (also incidentally fixed a stale local pin that had been pointing at `codex/create-pool-of-env` instead of `main` — unrelated to this ticket, worth someone double-checking that other branch's own status separately). `rm -rf _build && dune build` clean; `dune test framework/` and `dune test cli/sol/` both pass in full, including the migration-path-relevant `pending_migrations`/golden scaffold tests. No `sol`-repo file changes needed for the re-pin itself — opam pins are local switch state; this repo tracks no lockfile/pin-depends for it, consistent with `~/Code/CLAUDE.md`'s per-environment re-pin convention.
