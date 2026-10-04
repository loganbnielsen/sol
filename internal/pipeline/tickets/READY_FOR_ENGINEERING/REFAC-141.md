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

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: the comment-removal invariants the ticket lists are still prose-only; items 1-14 are unimplemented.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Premise verification (2026-10-03, part A)

Re-checked each item against `origin/main` at `38fe8a2d`. The Disposition's
"items 1-14 are unimplemented" is not accurate: items 1 and 8 are already
resolved, and item 11 cannot be implemented as written.

- **1 — stale.** `cluster_pg_exists`/`auto_forward_pg` now exist only in
  `cli/bin/cmd_migrate.ml`; `cli/bin/cmd_deploy_event.ml` has neither
  (`rg -n 'cluster_pg_exists|auto_forward_pg' cli/bin/*.ml`).
- **2 — real.** `cmd_up.ml` and `cmd_deploy.ml` independently define
  `check_contract`, `ensure_postgres_url`, `print_header` and `to_manifest_primitive`.
- **3 — real.** `cli/lib/deploy/sol_cli_status.ml` still hardcodes
  `-n monitoring svc/loki` and `svc/prometheus-server`, which
  `Sol_cli_local_platform.endpoints` also names.
- **4 — real.** `cli/lib/local/sol_cli_local_platform.ml` hardcodes every chart
  version (e.g. `26.1.11`, `18.8.17`) with nothing tying them to `variables.tf`.
- **5 — real, not yet implemented.** `cli/lib/local/sol_cli_dev_observability.ml`
  emits `derivedFields`; no test feeds it a line formatted by `Obs_loki`.
- **6 — real, renamed target.** `Sol_cli_manifest_yaml.render_taxonomy_labels` no
  longer exists (it is now `taxonomy_labels`); `sol_cli_deploy_event.ml` still
  carries its own label list.
- **7 — real.** `cli/lib/base/sol_cli_profile.ml`'s `capacity_envelope` has no tie
  to the declared requests in `variables.tf`.
- **8 — already satisfied.** `cli/test/inline/test_release_id.ml`'s
  `test_known_vector` pins `r-4b2ed7373a80de25` for a fixed content, so any change
  to the canonical encoding without a version bump fails that test.
- **9 — real.** `Sol_cli_terraform_plan.show_and_record` still takes a bare
  `~show:(unit -> ...)`, so `run_phase` can be handed the secret-bearing plan JSON.
- **10 — real.** `format_service_diagnosis` still takes `pod_status list`, where
  `[]` is overloaded to mean "confirmed zero pods".
- **11 — resolved by operator decision; implemented in Part B.** `merge`
  deliberately does not invoke `merge-finish` automatically (BUG-038 removed that),
  so the command was an orphaned public lifecycle surface with no pipeline phase
  behind it; the operator chose to delete it rather than keep a misleading entry
  point.
- **12 — implemented in Part C.** `Sol_cli_manifest_yaml.migration_configmap_doc`
  renders the ConfigMap unconditionally, so the cap is enforced where the files are
  read (`Sol_cli_migration_gate.migration_files`) — the layer that already returns a
  `result` and validates NUL, and the only path into `migration_configmap_doc`.
- **13 — implemented in this change** (see below).
- **14 — real.** `framework/ocaml/sol-svc/lib/auth_internal.ml`'s `get_jwks` fixes
  `max_age_s` to `Auth_cache.ttl_s`.

## Part A (2026-10-03) — item 13

Deleted `refuse_pre_rename_cluster` and its call from
`cli/lib/local/sol_cli_local_cluster.ml` (and the now-unused `open Result.Syntax`).
Sol is pre-alpha with no users, so no `sun-local` cluster can plausibly still
exist. The function was not exported by the `.mli` and no test referenced it.

- Demo/example coverage: not applicable — an internal CLI guard; no author-facing
  surface changes.
- Language parity: no impact — CLI-internal, no framework contract or primitive.

## Part B (2026-10-03) — item 11

Operator decision: `merge-finish` no longer represents a real pipeline phase after
BUG-038 removed the automatic post-merge path, so it is deleted rather than kept as
an orphaned public command. Removed:

- The `merge-finish` subcommand, its `merge_sha_arg` positional and its group
  registration in `internal/tooling/soldev/bin/cmd_pipeline.ml`.
- `Soldev_merge.run_merge_finish`, `post_merge_action` and
  `post_merge_action_of_rc` in `internal/tooling/soldev/lib/soldev_merge.ml`, which
  nothing else called.
- The two `post_merge_action_of_rc` tests and their group in
  `internal/tooling/soldev/test/test_merge.ml`.
- The `pipeline merge-finish` bullet in `AGENTS.md` (both the role list and the
  "Shepherding PRs to merge" paragraph) and the `merge-finish` sentence in
  `CONTRIBUTING.md`.

`internal/tooling/scripts/run_tests.sh` and the informational perf baseline are
untouched: `run_tests.sh` remains the local correctness suite, and
`perf.sh record --update-baseline` remains the only baseline writer. If an explicit
post-merge diagnostic is wanted later, it should be a new ticket exposing it under
semantics that describe what it actually does.

- Demo/example coverage: not applicable — internal tooling; no author-facing surface.
- Language parity: no impact — pipeline tooling, not a framework contract or primitive.

## Part C (2026-10-03) — item 12

`Sol_cli_migration_gate.migration_files` now refuses a set whose files total more
than 1 MiB (`1024 * 1024` bytes), instead of letting the apply fail on an oversized
ConfigMap. The refusal names both the total and the limit, and rides the existing
`result` channel: `sol migrate` reports it as an error, and the verification gate
surfaces it as `Unavailable` rather than as drift or absence.

The cap is enforced at the read layer, not in
`Sol_cli_manifest_yaml.migration_configmap_doc`: the renderer returns a YAML document
rather than a `result`, and `migration_files` is the only path that feeds it, so
this keeps the error channel in one place. `internal/tooling/scripts/run_tests.sh`
and the perf baseline are untouched.

- Test: `test_migration_gate.ml` adds `test_oversized_set_is_refused`, which writes a
  file one byte over the limit and asserts both the limit and the total appear in the
  error.
- Demo/example coverage: not applicable — a refusal on an internal input, no
  author-facing surface changes.
- Language parity: no impact — CLI-internal, no framework contract or primitive.

The remaining real items (2-7, 9, 10, 14) stay open; the ticket remains in
`READY_FOR_ENGINEERING/`.
