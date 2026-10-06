# Contributing to Sol

Sol is Apache-2.0. The project is not yet accepting outside code contributions while
contributor terms are being settled.

Bug reports, design critique, questions, and reports of confusing behavior are welcome
as GitHub Issues. Report security problems privately rather than in a public issue.

For maintainer changes, use an ordinary Git branch or worktree and a focused pull
request. Run targeted tests while developing and `bash internal/ci/run_fast_checks.sh`
before proposing the change. Required GitHub CI is the merge authority; request review
proportional to risk and squash-merge.

Independent changes can proceed concurrently from `main`. For mechanical dependencies,
stack pull requests with ordinary Git branches: base the child on its parent's branch and
open the child against that branch, describing the relationship in the PR. Keep each PR
focused, and rebase or retarget the child to `main` when its parent merges. Do not stack
across unresolved design decisions. When a PR is complete, validated, and intended to
land on its correct base, use auto-merge or the merge queue where the repository is
configured for them; required CI, review, and conversation resolution remain authoritative
and are never bypassed. A stacked child is ready to land after its parent merges and it is
retargeted.

Source-build prerequisites and setup are documented in `README.md`. Product and
architecture documentation lives under `docs/`; qualification procedures live under
`internal/qualification/`.

Do not introduce repository-specific issue states, branch/worktree naming protocols,
merge bookkeeping, or other workflow machinery. GitHub Issues, pull requests, and their
base branch relationships are sufficient work state.
