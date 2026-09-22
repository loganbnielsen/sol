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
