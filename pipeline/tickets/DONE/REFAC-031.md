---
id: REFAC-031
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-031/deployment-state-lib
worktree: /home/lbendtly/Code/sun-REFAC-031-deployment-state-lib
---

Move consumer group state functions from cmd_up.ml (bin) to a shared lib module

**Depends on:** None.

**Description:**

`cmd_deploy.ml` directly imports three functions from `cmd_up.ml` — a bin file — using the `Cmd_up.*` prefix:

```ocaml
(* cmd_deploy.ml lines 111–113, 182 *)
let prev_groups = Cmd_up.load_deployed_groups workspace in
let removed     = Cmd_up.removed_consumer_groups ~prev ~next in
Cmd_up.save_deployed_groups workspace ...
```

This creates an unusual and fragile coupling: two `(executable ...)` targets share source-level state through OCaml's module system. The functions themselves (`load_deployed_groups`, `removed_consumer_groups`, `save_deployed_groups`, lines 287–330 in `cmd_up.ml`) are pure business logic with no UI or command-specific dependencies — they read/write a Kubernetes ConfigMap via kubectl and compare string sets.

Any refactoring of `cmd_up.ml` risks silently breaking `cmd_deploy.ml` unless both are touched.

**Remediation:**

1. Create `cli/sun/lib/sun_cli_deployment_state.ml` with the three functions extracted verbatim from `cmd_up.ml:287–330`. The module has no dependency on Cmdliner or cmd_up-specific state.

2. Add `sun_cli_deployment_state` to the lib dune stanza.

3. In `cmd_up.ml`: delete the three function definitions and replace internal call sites with `Sun_cli_deployment_state.*`.

4. In `cmd_deploy.ml`: replace `Cmd_up.load_deployed_groups`, `Cmd_up.removed_consumer_groups`, `Cmd_up.save_deployed_groups` with `Sun_cli_deployment_state.*`.

**Acceptance criteria:**

- `grep -rn "Cmd_up\." cli/sun/bin/cmd_deploy.ml` returns zero hits.
- `cmd_up.ml` contains no `let load_deployed_groups`, `let removed_consumer_groups`, `let save_deployed_groups` definitions.
- `dune build` passes.
- `sun up` and `sun deploy` consumer group change warnings still fire correctly.

## Review — automated checks passed
All three functions extracted correctly; Cmd_up.* references eliminated; Sys.command rc checked; Filename.quote used; dune wrapped false; perf_baseline.json diff is expected pre-commit hook artifact
