---
id: INFRA-113
type: infra
severity: medium
source: validation workflow review 2026-10-05
title: Make local git validation content-correct and change-relevant
---

**Depends on:** INFRA-109, INFRA-112, INFRA-115.

## Premise verified

`internal/ci/run_fast_checks.sh` unconditionally builds the repository, runs the root `@ci-unit` and
`@ci-lifecycle` aliases, validates tickets, then runs the `always` and `static` guard classes. The
unit and lifecycle aliases are the same broad suites CI runs. INFRA-112 records three pre-push runs
of 113s, 156s and 170s on trees whose checks had already passed. `CONTRIBUTING.md` currently calls
the warm run about 12 seconds and does not say the local hook runs the lifecycle suite.

The hook change in INFRA-109 makes the pushed tree the input and keeps whole-tree guards whole-tree;
it does not narrow product-test work. The required CI `test` job independently builds and runs the full unit, lifecycle, integration,
end-to-end and static checks for each non-docs PR. CI must remain independent of local result caches,
but this current PR membership is not itself a required invariant; INFRA-115 defines the CI tiers.

The local suite also has inputs that are not reliably fixed by the developer environment: CI pins
`kubectl` before running the CLI unit alias because a command-argument check depends on the actual
client version, while `run_fast_checks.sh` uses whichever `kubectl` happens to be on `PATH`. CI's
broker/Postgres integration and E2E aliases are not in the pre-push hook today and must stay there.

## Remediation

Keep pre-commit quick and deterministic: the format result must be for the staged blobs, not a
different working-tree version. The full `dune build` may remain as a fast local sanity check when
the staged and working-tree source agree; when they differ, skip it with a clear explanation or
build an exact staged snapshot. Do not report a worktree build as proof that the staged commit
builds.

For pre-push, preserve INFRA-109's exact pushed-tree input, ticket checks, and whole-tree
verification classes, but replace unconditional product-wide build and test aliases with a
fail-closed validation plan derived from changed paths and Dune test ownership. Build and run the
deterministic test aliases for changed packages and their reverse dependents; include the CLI
lifecycle alias when CLI lifecycle code is affected. A change whose test ownership cannot be
established must select the broad local suite, never an empty or guessed plan.

Do not run broker/Postgres-backed integration tests, Kubernetes deployment smokes, or live cloud
qualification from a local Git hook. Keep them in CI or the separately authorized qualification
workflow. A selected local test that depends on a versioned external tool must use the pinned tool
or remain CI-only; an absent or different tool must not produce a local pass.

Reconcile INFRA-112's reuse key with the selected plan: reusable evidence must bind the exact pushed
tree, selected test/guard plan, runner and toolchain. A cached broad-suite pass must not stand in for
a different selected plan, and local evidence must never suppress CI's independent full run. Update
the contributor/agent instructions to state the actual stages and measured cost without promising
the unsupported “about 12s warm” duration.

## Acceptance criteria

- A reviewed path-to-test ownership map selects package-local `ci-unit` aliases plus reverse
  dependents; CLI lifecycle checks are selected for relevant CLI changes.
- The staged-format check reads the index contents. Tests stage a formatted version then make the
  worktree version unformatted, and vice versa; only the staged version determines the verdict.
- A pre-commit build result is treated as a check of the staged content only when those source bytes
  match the worktree or the build ran from an exact staged snapshot. A mismatching uncommitted patch
  cannot produce a misleading pass or block the commit as though it were staged.
- Ticket-only and tooling-only changes do not run all product unit/lifecycle tests, but still run
  their relevant deterministic tooling tests and the whole-tree guard classes.
- Unknown paths, global build/test metadata and selector errors fail closed to the documented broad
  local plan; every selector outcome is printed with the chosen checks.
- The local hook does not run integration, E2E, Kubernetes-smoke or live-qualification work.
  Version-sensitive tests run locally only with their pinned toolchain; otherwise the authoritative
  CI job owns them.
- INFRA-109's pushed-tree regression remains green, and INFRA-112's cache invalidates on a changed
  tree, validation plan, runner or toolchain. CI does not read or reuse local evidence. Review CI test
  failures for deterministic, low-cost candidates to add to the relevant local plan; do not mirror
  costly or environment-sensitive failures into hooks.
- Local evidence never suppresses or substitutes for independent CI. Per-PR CI selection follows
  INFRA-115; the broad cross-surface suite remains independently run on every push to `main` and on
  any PR whose impact is global, mixed, unknown or cannot be classified safely.
- Tests prove selection for a tooling-only change, a `sol-jobs` change, a CLI lifecycle change, a
  shared/global change, and an unknown path; a mutation that drops an affected package or reverse
  dependent from the plan fails.
- `CONTRIBUTING.md` and `AGENTS.md` accurately describe which stages run locally and in CI, without
  stale duration or serial/parallel claims.
- Example impact: none; developer tooling. Language-parity impact: none.
