---
id: REFAC-114
type: refactor
severity: medium
title: Move every Sol-owned asset lookup behind Sol_cli_platform_assets, and guard checkout discovery to it
source: DEC-049
premise: "test -f cli/lib/base/sol_cli_platform_assets.ml || test -f cli/lib/workspace/sol_cli_platform_assets.ml"
---

**Depends on:** DEC-049.

## The problem

Four consumers each call `Sol_cli_cmd_new.infer_sol_home` and hand-build `platform/...` paths, each with its own copy of the "set SOL_HOME" error: `cmd_migrate.ml` (twice), `cmd_cloud_tf.ml`, `sol_cli_dev_observability.ml` (twice), `sol_cli_platform_component.ml`. Nothing stops a fifth.

## Remediation

- A new `Sol_cli_platform_assets` module owns: the root (the resolution order from DEC-049, source form only for now), one error naming the fix, and typed accessors for what the consumers read: the cloud Terraform roots, the observability dashboards and Alloy template, `components.json`, and the migration runner's build context.
- The four consumers use it; none calls `infer_sol_home`. Checkout discovery moves into the resolver.
- A CI guard fails if checkout discovery is referenced outside the resolver (and its tests).
- Source-checkout behaviour is unchanged.

## Acceptance criteria

- `rg -n 'infer_sol_home|is_sol_home' cli --glob '!cli/test/**'` matches only the resolver.
- The guard runs in CI, and a positive control shows it fails on a planted call.
- Precedence for the source form is tested: a valid `SOL_HOME` wins; an invalid `SOL_HOME` is an error, not a fallback; with no `SOL_HOME`, discovery finds the checkout.
- `dune test cli/` is green.
- Demo/example: not applicable (internal); state it.
