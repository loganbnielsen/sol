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
- `docs/ROADMAP.md:88,109,159`
- `docs/architecture/devops-pipeline.md:95`
- `internal/pipeline/audits/AUDIT.md:94,107-108,141`

**Impact:** A first-time user's very first post-scaffold instruction fails with `unknown command dev`. The generated README is the artifact a user trusts most about "how do I run this?", and it documents two commands that do not exist. This is the same drift class as FRIC-014 (checked-in artifacts not re-synced after a rename).

**Remediation:** Sweep every reference to the pre-REFAC-083 names to the current commands (`sol local infra up`, `sol local run`, `sol local status`, `sol migrate`). Add a regression check that the scaffold's printed next-steps and generated README contain no `sol dev` token (e.g. extend `cli/sol/test/test_workspace.ml`). Optionally add `sol dev` as a one-line tombstone that errors with a pointer, for stale muscle memory.

Related: REFAC-083 (the rename), FRIC-014 (same drift class), FRIC-020 (`sol status` in the same next-steps block).

## Completion notes

- Swept the pre-REFAC-083 names out of every live surface: the scaffold's printed next-steps (`sol_cli_cmd_new.ml`), the generated workspace README (`sol_cli_scaffold_templates.ml`), the dogfood/ux-audit skills, `.claude/CLAUDE.md`, ROADMAP, devops-pipeline, the audit runbook, plus stale inline comments and one user-facing error string (`cmd_migrate.ml`: "Run 'sol dev up' first").
- Historical records (`pipeline/tickets/DONE/*`, past `pipeline/dogfood/RUN_*`) were deliberately left untouched — they describe the state at the time. The one surviving mention in `sol_cli_secret.ml` is an explicit note about the REFAC-083 rename and should stay.
- Verified by generating a throwaway workspace: both the printed next-steps and the generated `README.md` now say `sol local infra up` / `sol local run` and contain no `sol dev` token.
- No example/demo file embedded these commands (checked `examples/` as part of the sweep), so no runnable-example update applies.

- Also swept the **second-generation** stale name, `sol local up` (REFAC-083's target, itself since superseded): the README Quickstart, the reserved-env error message (`sol_cli_config.ml`) and its test assertion (`test_config.ml`), and a `cmd_local.ml` comment now all say `sol local infra up`.
- Verified `test_config.exe` (49 tests) passes after the message/assertion pair changed, and a full `dune build` is clean.
