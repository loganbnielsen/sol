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

Commit is frequent, so its hook is cheap: pre-commit checks formatting of staged
OCaml and builds (seconds). Push is the broader local gate: pre-push runs
`internal/ci/run_fast_checks.sh`, which builds, runs the unit tests (the same
directories as CI's unit step), then the fast `internal/ci/` guards and their
mutation tests in parallel, with a pass/fail line per member (about 12s warm). CI
runs the full contract, including the slow offline cloud-lifecycle test
(`dune build @cli/test/runtest-lifecycle`, about 2 minutes). Install the hooks once
per clone with `bash internal/tooling/scripts/install-hooks.sh`, which sets
`core.hooksPath`, so every worktree runs its own checkout's hooks; both hooks clear
git's repository-local variables (`git rev-parse --local-env-vars`) before anything
that runs nested git. Run the push battery by hand with
`bash internal/ci/run_fast_checks.sh`.

The guards are not enumerated anywhere. `internal/tooling/scripts/verify.sh <class>`
discovers a class by directory — `internal/ci/` is `static`, `internal/ci/always/`
runs on every path including a docs-only change — and runs each `check_*`/`test_*`
member in parallel. Adding a guard is one file in its class and no edit to
`.github/workflows/ci.yml`; an empty class, a class directory that is missing, an
unknown class, and a member that produces no result are all errors. `internal/ci/context/`
holds the few guards whose invocation is supplied by the caller (a piped diff, a
branch name, a build rule's stdout) rather than by the class runner.

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

## Commits, branches, and pull requests

Use ordinary Git branches or worktrees. Branch names and worktree names have no repository-specific semantics.

Open a focused pull request, let required CI establish the repository's merge gates, and request review proportional to the risk of the change. Use GitHub's native auto-merge when appropriate; do not bypass required checks. Squash merge is the normal merge shape.

GitHub Issues are the work tracker when a change is useful to track. Do not recreate the former repository-local ticket state machine with labels, branch conventions, dependency validators, bots, or project automation.

The pre-commit hook is local feedback, not the authority. CI is authoritative for merge requirements.

## Code conventions

These are the rules review keeps coming back to, written down once (REFAC-120). Each is applied across `cli/`, and each has a reason.

- **Lead with the data.** When the function argument is more than a line, pipe the data into it: `findings |> List.iter (fun f -> …)`, not `List.iter (fun f -> …) findings`. The reader learns *what* is being iterated before *how*, and a chain of steps reads top to bottom.
- **Group actual domain inputs.** When config fragments travel together, reuse the existing validated target, request or spec rather than passing copies that can disagree. Introduce a named record only for a real concept; keep independently selectable tool/lifecycle options explicit and split phase-specific inputs instead of hiding everything in a dependencies bag (REFAC-152).
- **Normalize meaningful inputs before application.** Resolve non-trivial branching, validation, fallbacks and Result/Option unwrapping before passing arguments to a constructor, higher-order function or terminal effect. A local binding should let the outer operation read in one pass. Keep short familiar expressions inline; do not name every default or transformation (REFAC-149).
- **Name conceptual groups before combining them.** A release/endpoint list assembled from Kafka, Postgres, observability, and ingress groups should name those groups and end with their ordered combination. Keep short homogeneous literals and straightforward per-element transformations inline; do not create a generic collection helper just to shorten the expression (REFAC-150).
- **Resolve, then print.** A function that computes something does not also print it: `http_services` finds the services, `print_service_urls` prints them. A value computed only to be consumed by the next line becomes a named function feeding a pipeline (`findings_for scope |> report`).
- **A bounded command's outcome travels; the command boundary prints.** Its operation returns typed data or an outcome, and semantic failure is decided there; the command entry function renders that outcome as text and owns stdout/stderr and exit conversion. Do not build the output text in a helper deeper in the call chain and pass it up as a string -- the enum is what travels, text is built where it is printed. Keep progress, prompts, streaming logs and child output at their execution phase; buffering them would change the operation (REFAC-151).
- **No redundant annotations or qualifiers.** Write `fun r -> r.name`, not `fun (r : Sol_cli_executor.result) -> r.Sol_cli_executor.name`, whenever the type is already known -- a pipeline usually makes it known. Keep one only where the compiler needs it (a field name shared by an opened module, a record constructed before its use fixes the type).
- **A no-op arm is `iter`.** `match r with Ok () -> () | Error e -> …` is `r |> Result.iter_error (fun e -> …)`; `match o with None -> () | Some x -> …` is `o |> Option.iter (fun x -> …)`. And `(fun x -> f x)` is `f`.
- **`let*` is `open Result.Syntax`**, never a hand-written `let ( let* ) = Result.bind`, in every OCaml file in the repository -- the CLI, the framework, the tooling, and what users copy (examples, fixtures, the scaffold templates). `internal/ci/check_result_syntax.sh` fails on one (REFAC-137).
- **Compose empty handoffs directly.** Avoid `let* value = operation () in next_operation value` when the binding is purely mechanical and the intermediate name adds no useful domain meaning. Prefer direct composition only when it makes the operation easier to read: `let* cfg = apply ... in Ok cfg` should simply be `apply ...`. Keep `let*` when the intermediate name identifies a meaningful domain phase (for example, `creds_json` between response classification and credential resolution), improves readability, is reused or transformed, or when direct `Result.bind` syntax is less clear than the binding it replaces. Standard OCaml `Result.bind` takes the result first; plain `operation () |> Result.bind next_operation` has the wrong argument order. Do not introduce an operator or optimize for line count (REFAC-154).
- **Propagate unchanged errors.** Use `let*` or direct monadic composition instead of manually forwarding unchanged errors. Choose the form that makes the success path easiest to read, not the shortest expression: `Result.bind (resolve ()) validate` is appropriate only when clearer than the named binding it replaces. Keep meaningful domain-phase names. Retain explicit recovery/error-enrichment branches; never accidentally change an error type or move cleanup, logging, or acknowledgement across a short-circuit (REFAC-148).
- **Nothing below a command's term exits.** Library code returns `result`; a command's `run` is a `let*` chain; its Cmdliner term converts the outcome to an exit once, with `Sol_cli_exit.exit_on` (REFAC-115).
- **A framework setting is read once, the same way.** `Sol_runtime.setting` is environment variable, trimmed, blank as unset; the framework packages that do not depend on `sol-runtime` (`sol-obs`, `kafka-eio-service`) carry a copy with the same rule, not a variant (REFAC-137).
- **Decide blank at the boundary.** Decoders, argument converters (`Sol_cli_args.text`), environment reads (`Sol_cli_string.env`) and tool adapters turn blank into `None` or an error, so inside Sol an optional string is never `Some ""` and an empty list is an answer, not a sentinel (REFAC-123).
- **Keep the original error text.** When handling a tool's or library's failure, pass its own words on; classification is a view for control flow (`Sol_cli_kubectl.classify`), never a replacement for the message. Adding context around it ("kubectl get configmap failed: <what kubectl said>") is fine; substituting Sol's own prose ("the cluster refused the request") loses what the operator needs to act on (REFAC-125).
- **Ask the tool for a structured answer** before matching its prose; where there is none, classify in one place per tool, with a test holding the verbatim message (REFAC-125).

## Trademarks

The "Sol" name and logo are **not** covered by the Apache-2.0 licence — see
[`TRADEMARK.md`](TRADEMARK.md).

### Post-merge cleanup

Delete local branches or worktrees when they are no longer useful. No repository-specific cleanup bookkeeping is required.
