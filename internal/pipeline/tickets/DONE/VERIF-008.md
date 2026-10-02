---
id: VERIF-008
type: refactor
severity: medium
title: Scratch-repository helpers trust their caller to sanitize Git's exported environment
source: internal/pipeline/audits/2026-10-01_verification_architecture_audit.md
premise: rg -q local-env-vars internal/ci/run_fast_checks.sh
---

Scratch-repository helpers trust their caller to sanitize Git's exported environment

**Depends on:** None.

**Premise re-verified (2026-10-01)** against `origin/main @ fd138b3a`: the sanitization that fixed
the hook incident lives in one place, `internal/tooling/hooks/pre-push:6`
(`unset $(git rev-parse --local-env-vars)`), with `internal/tooling/hooks/pre-commit:45` doing the
same for its build only. `internal/ci/run_fast_checks.sh` does not sanitize, and it invokes about ten
helpers that create and mutate scratch Git repositories —
`test_json_decode_boundary.sh:12`, `test_workflow_paths.sh:12`, `test_library_output.sh:12`,
`test_manifests_are_values.sh:12`, `test_result_syntax.sh:12`, `test_no_account_artifacts.sh:11`,
`test_authority_check.sh:18`, `test_hook_install.sh:25`. The regression coverage that does exist is
the model to copy: `internal/ci/test_hook_install.sh:70-85` drives a real `git push` through the
tracked hook and then asserts that no repository-local variable leaked and that nested `git` calls
resolved the pushing worktree and branch.

## Problem

Git exports repository-local variables (`GIT_DIR`, `GIT_INDEX_FILE`, and others) to hooks. A script
run underneath that environment that creates a scratch repository and then calls
`git -C "$scratch" rm --cached …` can resolve the exported variables instead of `$scratch` and mutate
the real repository — which is what the incident did. The protection today is that one hook
remembers to `unset`. A new hook, a `git rebase --exec`, or a developer running
`bash internal/ci/run_fast_checks.sh` from inside a Git-invoked process reintroduces the hazard with
no signal at all, and the same is true for any guard added later.

## Desired invariant

A script that creates or mutates a scratch repository proves it is operating on that repository
before a destructive Git operation, and the runner sanitizes its own environment rather than
trusting its caller. The real-`git` boundary remains the evidence.

## Remediation

Sanitize at the entry point of `internal/ci/run_fast_checks.sh` (and in whatever shared helper the
scratch-repo guards use). Where a helper performs `add`, `rm`, `commit`, `checkout` or `worktree` in
a scratch tree, assert first that `git -C "$scratch" rev-parse --git-dir` resolves inside `$scratch`,
and fail with the resolved path in the message when it does not. Keep and extend the existing
real-`git push` regression rather than adding a mock of Git's environment.

## Acceptance criteria

- `run_fast_checks.sh` is safe when invoked from inside a Git-invoked process: with `GIT_DIR` and
  friends set to another repository, it runs and leaves that repository untouched.
- Every scratch-repo helper fails closed, naming the resolved repository, when its target does not
  resolve inside the scratch directory; at least one helper demonstrates this in its own test.
- `internal/ci/test_hook_install.sh`'s leak and worktree-resolution assertions still pass, and its
  pattern (drive the real boundary, assert the environment) is what the new cases follow.
- Demo/example: not applicable — repository tooling only. Language parity: no application-facing
  contract changes; state that in one line.

## Completion notes (2026-10-02)

**Premise verified** against `origin/main @ 287f13dc`: the unique `git rev-parse --local-env-vars`
sanitization lived in `internal/tooling/hooks/pre-push:6` (and pre-commit's build), while
`run_fast_checks.sh` did not sanitize and invoked ~17 helpers that create and mutate scratch
repositories.

**Implemented — one shared helper, wired in at every scratch-repo creation.**

- `internal/ci/lib/scratch_repo.sh` defines `scratch_repo_sanitize`, `scratch_repo_assert`,
  `scratch_repo_leak_vars`, `scratch_repo_inside` and `scratch_repo_init`.
- `run_fast_checks.sh` sources it and calls `scratch_repo_sanitize` at its entry, so it no longer
  trusts its caller's environment.
- Every `git … init` that creates a scratch repository became `scratch_repo_init …`, which refuses
  to create anything while a Git-invoked process has any repository-local variable set (naming the
  variable and its value), then asserts `git -C <scratch> rev-parse --absolute-git-dir` resolves
  inside the scratch directory and fails naming the resolved path when it does not. 17 helper
  scripts (19 init sites) were converted; no bare `git … init` remains under `internal/ci/`.
- `internal/ci/test_scratch_repo.sh` (wired into `run_fast_checks.sh` and the `test` job) follows
  `test_hook_install.sh`'s pattern: it creates a real repository, asserts the resolver accepts it,
  then exports `GIT_DIR` at another real repository and asserts the helper refuses, names the
  variable, and leaves that repository's HEAD and status unchanged; it also proves
  `scratch_repo_sanitize` clears the leak.

**Evidence** (worktree, pinned kubectl on PATH):

```
(a) GIT_DIR=/tmp/verif008-real/.git bash internal/ci/test_ticket_move.sh
    exit=1  scratch-repo: refusing to create . while a Git-invoked process has repository-local
            variables set (GIT_DIR=/tmp/verif008-real/.git); run this outside a hook or unset them
(b) GIT_DIR=/tmp/verif008-real/.git bash internal/ci/run_fast_checks.sh
    fast checks: 0/67 failed in 17s ; FAST_EXIT=0
    leaked repository: HEAD unchanged, git status --porcelain empty
```

All 18 transformed helper tests pass; `test_hook_install.sh`'s leak and worktree-resolution
assertions still hold. `check_no_comments.sh` (785 files), `check_workflow_paths.py`,
`test_unconditional_guard_tooling.sh` and `test_docs_only_path.py` all pass.

**Demo/example:** not applicable — repository tooling only. **Language parity (DEC-022):** no
application-facing contract change.
