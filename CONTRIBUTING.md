# Contributing to Sol

Sol is Apache-2.0. The project is not yet accepting outside code contributions while
contributor terms are being settled.

Bug reports, design critique, questions, and reports of confusing behavior are welcome
as GitHub Issues. Report security problems privately rather than in a public issue.

For maintainer changes, use an ordinary Git branch or worktree and a focused pull
request. Run targeted tests while developing and `bash internal/ci/run_fast_checks.sh`
before proposing the change. Required GitHub CI is the merge authority; request review
proportional to risk and squash-merge.

Source-build prerequisites and setup are documented in `README.md`. Product and
architecture documentation lives under `docs/`; qualification procedures live under
`internal/qualification/`.

Do not introduce repository-specific issue states, branch/worktree naming protocols,
merge bookkeeping, or other workflow machinery. GitHub Issues and pull requests are
sufficient work state.
