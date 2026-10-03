---
id: INFRA-065
type: refactor
severity: low
title: Consolidate the ~44 hand-rolled `contains` substring helpers in the test suite
source: review question on INFRA-064 — "why the custom needle-in-haystack? there should be an existing function or package"
---

**Depends on:** none.

## The duplication

OCaml's stdlib has **no substring search**: `String.contains`, `index_opt`,
`rindex_opt` and friends are all **char**-only, and `starts_with`/`ends_with` are
prefix/suffix. So each helper is individually justified — but the repository has
roughly **44 copies**, in **four incompatible signatures**, so a call site does
not tell a reader which way round the arguments go:

| Shape | Where |
|---|---|
| `contains needle haystack` | `framework/ocaml/sol-fn/test`, `test_alerting.ml`, `test_dev_observability.ml`, `test_run_log.ml`, `test_secret.ml`, … |
| `contains haystack needle` | `test_scaffold.ml`, `test_migration.ml`, `test_manifest_render.ml`, `test_rollout_diagnosis.ml`, … |
| `contains ~needle haystack` | `test_config.ml`, `test_profile.ml`, `test_workspace.ml`, `test_destination.ml`, `test_substrate.ml`, … |
| `contains re s` / `contains s ~needle` / `contains_substring ~needle s` | `test_rollback.ml`, `test_process.ml`, `test_deployment_plan.ml`, `internal/tooling/soldev/lib/soldev_ticket.ml`, … |

Plus `cli/sol/bin/cmd_cloud_tf.ml:65` in production code.

`contains a b` therefore means opposite things in adjacent files, and every new
test re-derives the same scan loop.

## Remediation

1. **One shared helper, one signature** — e.g. `contains ~needle haystack : bool`,
   labelled so a call site reads unambiguously — in a place the `cli/sol` tests and
   the framework tests can both use. **No new dependency is needed**: `str` is
   already a dependency of `cli/sol/test`
   (`(libraries sol_cli alcotest unix yojson str)`), and `Str` also covers the
   regex-shaped copies.
2. **Migrate the copies**, and prefer the stdlib where the helper is really a
   prefix/suffix test (`String.starts_with` / `String.ends_with`).
3. **Prefer exact assertions where the value is deterministic.** A substring match
   is weaker than equality: `INFRA-064`'s retention test asserts the precise
   `Error` value rather than searching its text.

## Acceptance criteria

- One helper, one signature, used by every test that needs a substring search; no
  file-local `contains`/`contains_substring`/`contains_needle` remains.
- Call sites read unambiguously — the ambiguity above is the actual defect, more
  than the duplication.
- No new dependency.
- `dune fmt` clean (CI's Format check), and the touched suites still pass.

## Why this is `BACKLOG` and `low`

It is real but mechanical: ~44 files of test churn with no behavioural change, so
it should be prioritised deliberately rather than picked up as drive-by work. The
one thing worth keeping in view is that the *signature* inconsistency is a
correctness hazard (a reader can invert the arguments), not just tidiness.

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `rg "let contains|let contains_substring|let contains_needle" --glob "*.ml"` finds 49 definitions in four signatures.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

**Premise re-checked before pickup** against `origin/main @ 33229d78`:
`rg -n 'let contains|let contains_substring|let contains_needle' --glob '*.ml'` found 47
definitions in the same four incompatible signatures (49 at the ticket's date; the
`cmd_cloud_tf.ml` production copy the ticket lists is already gone).

**What changed.** Every file-local substring helper is gone, and each call site names the
helper its own package already owns — all three now share one signature,
`~needle:<needle> <haystack>`:

- **CLI** (`cli/test/**`, 33 files): `Sol_cli_string.contains ~needle`, the library helper
  the CLI's production code already uses (`sol_cli_kubectl`, `sol_cli_secret`,
  `sol_cli_gcp_absence`, …). Most of these were one-line re-exports whose *argument order
  differed from the canonical helper's* — `contains haystack needle` in one file,
  `contains needle haystack` in the next — and that inversion is the actual defect.
- **soldev** (`internal/tooling/soldev/test/**`, 2 files): `Soldev_string.contains_substring
  ~needle`, the helper `soldev_merge`/`soldev_ticket` already use.
- **Framework** (`framework/ocaml/*/test/**`, 6 files): `Sol_runtime.contains_substring
  ~needle`, added to `sol-runtime` — the framework's shared plumbing package, already a
  dependency of every app shape — because the framework had no shared substring helper and
  each of the six suites carried its own. `sol-obs`'s and `kafka-eio-service`'s *test*
  stanzas gain `sol_runtime`; no library dependency changes.
- **Four regex matchers keep their `Str` implementation and are renamed `matches_regex`**
  (`test_boundary_lease`, `test_cloud_destroy`, `test_deployment_plan`, `test_rollback`).
  They are not substring searches, and downgrading them to one would weaken their
  assertions — the failure mode the ticket's third remediation point warns about.

**One signature everywhere; one helper per package, not one repo-wide.** The acceptance
criterion's literal single helper is not reachable without a new cross-package test-support
package: `Sol_cli_string` belongs to the CLI library, `Soldev_string` to soldev, and the six
framework suites have no shared test library — `windtrap`, which they all already depend on,
does not export its own `Text.contains_substring`. A published `sol-test-support` package is
a DEC-025 release-train decision, not a low-severity dedup, so this ticket did not take it.
What it did remove is the hazard the ticket names as the defect: no call site can now be
read with the arguments inverted, and no file-local copy remains.

**No new dependency:** neither `str` nor anything else was added beyond the framework helper
above; the four regex matchers already used `Str`, which was already a CLI test dependency.

**Checks.**

- `dune build` (whole workspace), `dune fmt` + `internal/ci/check_ocamlformat.sh --all`,
  `internal/ci/check_no_comments.sh` (863 files): green.
- `dune test cli/test framework/ internal/tooling/soldev/test`: every suite passes except the
  two `Test_scaffold` compile tests (`existing_files: scaffold actually compiles`,
  `existing_files: bare fn library compiles`). Both fail **identically on unmodified
  `origin/main @ 33229d78`**, verified in a separate pristine worktree — they scaffold a
  workspace and run `dune build` inside it, which needs an opam toolchain in the test
  sandbox. Not this change (BUG-130's completion notes record the same pair).
- `internal/ci/run_fast_checks.sh`: green (`verify always` / `verify static` included).
- No `contains`/`contains_substring` definition or call remains outside the three canonical
  helpers.

**Behaviour is unchanged** — every rewrite is an argument-order-preserving call-site change
over the same scan, and the suites that assert on those strings are the evidence.

**Demo/example coverage:** not applicable — test-suite churn with no author-facing surface.
**Language parity (DEC-022):** no impact — OCaml test suites only, no framework contract
change.

