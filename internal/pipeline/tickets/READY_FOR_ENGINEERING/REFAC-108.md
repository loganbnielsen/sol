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
