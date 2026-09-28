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
- Where to make common changes: [`internal/contributing-map.md`](internal/contributing-map.md).
- The conventions code and docs are held to — including the demo/example coverage
  rule, which requires a runnable example (not only unit tests) for anything that
  changes what an application author writes.

## Checks

```bash
dune build && dune test && dune fmt --preview
```

A pre-commit hook runs the build and unit suites; install it with
`bash internal/tooling/scripts/install-hooks.sh`.

The repository guards under `internal/ci/` are the same checks CI runs, and some
of them need their own tooling: the structural Terraform and YAML guards read
through pinned Python modules (`internal/ci/requirements.txt`), and the comment
guard parses shell with a pinned `shfmt`. One script provides both, the same one
CI runs:

```bash
bash internal/tooling/scripts/prepare-guard-tools.sh
```

It is idempotent, and on a distribution whose Python refuses a user install
(PEP 668) it installs the same pinned set into the user site and says so. Without
it a structural guard fails with the command to run, rather than a verdict about
the tree. It also validates ticket
state transitions: ticket creation and correction happen on ordinary PR
branches, while deletion is only allowed as a same-ID state move.

## Commits and branch protection

**Every change reaches `main` through a pull request.** There is no exception,
including internal/pipeline/planning/bookkeeping under `internal/pipeline/`, documentation
(`*.md`), and the perf baseline.

```text
branch → push → pull request → required checks green → squash merge
```

`main` is protected with required status check `test`, no mandatory approving review,
and admin enforcement enabled — so the rule
binds maintainers and administrators too, not only contributors. Direct pushes
to `main` are rejected by GitHub:

```text
remote: error: GH006: Protected branch update failed for refs/heads/main.
remote: - Changes must be made through a pull request.
remote: - Required status check "test" is expected.
```

Routine refactors, documentation, and ticket filings use focused author validation
plus required CI, without a review marker or adversarial loop. Native squash
auto-merge is enabled: from an owned worktree run
`soldev pipeline merge --auto <TICKET-ID>` to queue it, or omit `--auto` for an
immediate merge after required checks succeed. The command pins the PR head and
preserves local worktrees; it does not delete trees, switch branches, or sync the
canonical checkout. Post-merge performance maintenance remains optional and
informational, not another merge gate.

Select targeted review for infrastructure, security, lifecycle/concurrency,
substantial API changes, or when requested. Keep these PRs draft until the review
is satisfactory and its actionable findings are resolved, then mark ready and
queue auto-merge. One satisfactory pass is enough; fresh-reviewer loops and
SOLDEV-REVIEW markers are not universal requirements. Do not introduce a risk
classifier or a second approval state machine for this judgment.

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

The hook (`internal/tooling/scripts/install-hooks.sh`) still skips the test
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
bash internal/tooling/scripts/install-hooks.sh
```

That path is guarded by `internal/ci/test_hook_install.sh`, which runs the
installer in a scratch repository, seeds a dangling symlink, and asserts every
hook lands as a resolving, executable symlink. The test exists because a stale
install is otherwise indistinguishable from a clean one.

## Code conventions

These are the rules review keeps coming back to, written down once (REFAC-120). Each is applied across `cli/`, and each has a reason.

- **Lead with the data.** When the function argument is more than a line, pipe the data into it: `findings |> List.iter (fun f -> …)`, not `List.iter (fun f -> …) findings`. The reader learns *what* is being iterated before *how*, and a chain of steps reads top to bottom.
- **Normalize meaningful inputs before application.** Resolve non-trivial branching, validation, fallbacks and Result/Option unwrapping before passing arguments to a constructor, higher-order function or terminal effect. A local binding should let the outer operation read in one pass. Keep short familiar expressions inline; do not name every default or transformation (REFAC-149).
- **Name conceptual groups before combining them.** A release/endpoint list assembled from Kafka, Postgres, observability, and ingress groups should name those groups and end with their ordered combination. Keep short homogeneous literals and straightforward per-element transformations inline; do not create a generic collection helper just to shorten the expression (REFAC-150).
- **Resolve, then print.** A function that computes something does not also print it: `http_services` finds the services, `print_service_urls` prints them. A value computed only to be consumed by the next line becomes a named function feeding a pipeline (`findings_for scope |> report`).
- **No redundant annotations or qualifiers.** Write `fun r -> r.name`, not `fun (r : Sol_cli_executor.result) -> r.Sol_cli_executor.name`, whenever the type is already known -- a pipeline usually makes it known. Keep one only where the compiler needs it (a field name shared by an opened module, a record constructed before its use fixes the type).
- **A no-op arm is `iter`.** `match r with Ok () -> () | Error e -> …` is `r |> Result.iter_error (fun e -> …)`; `match o with None -> () | Some x -> …` is `o |> Option.iter (fun x -> …)`. And `(fun x -> f x)` is `f`.
- **`let*` is `open Result.Syntax`**, never a hand-written `let ( let* ) = Result.bind`, in every OCaml file in the repository -- the CLI, the framework, the tooling, and what users copy (examples, fixtures, the scaffold templates). `internal/ci/check_result_syntax.sh` fails on one (REFAC-137).
- **Propagate unchanged errors.** Replace `match resolve () with Error e -> Error e | Ok value -> validate value` with `Result.bind (resolve ()) validate`. Keep `let* value = resolve () in ...` when naming the value helps explain the next domain decision. Retain explicit recovery/error-enrichment branches; never accidentally change an error type or move cleanup, logging, or acknowledgement across a short-circuit (REFAC-148).
- **Nothing below a command's term exits.** Library code returns `result`; a command's `run` is a `let*` chain; its Cmdliner term converts the outcome to an exit once, with `Sol_cli_exit.exit_on` (REFAC-115).
- **A framework setting is read once, the same way.** `Sol_runtime.setting` is environment variable, trimmed, blank as unset; the framework packages that do not depend on `sol-runtime` (`sol-obs`, `kafka-eio-service`) carry a copy with the same rule, not a variant (REFAC-137).
- **Decide blank at the boundary.** Decoders, argument converters (`Sol_cli_args.text`), environment reads (`Sol_cli_string.env`) and tool adapters turn blank into `None` or an error, so inside Sol an optional string is never `Some ""` and an empty list is an answer, not a sentinel (REFAC-123).
- **Keep the original error text.** When handling a tool's or library's failure, pass its own words on; classification is a view for control flow (`Sol_cli_kubectl.classify`), never a replacement for the message. Adding context around it ("kubectl get configmap failed: <what kubectl said>") is fine; substituting Sol's own prose ("the cluster refused the request") loses what the operator needs to act on (REFAC-125).
- **Ask the tool for a structured answer** before matching its prose; where there is none, classify in one place per tool, with a test holding the verbatim message (REFAC-125).

## Trademarks

The "Sol" name and logo are **not** covered by the Apache-2.0 licence — see
[`TRADEMARK.md`](TRADEMARK.md).
