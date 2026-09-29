---
id: CODEX_STYLE_AUDIT-079
type: refactor
severity: medium
title: Validate job timing configuration before entering the runtime
source: internal/pipeline/audits/2026-09-28_code_layer_audit.md
---

Validate job timing configuration before entering the runtime

**Depends on:** None.

**Premise verified (2026-09-28):** Read the implementation at `framework/ocaml/sol-jobs/lib/sol_jobs.ml:32-48,225-243 and claim_q` and its representative callers/tests on origin/main `6a7b1fb5`. The described boundary remains present.

## Problem

Only max_attempts is validated. Nonpositive lease_s permits immediate concurrent reclaim; negative max_delay_s yields negative backoff; invalid or nonfinite intervals/jitter reach sleeps, Random or SQL.

## Remediation

Extend the existing configuration boundary with finite/range checks for lease, polling interval, retry delays and jitter. Preserve supported zero retry delays and negative unlimited attempt counts.

## Acceptance criteria

- Invalid timing values return Config before database access or signal registration; defaults, zero retry delay and unlimited attempt counts remain accepted. Add a focused runtime/config regression check.
- Update a runnable example/demo for application-facing behavior, or record why this is an internal-only refactor.
- Record the per-language capability verdict for framework/application contracts, or explain why language parity is unaffected.

## Completion (2026-09-29)

- **Premise re-verified** at origin/main `788e688d`: `validate_retry_policy` checked only `max_attempts = 0`, and `run` validated nothing else, so a nonpositive `lease_s` reached the claim SQL (`locked_until = now() + lease_s`), a nonpositive/`nan`/`infinity` `poll_interval_s` reached `Eio.Time.sleep`, and a negative `max_delay_s` produced a negative backoff.
- **Fix.** `run` now calls a new `validate_timing ~poll_interval_s ~lease_s` (both finite and `> 0`) and an extended `validate_retry_policy` (`base_delay_s`/`max_delay_s` finite and `>= 0`; `jitter_ratio` finite and within `[0, 1]`; `max_attempts = 0` still refused). Both run as the first `let*` steps of `run`, before `Pg_db.find` and before `with_runtime` installs the signal handler. Zero retry delays and negative (unlimited) `max_attempts` stay accepted.
- **Tests** (`framework/ocaml/sol-jobs/test/test_sol_jobs.ml`): `validate_retry_policy` refuses negative/`nan` delays, `infinity`/negative `max_delay_s`, and out-of-range (`2.0`, `-0.5`, `nan`) jitter while accepting zero delays and the default; `validate_timing` accepts positive values and refuses zero/negative/`nan`/`infinity` for both knobs; a **config-boundary** test builds a lazy `Pg_db.create_pool` pointed at an unused port and asserts `run ~lease_s:0.0` returns `` `Config `` naming `lease_s` — proving the failure precedes database access and signal registration rather than surfacing as `` `Database ``. All 11 tests pass.
- Validation: `dune fmt --preview` clean; `test_sol_jobs_pg.exe` still builds (its PG cases skip without `POSTGRES_URL`, as before).
- **Demo/example**: the only runnable caller outside the library is `internal/fixtures/local-demo` (and its e2e test), both using `poll_interval_s:0.2`, which the new validation accepts; no example change was needed. `framework/ocaml/sol-jobs/sol-jobs.md` documents the added boundary. **Language parity: no impact** — no framework convention or new concept changes; the validation tightens an existing OCaml config boundary, and no TypeScript jobs equivalent exists to diverge.
