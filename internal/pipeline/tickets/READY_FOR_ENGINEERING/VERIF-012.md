---
id: VERIF-012
type: refactor
severity: low
title: A verification input sits in the docs-only allowlist, and comments outlive the defects they describe
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: '! rg -q "dune fmt --preview" .github/workflows/ci.yml'
---

A verification input sits in the docs-only allowlist, and comments outlive the defects they describe

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`:

- `internal/ci/classify-changes.sh:61` treats a change to
  `internal/tooling/perf/perf_baseline.json` as `docs-only`, so such a pull request skips the build,
  every suite and every product guard. Today the baseline gates nothing, so the exposure is bounded;
  the moment performance becomes a gate (VERIF-003), the allowlist must not contain a gate input.
- `.github/workflows/ci.yml:282-285` states that running `dune fmt --preview` first makes the CLI
  tests' `SOL_HOME` ancestor walk resolve to `_build/default` instead of the source checkout, which
  is why the format check runs after the unit step. The code already prevents that:
  `cli/lib/base/sol_cli_platform_assets.ml:62-68` excludes any directory containing a `_build` path
  component (`inside_build_context`) before `is_checkout` is consulted by `find_ancestor` at line
  145. The ordering constraint is no longer load-bearing, and the comment says it is.
- The `note` field in `internal/tooling/perf/perf_baseline.json` points at
  `./cli/platform/local/scripts/run_tests.sh`, a path that does not exist.

## Problem

Three small things that all mislead a reader about what is load-bearing. The allowlist entry is the
one with a real consequence: it is an accepted skip of all verification for a file that exists to
describe expected verification behaviour, and nobody has decided that explicitly. The stale comment
is the more insidious of the two comments because it describes a hazard the code has already
removed, which invites a future reader — human or agent — to protect an ordering that no longer
needs protecting, or to assume a test's meaning depends on sibling build state.

## Desired invariant

No verification input is in the docs-only allowlist without a recorded decision. Comments about
ordering and environment describe constraints the code still has. Paths named in committed data
resolve.

## Remediation

Decide whether a baseline change may ride the docs-only path, and record the decision next to the
allowlist entry (or move the file out of the allowlist). Correct or delete the `ci.yml` ordering
comment, and while there, check the other INFRA-006-era notes in that step for the same staleness.
Fix the baseline's `note` to name the current script.

## Acceptance criteria

- The allowlist carries a one-line reason for `perf_baseline.json`, or no longer contains it, and
  the reason states what must change if performance becomes a gate.
- The `ci.yml` comment about `dune fmt --preview` and `SOL_HOME` either matches the code or is gone;
  no comment claims an ordering constraint the code does not have.
- `perf_baseline.json`'s `note` names a path that exists.
- Demo/example: not applicable — comments, classification and one data field. Language parity: not
  applicable; state that in one line.
