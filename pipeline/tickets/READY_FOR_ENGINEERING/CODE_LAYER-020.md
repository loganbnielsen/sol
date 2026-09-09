---
id: CODE_LAYER-020
type: code-layer-finding
severity: medium
source: https://github.com/loganbnielsen/sol/pull/170
---

# Split deployment command modes into readable execution paths

`cmd_up.ml` and `cmd_deploy.ml` mix preflight checks, output, plan execution,
post-deploy state writes, and mode-specific skips in long imperative handlers.
The immediate `sol check` preflight can land without solving that, but the
shape makes future hosted/local/GitOps mode work harder to reason about.

Refactor deployment command handlers so each execution path is explicit:

```text
parse request -> build plan -> dry-run | emit-to | apply
```

Keep the extraction small. Do not redesign the full internal factory API here;
that is tracked separately by `CODE_LAYER-018`, and workspace modeling is
tracked by `CODE_LAYER-019`.

Acceptance:
- `cmd_deploy.ml` has one clear branch for dry-run, one for GitOps emit, and
  one for direct apply.
- `cmd_up.ml` separates dry-run output from apply-only side effects without
  scattering repeated mode checks through the handler.
- Preflight checks still run before mutating apply paths and still skip dry-run
  / emit-only paths.
- Existing CLI behavior and output stay compatible.
- `dune build @all` and `dune runtest cli/sol/test` pass.
