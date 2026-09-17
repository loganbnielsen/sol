---
id: INFRA-019
type: feature
severity: medium
title: Reuse a passing CI run when the tested code is byte-identical
source: PR #288 re-ran the full suite after a no-op update from main, 2026-09-17
---

**Depends on:** None.

## Root cause

PR #288 passed CI, was then updated from `main` (branch protection requires
`strict` up-to-date branches), and re-ran the entire suite. The
classifier was not at fault: it diffs `base.sha...head.sha`, which after the
update was still exactly the PR's 31 changed files, all `source`. The rerun
happened because every new head of a `source` pull request runs the full suite.

The new run tested nothing new. The green run had checked out `142adc9`,
"Merge d9b237f into fc0ff628", whose tree (`3109e98f…`) is byte-identical to the
tree of the updated head. Only the required `test` check (~7 min) gates the
merge; the golden paths (~13 min) are not required but still cost the time.

## Why a tree hash alone is not enough

- **Support packages float.** CI pins every `*-eio` support package at `#main`, so
  identical Sol code can build against different dependency code on two runs.
- **The tested base is not recorded.** GitHub's runs API does not record which
  base a pull-request run merged with (`pull_requests` is empty for these runs).
- **A marker can be forged.** A pull request whose intermediate commit edits the
  workflow can write any marker, so a marker a run writes about itself proves
  nothing unless the run executed an unmodified CI definition.

## Design

- **One set of dependency commits per run.** `classify` resolves every support
  package's `main` commit once, and every job pins those commits.
  `packages.txt` becomes the single package list.
- **Every full pull-request run records evidence.** `classify` uploads a
  `ci-evidence` artifact naming the tested base, head and support-package
  commits. It refuses to record unless git's merge of that base and head
  reproduces the checked-out tree.
- **A later run reuses evidence only under strict conditions.** It skips the
  expensive suite only when an earlier run meets every condition in
  `devtools/ci/ci-evidence.sh`, each checked against GitHub's records or local
  git:
  1. the current change and the earlier head leave `.github/` and
     `devtools/ci/` untouched;
  2. the earlier run succeeded;
  3. its single evidence artifact predates the end of its `classify` job;
  4. merging the recorded base and head reproduces the current tree, and the
     recorded base is on the base branch;
  5. both runs used the same support-package commits.

  The required `test` check still reports, with a summary linking the reused run.
- **Fails closed.** Any error or missing datum means a full run.

Drift outside those inputs (third-party opam packages, runner images) is not
covered, exactly as when an old commit is re-run. A pull request that edits the
CI definition can already change what its own checks do; this adds no way for
one run's evidence to vouch for another run's untrusted CI.

## Acceptance criteria

- A pull request updated from `main` with no new code, whose earlier run
  passed, skips the expensive suite and still reports a green `test` check.
- Any change to the tested tree, the support-package commits or the CI
  definition runs the full suite.
- Pushes to `main`, docs-only changes, and runs where classification fails behave
  as before.
- Every disqualifying condition has its own test in
  `devtools/ci/test_ci_evidence.sh`, and a mutation of each guard fails the
  suite.

**Demo/example coverage:** Not applicable; CI internals with no app-author surface.

**TypeScript parity:** No language impact; both golden paths benefit equally.
