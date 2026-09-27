---
id: REFAC-137
type: refactor
severity: low
title: Carry the code conventions into framework/ocaml and soldev -- Result.Syntax, blank env at one boundary, one exit
source: pattern audit of the REFAC-104..130 series (2026-09-26); CONTRIBUTING's conventions were applied to cli/ only
premise: '! rg -q --glob ''*.ml'' ''let \( let\* \) ='' framework internal/tooling'
---

**Depends on:** None.

## The problem

`CONTRIBUTING.md § Code conventions` says each rule "is applied across `cli/`", and it was. The rest of the OCaml in this repository still carries the patterns the CLI removed (counts 2026-09-26):

| Pattern | `framework/ocaml` | `internal/tooling` |
|---|---|---|
| hand-written `let ( let* ) = Result.bind` (a test rule refuses it in `cli/`) | 10 | 0 |
| `Some v when String.trim v <> ""` / `Some ""` at the use site | 7 in lib (`sol-svc/lib/peer.ml`, `service.ml` ×2, `auth_internal.ml`, `sol-fn/lib/fn.ml`, `kafka_service_config.ml` ×2) | 3 (`soldev_ticket.ml` ×2, `soldev_merge.ml`) |
| `exit N` below the entry point | 0 in lib | 21 in `soldev_merge.ml` |

The framework's env reads each decide blank on their own: some trim, some don't, and each builds its own `Sys.getenv_opt` match.

## Remediation

- `Result.Syntax` everywhere; extend the `cli/test/dune` rule (or an `internal/ci` guard) to the whole repository's `.ml`, still exempting the scaffold templates.
- Framework: one env reader per package boundary (a tiny shared `Sol_env`-style helper, or one private function per package if a shared library would create a new dependency edge -- decide by the graph), with blank = unset, used by every framework `Sys.getenv_opt` for a setting. Behaviour for set, unset and blank values is unchanged where it was already "blank = unset"; any site that changes is listed.
- soldev: pipeline steps return `result`; the command entry converts once (REFAC-115's rule).
- soldev: ticket frontmatter is read with the `yaml` library (as REFAC-106 did for `sol.yml`), not split on the first `:` by hand in `soldev_ticket.ml`'s `parse_frontmatter`. Today a quoted value is not unescaped, so a `premise:` probe written with YAML escapes (`"\\("`) runs with doubled backslashes and silently matches nothing -- found while filing this ticket.

## Acceptance criteria

- `rg -n --glob '*.ml' 'let \( let\* \) =' framework internal/tooling cli` finds only the scaffold templates.
- The widened guard fails on a planted hand-written `let*` in `framework/` (positive control).
- `rg -n 'exit [0-9]' internal/tooling/soldev/lib` lists only the entry point, or each remaining site with its reason.
- `dune test framework/` and the soldev tests pass.
- Demo/example: not applicable (internal).
- Language parity (DEC-022): the env-reading contract (blank = unset) is application-facing; the completion notes state whether `@sol-fab/*` treats a blank env value the same way, or record the gap.

## Completion notes

**Premise verified (2026-09-27, `origin/main` at `cf199c5b`):** `git ls-files '*.ml' | xargs grep -n 'let ( let\* ) ='` listed 10 framework sites, plus the local demo, the venus and pluto events and three scaffold templates; the framework had four private `env_nonempty` copies with three different rules; `soldev_merge.ml` held 21 `exit` calls.

- **`let*` is `Result.Syntax` everywhere.** Every hand-written `let ( let* ) = Result.bind` in the repository is gone -- framework, fixtures, pluto's events and the three scaffold templates (so a new workspace models the convention; `test_scaffold` asserts `open Result.Syntax` in the generated event). The `cli/test/dune` rule, which covered `cli/` only and still exempted the since-deleted `sol_cli_scaffold_templates.ml`, is replaced by `internal/ci/check_result_syntax.sh` over every tracked `.ml`, with `test_result_syntax.sh` (a framework site and a local example site each fail; both `Result.Syntax` forms pass). Both run in CI.
- **One settings rule in the framework.** `Sol_runtime.setting` (trimmed; unset or blank is `None`) replaces `sol-svc`'s two copies (`service.ml`, `peer.ml`) and `sol-fn`'s. `sol-obs` and `kafka-eio-service` are separate packages that do not depend on `sol-runtime`, so each keeps one private `setting` with the identical rule rather than gaining a package edge. **Behaviour that changed, all toward "blank is unset":** `sol-obs` treated `LOKI_URL=" "` as a URL (it did not trim); `kafka-eio-service`'s `env_or` treated `" "` as set for `SOL_KAFKA_DURABILITY` and the substrate addresses; `service.ml`'s check trimmed but kept the untrimmed value; the unverified-JWT opt-in now accepts `" 1 "` as `1`. Tests: `framework/ocaml/sol-runtime/test/test_setting.ml`.
- **soldev: one exit.** `Soldev_exit` (`failure = { message; code }`, `error`, `reported`, `exit_on`); every `run_*` returns a result and `cmd_pipeline.ml` converts it once. `rg -n '\bexit [0-9]' internal/tooling/soldev/lib` now lists only `Soldev_exit.exit_on`. Exit codes and messages are unchanged (checked with the rebuilt binary: `check` on an unknown ticket exits 2, a stale premise 1, an actionable ticket 0). Found along the way: a review result that was not JSON, or had the wrong shape, escaped `pipeline review` as an uncaught exception; it is now `error: the review result is not JSON: …` (exit 1).
- **soldev reads frontmatter with the yaml library.** The hand-split parser kept quotes and did not decode escapes -- this ticket's own probe, written `"…\\(…"`, ran with doubled backslashes and matched nothing (found while filing it). `Soldev_ticket.frontmatter` parses YAML, drops blank/null values at the boundary (so `premise_verdict`'s empty-probe case and `ticket_title`'s re-trim are gone), and reports an invalid block; `pipeline ls` shows `invalid-frontmatter: …` and `check` fails on one instead of reading no fields. The unused `set_frontmatter_field` is deleted. **Every ticket must now parse**: a PyYAML sweep of all 781 frontmatters found 6 invalid (unquoted `: ` in a value, a leading `` ` ``, and two of this audit's own tickets) plus one whose title YAML would cut at ` #main` (BUG-059); all seven are quoted, meaning unchanged, and `test_ticket` asserts every ticket in the repository parses. AGENTS.md states the quoting rule.
- **Verified:** `dune build`; `dune test internal/tooling framework cli/test --force` -- the only failures are `kafka-eio-service`'s 14 broker-dependent integration tests (`Connection refused`, no local Redpanda), identical on `origin/main` in a scratch worktree; format clean; `check_result_syntax.sh` + mutation test pass.
- **Demo/example:** pluto's and venus's event modules, the scaffold templates, and pluto's TypeScript demo (below) are updated.
- **Language parity (DEC-022):** the blank-is-unset rule is application-facing. `@sol-fab/svc`, `@sol-fab/worker` and `@sol-fab/kafka` read no environment (checked in `sol-typescript` and `sol-kafka`; the app passes configuration in), so the rule lives in the app. Pluto's `demo_ts` applied it inconsistently -- `LOKI_URL`/`TEMPO_URL`/`POSTGRES_URL`/`PUSHGATEWAY_URL`/`ORDERS_TOPIC` were read raw, so `" "` counted as set -- and its `intEnv` fell back on a malformed `PORT`, citing an OCaml behaviour BUG-046 had already changed to an error. Both services now use one `setting()` helper with the same rule and refuse a malformed integer; `npm run build` for both passes. Verdict: already equivalent in the framework packages (they read nothing); the demo now matches.
