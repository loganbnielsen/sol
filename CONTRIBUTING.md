# Contributing to Sol

Sol is Apache-2.0 — see [`LICENSE`](LICENSE).

## Not accepting outside contributions yet

**The project is not currently accepting pull requests**, and that is deliberate rather than an oversight: the terms on which outside code is accepted are still being settled (below), and accepting a contribution under the wrong terms permanently restricts what the project can do with its licence.

What is welcome in the meantime:

- **Issues.** Bug reports with a reproduction, design critique, and "this was confusing" are genuinely useful.
- **Security reports.** Please report these privately rather than in a public issue.
- **Questions.** If you are building on Sol and something is unclear, that is a documentation bug worth reporting.

If you have already prepared a change, tell us through an issue rather than letting it sit — we would rather say whether it is something we can take, and under what terms, than have you guess.

## Contributor terms (to be settled before any contribution is accepted)

Two mechanisms are on the table, and the choice is not cosmetic:

- **DCO sign-off** (`git commit -s`) — a per-commit *origin statement*: you certify you created the work, in whole or in part, or otherwise have the right to submit it under this project's licence. Minimum friction, and what most projects use. It does **not** grant permission to relicense the contribution.
- **CLA** — a signed agreement that does grant that permission, which is what makes it possible to change the project's licence later (for example tightening it to prevent a reseller), and what every notable relicensing has relied on.

The distinction is worth stating plainly because it is easy to conflate: a sign-off is an *origin statement, not a rights grant*. And the difference only matters *before* code lands — after a handful of contributors it is not realistically reversible without tracking each of them down. That is why the choice is being settled first rather than deferred, and why no contribution will be accepted until it is.

## Before you start

- Build, tests and repository layout: [`AGENTS.md`](AGENTS.md).
- Where to make common changes: [`docs/architecture/contributing-map.md`](docs/architecture/contributing-map.md).
- The conventions code and docs are held to — including the demo/example coverage
  rule, which requires a runnable example (not only unit tests) for anything that
  changes what an application author writes.

## Checks

```bash
dune build && dune test && dune fmt --preview
```

A pre-commit hook runs the build and unit suites; install it with
`bash platform/local/scripts/install-hooks.sh`. It also validates ticket
state transitions: ticket creation and correction happen on ordinary PR
branches, while deletion is only allowed as a same-ID state move.

## Commits and branch protection

**Every change reaches `main` through a pull request.** There is no exception,
including internal/pipeline/planning/bookkeeping under `internal/pipeline/`, documentation
(`*.md`), and the perf baseline.

```text
branch → push → pull request → required checks green → review → merge
```

`main` is protected with required status check `test`, one approving review,
strict (branch must be up to date), and admin enforcement enabled — so the rule
binds maintainers and administrators too, not only contributors. Direct pushes
to `main` are rejected by GitHub:

```text
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - Changes must be made through a pull request.
remote: - Required status check "test" is expected.
```

### Why there is no bookkeeping exception

An earlier revision of this file allowed maintainers to commit
non-source changes — tickets, `*.md`, the perf baseline — directly to `main`.
That exception was withdrawn after it was used, in practice, for *everything*:
25 consecutive commits on `main`, including a large refactor and the change that
broke `main`'s CI, all landed by direct push. A gate that is bypassed for
convenience is not a gate, and the failure mode is silent — `main` stayed red
across ~10 further commits before anyone noticed.

Evidence-only pull requests are cheap and immediately mergeable. That is a
better trade than discovering hours later that the authoritative branch has been
broken for a dozen commits.

### The pre-commit hook is not the gate

The hook (`platform/local/scripts/install-hooks.sh`) still skips the test
suite for staged bookkeeping-only changes, which is a useful local speed-up. It
is **not** a substitute for CI: run CI on the pull request, and do not treat "the
hook was quiet" as evidence a change is safe. CI is the gate.

### Isolation and ownership

**Each concurrent actor owns one worktree. Agents do not perform mutating work in
the canonical checkout.** The canonical checkout — the first entry in
`git worktree list`, the one that holds `.git/` — belongs to the human operator.

Worktrees share the object database, so commits and refs stay visible to
everyone, but working-tree state and `HEAD` are isolated. That isolation is the
point: a shared checkout's branch can change underneath an actor midway through a
commit, and the resulting commit is *valid but in the wrong place* — every test,
guard and review of its contents passes while it sits on someone else's branch.

```bash
git worktree add -b <TICKET-ID>/<short-slug> ../sol-<TICKET-ID>-<short-slug> main
```

Before **every** commit and push, resolve and verify:

- the **worktree** you are in, and that it is not the canonical checkout;
- the **branch** you are on, and that it is not detached with staged changes;
- the **upstream**, if any;
- the **expected base** — what this work is stacked on;
- **ownership** — whose ticket/PR branch this is. If another actor owns it or is
  actively rewriting it, do not push to it; produce a clean handoff instead.

**Removing a worktree is a mutating operation on someone else's working tree.**
`git worktree remove --force` discards uncommitted changes without asking, and a
worktree that looks finished — your PR merged, branch deleted — can still hold an
actor's edits made after the merge. Removing one that way destroyed uncommitted
review edits to two tickets in this repository. Before removing any worktree that is
not demonstrably yours and clean:

```bash
git -C <worktree> status --porcelain   # empty, or stop and hand it over
```

The isolation rule above is about not *working* in a shared checkout; this is the
same rule applied to cleaning one up.

`internal/ci/check_authority.sh` performs those checks and is wired into the
pre-commit hook. It is **advisory by default**, because a human committing in the
canonical checkout is legitimate and a single-worktree clone should be quiet.
Declare a context to make it strict:

```bash
SOL_AUTHORITY_WORKTREE=$PWD \
SOL_AUTHORITY_BRANCH=<TICKET-ID>/<slug> \
SOL_AUTHORITY_BASE=main \
git commit ...
```

A declared mismatch is refused. An undeclared context warns only about the two
signals that are unambiguous once more than one worktree exists: a commit from
the canonical checkout, and a detached `HEAD` with staged changes. It never
requires a branch to have an upstream, and never blocks a merge commit.

### If nothing seems to be running

A stale hook install fails silently — the hook simply never runs, so the gate is
absent rather than red. If the local hooks appear inert, re-run the documented
installer:

```bash
bash platform/local/scripts/install-hooks.sh
```

That path is guarded by `internal/ci/test_hook_install.sh`, which runs the
installer in a scratch repository, seeds a dangling symlink, and asserts every
hook lands as a resolving, executable symlink. The test exists because a stale
install is otherwise indistinguishable from a clean one.

## Trademarks

The "Sol" name and logo are **not** covered by the Apache-2.0 licence — see
[`TRADEMARK.md`](TRADEMARK.md).
