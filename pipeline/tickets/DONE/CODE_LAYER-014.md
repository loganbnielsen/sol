---
id: CODE_LAYER-014
type: code-layer-finding
severity: medium
source: pipeline/audits/2026-09-09_code_layer_audit.md
---

# Extract reusable deployment execution stages from `sol up`

`cmd_up.ml` currently owns local env setup, Docker context prep, build/push,
manifest apply, rollout wait, port-forward setup, state writes, and migration
hints in one command handler.

Move the reusable pieces into small library functions that return typed results:
build context, build/push image, execute plan, wait rollout, post-deploy
summary. Keep `cmd_up.ml` as argument handling plus output.

Acceptance:
- `sol up` behavior stays the same.
- Existing `dune build @all` and `dune runtest` pass.
- At least one new unit test covers a non-I/O decision moved out of
  `cmd_up.ml`.
