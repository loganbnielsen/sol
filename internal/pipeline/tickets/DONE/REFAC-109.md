---
id: REFAC-109
type: refactor
severity: low
title: Rename Sol_cli_config's overloaded t / target / target names
source: operator code-review notes (2026-09-26), cli/lib/workspace/sol_cli_config.ml
---

**Depends on:** FEAT-100.

## The problem

`Sol_cli_config` has a resolved-configuration type `t` with a field `target` of type `target`, and an accessor `Sol_cli_config.target : t -> target option`. A reader sees `target cfg`, `cfg.target` and `(target : target)` and can't tell the whole resolved config from the deploy destination inside it. It's correct at runtime, but costly to read.

## Remediation

- Rename for meaning. Proposed: the resolved config `t` → `resolved`; the `target` record → `destination`, since it says where and how a workload is deployed; and the accessor to match. Choose the final names in this ticket's first commit, and update every call site (pre-alpha, no aliases).
- Do it after FEAT-100, which restructures this module's resolution code, so the rename happens once.

## Acceptance criteria

- No type and value in `Sol_cli_config`'s interface share the name `target`.
- **Demo/example:** not applicable (internal); state it.

## Completion notes

Premise checked 2026-09-25 on `cf6737b0`: `val target : t -> target option` was still in `sol_cli_config.mli`, and `rg -c 'Sol_cli_config\.target\b' cli` counted its call sites.

**Names chosen: not the proposed renames. The fix is the type split.** The confusion wasn't really the word `target`. It was that one type `t` served two roles: a *layer* being merged (where the target is legitimately optional) and the *resolved* result (where it is always present). That forced the `target option` accessor and a `match ... | None -> <unreachable>` at every caller. So:

- The internal merge type is now `layer` (not exported). The exported `t` is the resolved config, `{ project; target : target; resources; services }`, whose `target` is always present.
- `val target : t -> target option` is removed. Callers read `cfg.Sol_cli_config.target` directly, and each dead `None` branch is gone (cmd_alert, cmd_cloud_tf, cmd_deploy, cmd_migrate ×2, cmd_plan, cmd_target, sol_cli_terraform_vars, sol_cli_observability_url, sol_cli_destination, sol_cli_deployment_plan, and the tests).
- `target` → `destination` was rejected: `Sol_cli_destination` (`cli/lib/deploy/sol_cli_destination.ml`) already exists as a separate concept (where the rendered manifests go), so the rename would have created a worse collision. `target` is also the user-facing term (`sol deploy <TARGET>`, `targets:` in `environments.yml`), so it stays.
- `parse_target : string -> (target, error) result` is exported for tests and callers that need a bare target from an address.

Acceptance: the interface no longer has a value and a type both named `target` (`rg -n '^val target\b' cli/lib/workspace/sol_cli_config.mli` matches nothing; `val target_declared`/`val target_source` remain and take a `target`).

Verification: `dune build`, `dune test cli/ --force` (58 suites, 0 failures), `internal/ci/check_ocamlformat.sh --all` clean.

- Demo/example: not applicable (internal refactor, no app-author surface).
- Language parity (DEC-022): no application-facing impact.
