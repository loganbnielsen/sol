---
id: CODE_LAYER-021
type: code-layer-finding
severity: medium
source: follow-up from CODE_LAYER-020 review
---

# Finish mode-level dispatch for deploy/up execution paths

`CODE_LAYER-020` introduced the right execution-mode domain model, but
`cmd_deploy.ml` and `cmd_up.ml` can still re-check the same mode through long
imperative handlers. That leaves the control flow fragmented: apply-only
preflight checks, dry-run output, GitOps emit, direct apply, and state recording
are still easy to reason about only by scanning the whole function.

Refactor the remaining mode-specific control flow so the command chooses the
execution path at a higher level:

```text
parse request -> build shared context/plan -> dry-run | emit-to | apply
```

Keep this ticket scoped to readability and layer ownership in the existing CLI
paths. Do not add hosted APIs, redesign the internal factory boundary, or pull
in workspace discovery modeling; those are tracked separately by
`CODE_LAYER-018` and `CODE_LAYER-019`.

Acceptance:
- `cmd_deploy.ml` does not repeatedly match `Sol_cli_executor` mode through one
  long imperative function with empty branches.
- `cmd_up.ml` keeps shared setup shared, but apply/dry-run-specific behavior is
  dispatched through named helpers or a single higher-level branch.
- Preflight checks still run before mutating apply paths and still skip dry-run
  / emit-only paths.
- Existing CLI output and behavior stay compatible.
- `dune build @all` and `dune runtest cli/sol/test` pass.
