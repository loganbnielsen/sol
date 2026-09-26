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

## Completion notes (2026-09-26)

Premise checked on `origin/main` (`bc9062b0`): no `sol_cli_platform_assets.ml` existed, and `rg -n 'infer_sol_home' cli --glob '!cli/test/**'` listed the four consumers (migrate twice, observability twice).

- **`Sol_cli_platform_assets`** (`cli/lib/base/`, so every domain library can use it):
  - `resolve : unit -> (t, error) result` and `resolve_or_exit`;
  - `error = Invalid_sol_home of string | Not_found`, with one message that names the fix;
  - accessors: `cloud_root t provider (Cluster | Platform)`, `cloud_root_rel`, `components_json`, `dashboard`, `alloy_template`, and `migration_runner t = Build_from_source { context }`;
  - discovery internals (`is_checkout`, `find_ancestor`), exposed for tests.

  `infer_sol_home`, `is_sol_home` and `find_ancestor` are gone from `Sol_cli_cmd_new`. The `realpath`/ancestor-walk code moved unchanged. `Sol_cli_cloud_lifecycle.platform_root` is gone too; the layout of the `platform/` tree now has one owner.
- **Consumers:**
  - `cmd_cloud_tf` (`infra_dir`, `platform_dir`; its `resolve_sol_home` is deleted);
  - `cmd_migrate` (both runner builds take `Build_from_source.context`);
  - `sol_cli_dev_observability` (dashboards and the Alloy template; `render_alloy_config ~assets`);
  - `sol_cli_platform_component` (`components.json`).

  Four copies of the "set SOL_HOME" error became one.
- **Behaviour:** source-checkout resolution is unchanged, with one deliberate difference. An invalid explicit `SOL_HOME` used to surface as "cannot locate the Sol monorepo root". It is now `Invalid_sol_home`, naming the bad value and the missing sentinels. Real binary, in `examples/pluto`:
  ```
  $ SOL_HOME=/tmp sol cloud plan dev/aws/us-east-1
  error: SOL_HOME=/tmp is not a Sol checkout (it has no framework/ocaml/sol-svc/lib/dune and framework/ocaml/kafka-eio-service/lib/dune, or it is inside a _build tree).
    Set SOL_HOME to your Sol checkout and re-run:
      export SOL_HOME=/path/to/sol
  ```
- **Guard:** `internal/ci/check_platform_assets_owner.sh`, run unconditionally in CI. It flags a `"SOL_HOME"` literal, `/proc/self/exe`, a `"platform/…"` literal, or use of the resolver's discovery functions in any CLI source outside the resolver. It checks 181 files and passes. Its mutation test (`test_platform_assets_owner.sh`) confirms it passes on the owner and on tests, and fails on each of four planted violations.
- **Tests:** a new `cli/test/test_platform_assets.ml` covers:
  - a valid `SOL_HOME` wins over discovery, while the test binary sits inside a checkout that discovery would find;
  - an invalid `SOL_HOME` is `Invalid_sol_home`, never a fall-through;
  - an unset `SOL_HOME` discovers this checkout, whose `components.json` exists;
  - a `_build` mirror is rejected;
  - every accessor's path.

  The existing `test_scaffold` and `test_dev_observability` checks now call the resolver.
- Verification: `dune build`, `dune test cli/ --force` (60 suites, 0 failures), and `internal/ci/check_ocamlformat.sh --all` clean.
- Demo/example: not applicable (internal refactor; source users see the same behaviour).
- Language parity (DEC-022): no impact.
