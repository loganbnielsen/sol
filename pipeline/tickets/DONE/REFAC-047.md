---
id: REFAC-047
type: refactor
severity: medium
source: codebase simplification review 2026-06-16
branch: REFAC-047/remove-duplicate-yaml-dispatch
worktree: ../sun-REFAC-047-remove-duplicate-yaml-dispatch
---

Remove duplicate YAML resource-dispatch path in `sun_cli_manifest_yaml`

**Depends on:** None.

**Description:**

The match expression that maps `(primitive, progressive_delivery)` to a list of YAML resource documents exists in two places and must be kept in sync:

- `cli/sun/lib/sun_cli_manifest_yaml.ml:536–563` — the `render` function, used by `sun new` scaffolding tests and an older code path. It also re-resolves TOML defaults (`replicas`, `cpu`, `memory`, `rollout_strategy`, `ingress_*`) that the live path has already resolved.
- `cli/sun/lib/sun_cli_deployment_render.ml:54–88` — the `render_spec` function, the live path used by `sun up` and `sun deploy`.

Any change to resource shape (new workload annotation, new primitive type, renamed field) must be applied in both places. The `render` function's independent default-resolution is also a latent divergence: if defaults change in the TOML layer they may not be reflected in the scaffold path.

**Remediation:**

1. Verify callers: `grep -rn 'Sun_cli_manifest_yaml\.render\b' cli/`. If any production callers exist outside tests, migrate them to `Sun_cli_deployment_plan.of_services` + `render_spec` first.
2. Delete `sun_cli_manifest_yaml.ml:516–566` (the `render` function) and its `.mli` signature.
3. Update any test callers to use the `render_spec` path with a minimal synthetic `Sun_cli_deployment_plan.t`.
4. Keep all `*_doc` YAML template functions in `manifest_yaml.ml` — only the dispatch switch is removed.

**Acceptance criteria:**

- `grep -rn "Sun_cli_manifest_yaml\.render\b" cli/` returns zero hits.
- `dune build` and `dune test cli/sun/` pass.

## Review — automated checks passed
render function and val render signature deleted, parity test removed, no references remain, build clean
