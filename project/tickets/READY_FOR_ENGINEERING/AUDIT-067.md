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
