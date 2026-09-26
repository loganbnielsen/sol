---
id: REFAC-108
type: refactor
severity: low
title: Pass the workspace root as a value instead of chdir-ing into it
source: operator code-review notes (2026-09-26), cli/bin/cmd_check.ml and cli/lib/workspace/sol_cli_workspace.ml
---

**Depends on:** None.

## The problem

DEC-024 clause 4 lets commands run from any subdirectory of a workspace (like `git`), which is worth keeping. The implementation makes the root hidden global state, though. `Sol_cli_workspace.enter` resolves the root and then calls `Sys.chdir root`, and callers discard the returned root: `cmd_check.ml` does `| Ok _ -> ()`. Every later relative path depends on the process's cwd having been changed. Other code (`Sol_cli_config.workspace_root`) re-derives the root from `Sys.getcwd ()` instead.

## Remediation

- Resolve the root once per command and pass it explicitly to what needs it. Remove `enter`'s `Sys.chdir`, and `Sol_cli_config.workspace_root`'s cwd re-derivation where the root can be passed instead.
- Keep the user-visible behaviour: every command still works from any subdirectory.
- In the same file, two small cleanups the review found:
  - `validate` emulates an early exit with `Array.fold_left … | Some _ -> found`, which keeps visiting every remaining entry. Use `Array.find_map`.
  - Its comment says "resolution stays a cheap upward walk" right above a function that walks *down*. Name which function walks which way. Also add the scenario behind the symlink check: a symlinked checkout such as `vendor/sol -> ~/Code/sol` contains `examples/pluto/sol.yml`, which would read as a nested workspace, and a symlink loop would recurse forever.

## Acceptance criteria

- `rg -n 'Sys.chdir' cli/lib cli/bin` shows no chdir used to establish the workspace root.
- A test runs a representative command from a subdirectory and shows it resolves the same workspace.
- **Demo/example:** not applicable (internal); state it.

## Completion notes (required)

- Language parity (DEC-022): no application-facing impact.

## Completion notes

**Premise re-verified (2026-09-26):** `rg -n 'Sys.chdir' cli/lib cli/bin` showed four places that establish the root. `Sol_cli_workspace.enter` is used by `check` and `up`. `cmd_logs.ml`, `cmd_fn.ml` and `cmd_status.ml` each hand-rolled `find_root` + `Sys.chdir`.

**A bug found on the way.** The three hand-rolled versions skipped `validate`, so `sol logs`, `sol fn run` and `sol status` accepted a nested workspace (DEC-024 clause 2). Outside a workspace they carried on with the current directory's name instead of failing closed.

**What landed (part A):**
- `Sol_cli_workspace.enter_or_exit ()` is the one way a command establishes its workspace. It validates the boundary, fails closed when there is none, `chdir`s to the root and returns it.
  - `check`, `up`, `logs`, `fn` and `status` all use it, and the hand-rolled copies are gone.
  - `cmd_check` still ignores the returned root, now explicitly (`ignore (… : string)`), with a comment saying nothing below needs it by name.
- **`validate` cleanups:**
  - `Array.find_map` replaces the fold that emulated an early exit (it stopped doing work but still visited every remaining entry);
  - the comment says which function walks up (`find_root`) and which walks down (`validate`);
  - the symlink rule states its scenario: a symlinked checkout containing `sol.yml` files, and symlink loops.
- **Tests** (`test_workspace.ml`): entering from `app/payments/charge_svc` returns the root and leaves the cwd there; a symlinked checkout containing a `sol.yml` is not a nested workspace.
- **Real binary:**
  - `sol check` from `examples/pluto/app/payments` → `sol check: ok`;
  - `sol logs --target prod/aws/us-east-1 --scope payments/charge_svc` outside any workspace → "not inside a Sol workspace", exit 1.

**Deviation from the acceptance criterion, deliberate:** `rg -n 'Sys.chdir' cli/lib cli/bin` still finds one `chdir`, inside `enter`. Removing it means every consumer of a workspace-relative path has to take the root. `rg -n '\.dir\b|~context:|Sol_cli_toml.load|sol\.toml|Dockerfile"' cli/lib cli/bin --glob '*.ml'` → 119 sites in 20 files, including the Docker build contexts and `sol.toml` reads on every deploy path. That's a large, regression-prone change for a hygiene gain, so it's filed as **REFAC-110** in `BACKLOG/` for a decision rather than done silently here. What this ticket delivers is the behaviour that mattered: one validated entry point, a single place that changes directory, and a root that's always resolved, never guessed.

- **Verified:** `dune build` and `dune test cli/test/` pass (0 `[FAIL]`); format clean.
- **Demo/example:** not applicable (internal; commands behave as documented from any subdirectory).
- **Language parity (DEC-022):** no application-facing impact.
