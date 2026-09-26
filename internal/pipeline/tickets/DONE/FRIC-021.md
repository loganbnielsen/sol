---
id: FRIC-021
type: dogfood-finding
severity: medium
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Documented `sol migrate --table <workspace>_migrations` diverges from the tool's default tracking table

**Description:** `internal/pipeline/dogfood/DOGFOOD.md` and `.claude/skills/dogfood/SKILL.md` both instruct `sol migrate --table <workspace-name>_migrations`. The tool's actual default is `sol_<workspace>_schema_migrations` (`cli/sol/bin/cmd_migrate.ml:16`, surfaced in `sol migrate --help`: `default: sol_<workspace>_schema_migrations`). Applying via the documented flag succeeds but writes a tracking table named `<workspace>_migrations`; a subsequent `sol migrate status` with no flag reads the default table, finds nothing, and reports every migration as pending.

**Impact:** A user who follows the docs once and then checks status is told their migrations never applied. Worse, they may re-apply or start debugging a migration bug that doesn't exist.

**Remediation:** Drop the `--table` flag from the dogfood runbook/skill and use the default (the migration SQL itself is table-name-agnostic for the tracked table), or document the real default and when overriding it is legitimate. Add a runbook note that `--table` changes where the *tracking* rows live, not the schema.

Related: FRIC-012 (migrations via one-shot Job from a target).

## Completion notes

- Removed the `--table <workspace>_migrations` override from `internal/pipeline/dogfood/DOGFOOD.md` and `.claude/skills/dogfood/SKILL.md`; both now use the tool default (`sol_<workspace>_schema_migrations`), which the Tutorial already documents correctly. The `--table` flag remains available and documented for genuine overrides.
- Doc-only; no example/demo update applies.
