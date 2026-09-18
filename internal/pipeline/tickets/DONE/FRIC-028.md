---
id: FRIC-028
type: dogfood-finding
severity: low
source: pipeline/dogfood/RUN_2026-09-13.md
---

**Depends on:** None.

Ubuntu's `/usr/games/sol` shadows the CLI when PATH isn't set correctly

**Description:** Ubuntu ships a solitaire game at `/usr/games/sol`, and `/usr/games` is commonly ahead of `~/.local/bin` in the default PATH. If the freshly built `sol` is not first, `sol` silently runs the game — e.g. `sol --version` prints `Unknown option --version` (observed when a helper shell's `source` failed and PATH fell through). The dogfood runbook does say to run `which sol`, but never names this specific collision, and the observable failure (an option-parsing error from an unrelated program) looks like a CLI bug.

**Impact:** Low but disorienting: a user can be "running sol" and getting game errors, with no hint that a same-named system binary is involved.

**Remediation:** Name the collision explicitly in `DOGFOOD.md`'s "Required on PATH" step (with a suggested `alias sol=...` or absolute path), and/or have `sol --version` print enough identity that it's obvious which binary answered.

Related: FRIC-019 (tool install/PATH hygiene).

## Completion notes

- Added an explicit `/usr/games/sol` warning to `docs/dogfood/DOGFOOD.md`'s "Required on PATH" section, naming the observed symptom (`Unknown option --version`) and the helper-shell (`sg`, `sh -c`) PATH gotcha.
- Doc-only; no example/demo update applies.
