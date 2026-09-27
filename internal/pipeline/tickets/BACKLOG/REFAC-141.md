---
id: REFAC-141
type: refactor
severity: low
title: Enforce in code the invariants that only comments stated
source: comment removal (2026-09-27)
---

**Depends on:** None.

Removing every comment surfaced rules that were stated in prose and not held by the code. Each can be worked around today. Found by scanning the removed comments for "mirror", "kept identical", "must match", "callers must" and "never call" (the scan is in the comment-removal PR's description); each item names the file at the PR's base.

## Duplicated logic or constants kept in step by a comment

1. `cli/bin/cmd_deploy_event.ml` "mirrors" `cmd_migrate.ml`'s `cluster_pg_exists` and `auto_forward_pg`: two copies of an in-cluster service probe and port-forward. One helper.
2. `cli/bin/cmd_up.ml` "mirrors `cmd_deploy`'s helpers" for the local destination: share them.
3. `cli/lib/deploy/sol_cli_status.ml` restates `platform/cloud/modules/platform/main.tf`'s monitoring namespace and Loki/Prometheus service names, which `Sol_cli_local_platform.endpoints` also restates. One definition, and a test against the Terraform.
4. `cli/lib/local/sol_cli_local_platform.ml`'s chart pins restate `main.tf`'s ("dev mirrors prod"). `test_local_platform` checks Redpanda's version only; check every chart and version.
5. `cli/lib/local/sol_cli_dev_observability.ml`'s derived-field regex "must match obs-loki-eio's logfmt output". A test that formats a line with `Obs_loki` and matches it.
6. `cli/lib/deploy/sol_cli_deploy_event.ml`'s field set "mirrors" `Sol_cli_manifest_yaml.render_taxonomy_labels`. One taxonomy definition both use.
7. `cli/lib/base/sol_cli_profile.ml`'s capacity envelope must "grow with the charts" in `variables.tf`. Nothing ties the two; a test that reads the declared requests.
8. `cli/lib/base/sol_cli_release_id.ml`'s `encoding_version` must be bumped when the projection's meaning changes. A golden test of the canonical encoding.

## Caller obligations only prose enforced

9. `Sol_cli_terraform_plan.show_and_record`: callers "must not run [show] through `run_phase`", which would log plan JSON carrying secrets (SEC-008). A type that `run_phase` cannot accept.
10. `Sol_cli_rollout_diagnosis.format_service_diagnosis`: "pass only a real pod list from a successful fetch; [] means confirmed zero pods". A confirmed-pods type only a successful parse constructs.
11. `soldev pipeline merge-finish` is "internal, never call directly" yet is a public subcommand. Make it unreachable except from `merge`.

## Debt that was marked `ponytail:`

12. Migration files ride in one ConfigMap, capped at 1 MiB (`Sol_cli_manifest_yaml`). Refuse an oversized set with a clear error instead of failing at apply.
13. The pre-rename `sun-local` k3d check (`Sol_cli_local_cluster`) was to be deleted "once nobody plausibly still has one". Sol is pre-alpha with no users: delete it.
14. `framework/ocaml/sol-svc/lib/auth_internal.ml`'s fixed JWKS rotation window.

## Acceptance criteria

- Each item is enforced by a type, a single definition, a test or a guard, or its completion note says in one line why not.
- Demo/example: per item, only where an author-facing surface changes. Language parity: check items 5 and 6 against the TypeScript framework.
