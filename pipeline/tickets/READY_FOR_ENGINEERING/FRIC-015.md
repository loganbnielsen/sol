---
id: FRIC-015
type: dogfood-finding
severity: high
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Scaffold output, generated workspace README, and several docs still instruct users to run `sol dev up` / `sol dev run`, which no longer exist

**Description:** REFAC-083 renamed `sol dev up`, but the sweep was incomplete. The current CLI exposes `sol local infra up` (substrate) and `sol local run` (run services); there is no `sol dev` command and no `sol local up` either. Stale references observed live and by grep:
- `cli/sol/lib/sol_cli_cmd_new.ml:164` — the scaffold's own "Next steps" prints `sol dev up` (and `sol status`).
- `cli/sol/lib/sol_cli_scaffold_templates.ml:49-50` — the generated workspace `README.md` prints `sol dev up` and `sol dev run`.
- `.claude/skills/dogfood/SKILL.md:77,95`
- `.claude/skills/ux-audit/SKILL.md:48-49`
- `.claude/CLAUDE.md:81`
- `docs/planning/ROADMAP.md:88,109,159`
- `docs/architecture/devops-pipeline.md:95`
- `docs/audits/AUDIT.md:94,107-108,141`

**Impact:** A first-time user's very first post-scaffold instruction fails with `unknown command dev`. The generated README is the artifact a user trusts most about "how do I run this?", and it documents two commands that do not exist. This is the same drift class as FRIC-014 (checked-in artifacts not re-synced after a rename).

**Remediation:** Sweep every reference to the pre-REFAC-083 names to the current commands (`sol local infra up`, `sol local run`, `sol local status`, `sol migrate`). Add a regression check that the scaffold's printed next-steps and generated README contain no `sol dev` token (e.g. extend `cli/sol/test/test_workspace.ml`). Optionally add `sol dev` as a one-line tombstone that errors with a pointer, for stale muscle memory.

Related: REFAC-083 (the rename), FRIC-014 (same drift class), FRIC-020 (`sol status` in the same next-steps block).
