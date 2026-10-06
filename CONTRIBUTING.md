# Contributing to Sol

Sol is Apache-2.0. The project is not yet accepting outside code contributions while
contributor terms are being settled.

Bug reports, design critique, questions, and reports of confusing behavior are welcome
as GitHub Issues. Report security problems privately rather than in a public issue.

For maintainer changes, use an ordinary Git branch or worktree and a focused pull
request. Run targeted tests while developing and `bash internal/ci/run_fast_checks.sh`
before proposing the change. Required GitHub CI is the merge authority; request review
proportional to risk and squash-merge.

When a change depends on an unmerged pull request, prefer a native GitHub stacked pull
request: base the dependent PR on the predecessor's branch, keep each layer reviewable,
and land the stack bottom-up with `gh stack` (or the stack UI). Do not duplicate the
predecessor's changes or build custom merge-order tooling.

Source-build prerequisites and setup are documented in `README.md`. Product and
architecture documentation lives under `docs/`; qualification procedures live under
`internal/qualification/`.

Do not introduce repository-specific issue states, branch/worktree naming protocols,
merge bookkeeping, or other workflow machinery. GitHub Issues, pull requests, and native
stack relationships are sufficient work state.
