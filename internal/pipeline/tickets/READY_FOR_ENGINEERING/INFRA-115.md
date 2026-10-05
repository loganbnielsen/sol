---
id: INFRA-115
type: infra
severity: high
source: validation workflow review 2026-10-05
title: Select independent PR CI by affected contract and retain broad main validation
---

**Depends on:** None.

## Premise verified

`.github/workflows/ci.yml` classifies PRs into `docs-only`, `ocaml`, `typescript` and `source`. The
required `test` job runs the whole product suite for every non-docs class: build, all `@ci-unit` and
`@ci-lifecycle` targets, broker and Postgres integrations, E2E and static guards. This means a hook
change in `internal/ci/` can be blocked by the Postgres-backed `sol-jobs` lease-fencing integration.
That test failed on INFRA-109 PR #1079 in `lease fencing (BUG-050) / long handler renews its lease`
with `one handler ran`, though the hook change did not touch `sol-jobs`. The same run spent 18m06s
in the optional TypeScript Kubernetes golden path, which failed on a missing `order-svc-env`
ConfigMap. That job was also triggered for the hook-only change.

The workflow already runs a full `source` classification on every push to `main`; its broad suite is
therefore available as independent post-merge validation. Local hook evidence is not consumed by
GitHub Actions. The required invariant is independent CI coverage appropriate to the change plus a
broad authoritative lane, not the current full suite membership on every PR.

## Remediation

Replace the four-bucket PR suite choice with a reviewed, fail-closed impact plan shared with local
validation and optional product smokes. The plan must represent affected product contracts and
validation classes, not merely language labels. Every PR runs CI-owned deterministic invariants:
classification and its mutation tests, ticket identity/transition checks, always-class guards, and
any other checks explicitly designated universal. A required status check always reports a result,
even if classification fails; uncertainty selects the broad plan rather than an empty or skipped
check.

Select independent product validation from changed surface and reverse dependencies. Examples: a
hook-only change runs its hook/classifier tests and whole-tree invariants, but not `sol-jobs` Postgres
integration or app deployment; a `sol-jobs` change runs its unit and Postgres-backed lease/integration
tests; CLI lifecycle changes run the relevant CLI build/lifecycle checks; TypeScript scaffold or
demo changes run TypeScript build/tests and the Kubernetes golden path when appropriate. Shared,
mixed, global build/test metadata, dependency/toolchain, selector or unrecognized changes use the
broad PR plan. Selection must be visible in CI logs and testable independently of the local hook.

Retain the complete cross-surface product suite on every push to `main`. Keep scheduled/nightly broad
validation only for checks that are not covered by that main lane or whose operational constraints
make the main run unsuitable, and report its result clearly. Live cloud qualification remains a
separately authorized run, never an ordinary PR or hook gate. Keep environment-sensitive tests in
CI; where a failure is flaky, track and fix the test or environment instead of silently dropping its
contract coverage. CI selectors and local selectors must not reuse local result evidence.

## Acceptance criteria

- A written impact-to-check map identifies universal CI invariants, affected-surface unit/lifecycle
  and integration checks, broad PR conditions, main-branch broad coverage, and explicitly authorized
  qualification work.
- Hook-only changes do not run Postgres-backed `sol-jobs` integration or the TypeScript Kubernetes
  deployment smoke; `sol-jobs` changes do run the relevant Postgres suite; CLI lifecycle, TypeScript
  demo/scaffold, and shared/global changes select their corresponding checks.
- Unknown paths, mixed/global changes, build/test metadata and dependency/toolchain changes select the
  conservative broad PR suite. Classifier errors cannot result in missing required statuses or an
  empty validation plan.
- The required PR status always reports success or failure after running universal invariants and
  all checks selected by the plan. CI independently checks the PR tree and never consumes local
  cache/evidence.
- The full cross-surface build, unit, lifecycle, broker/Postgres integration and E2E suite continues
  on every push to `main`; broad PR selection is exercised by tests and classifier mutations.
- The slow TypeScript Kubernetes smoke is selected for TypeScript golden-path-affecting changes and
  broad main validation, with an explicit skip reason otherwise. Its required/optional status is
  explicit and does not block unrelated changes by accident.
- Tests prove selection for hook-only, `sol-jobs`, CLI lifecycle, TypeScript demo/scaffold, shared,
  global metadata, mixed and unknown paths. Mutations that omit a required affected check fail.
- The INFRA-109 run’s lease-fencing failure and TypeScript deployment failure remain recorded as
  failures to diagnose; tiering must not relabel them as passes or erase their evidence.
- Live cloud qualification remains authorization-gated and outside PR CI.
- Example impact: none; developer tooling. Language-parity impact: none.
