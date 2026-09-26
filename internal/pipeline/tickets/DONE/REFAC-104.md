---
id: REFAC-104
type: refactor
severity: low
title: Split cli/lib into per-domain dune libraries along its dependency graph
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 6
---

**Depends on:** REFAC-099.

**Premise verified (2026-09-25):** `ls cli/sol/lib | wc -l` → 157 files in one directory, grouped only by prefix (`sol_cli_deployment_*` ×15, `sol_cli_release_*` ×10, `sol_cli_terraform_*` ×7, …).

## Remediation

**The deliverable is the graph and a decision for each domain.** Moving files is secondary.

1. Derive the module dependency graph (`dune describe` or `ocamldep`) and propose domains that minimize cross-domain edges. A starting sketch from prefixes is `workspace`, `local`, `cloud`, `deploy`, `kubernetes`, `observability` and `secrets`, but the graph decides.
2. For each domain, record **library** (it has no cycle with the rest) or **stays in the top-level library** (and name the cycle that keeps it there).
3. Each library domain gets its own directory and `dune` stanza, still `(wrapped false)`. No module is renamed, but a module can only reference another domain if its `dune` lists that domain, so the boundary is enforced at build time. The top-level library keeps an explicit `(modules …)` list for the remainder, as `cli/sol/lib/dune` does today.
4. **Mechanism:** use `(include_subdirs no)`, the default, with a `dune` per domain directory. Don't use `(include_subdirs unqualified)`: dune treats every subdirectory of such a tree as part of the enclosing library, so nested library stanzas can't coexist with it. Use it only if the graph's answer turns out to be "folders everywhere", and say so if it does.

## Acceptance criteria

- No module name changes: `git diff --stat` shows renames only, apart from `dune` files.
- The completion notes include the graph, the decision for each domain, and, for each domain left in the top-level library, the cycle that keeps it there.
- A mutation check: adding a reference from one library domain to another that its `dune` doesn't list fails the build.
- `dune build`, `dune test cli/` and the format check pass.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.


## Completion notes

**Premise re-verified (2026-09-25):** `cli/lib` held 86 modules (157 files, counting `.mli` and `dune`) in one `(wrapped false)` library with an explicit `(modules …)` list.

**The graph.** `ocamldep -modules cli/lib/*.ml cli/lib/*.mli` gives 86 modules and 273 internal edges. There are no module-level cycles, as OCaml requires within one library.

**Domains.** Each module is assigned to one domain (module names drop the `sol_cli_` prefix):

- **base** (21): `process`, `kube_destination`, `kubernetes_name`, `release_id`, `deployment_id`, `plan_ids`, `profile`, `provider`, `availability`, `fs_walk`, `image_ref`, `destroy_verification`, `migration`, `migration_disposition`, `redaction`, `sensitive_vars`, `scaffold`, `scaffold_templates`, `state`, `alerting`, `aws_credentials`
- **kube** (8): `kubectl`, `port_forward`, `cluster`, `docker`, `helm`, `rollout_diagnosis`, `deployment_state`, `execution`
- **workspace** (9): `toml`, `compat`, `workspace`, `manifest_yaml`, `manifest`, `config`, `workspace_scan`, `cmd_new`, `observability_url`
- **cloud** (17): `run_log`, `supervised`, `terraform`, `terraform_plan`, `terraform_steps`, `terraform_vars`, `provider_capabilities`, `cloud_lifecycle`, `cloud_destroy`, `cloud_apply`, `destruction`, `aws_cluster`, `aws_destruction`, `gcp_cluster`, `gcp_destruction`, `provider_registry`, `target_report`
- **deploy** (28): `deployment_plan`, `deployment_render`, `deployment_scope`, `release`, `release_store`, `release_retention`, `release_inspection`, `deployment`, `deployment_store`, `deployment_attempt`, `executor`, `factory`, `env_target`, `up_execution`, `rollback`, `secret`, `substrate`, `boundary_lease`, `status`, `logs`, `open`, `command_request`, `workload_selection`, `check`, `manual_job_name`, `deploy_event`, `destination`, `profile_preflight`
- **local** (3): `dev_observability`, `platform_component`, `loki`

**Domain-level graph: acyclic, so every domain became a library and nothing stays behind.**

| from → to | edges | example |
|---|---|---|
| kube → base | 13 | `cluster → process` |
| workspace → base | 18 | `cmd_new → scaffold` |
| workspace → kube | 3 | `manifest → kubectl`, `manifest → port_forward`, `workspace → port_forward` |
| cloud → base / kube / workspace | 26 / 7 / 7 | `cloud_lifecycle → config` |
| deploy → base / kube / workspace | 55 / 18 / 30 | `check → manifest` |
| deploy → cloud | 1 | `profile_preflight → provider_capabilities` |
| local → base / workspace | 1 / 2 | `dev_observability → cmd_new` |

That's 92 edges within domains and 181 across them. Every cross edge points down the DAG `base ← kube ← workspace ← cloud ← deploy`, with `local → workspace, base`.

**Answer to DEC-046 open question 3, per domain:** all six are **libraries** (`sol_cli_<domain>`, `(wrapped false)`, `(include_subdirs no)`, one `dune` per directory). No domain was left in the top-level library, because no domain-level cycle exists. `sol_cli` is now an umbrella with `(modules)` empty that lists the six, so `cli/bin`, `cli/test` and `internal/fixtures` are unchanged (implicit transitive deps).

**Enforced at build time.** Mutation: appending `let _boundary_probe = Sol_cli_config.load` to `base/sol_cli_profile.ml` (`base` doesn't list `sol_cli_workspace`) fails `dune build ./cli/lib/base` with "Error: Unbound module Sol_cli_config".

**Per-domain external deps** come from `ocamldep`, not copied: `base` unix/yojson; `kube` adds ptime; `workspace` cmdliner/otoml/unix; `cloud`/`deploy`/`local` unix/yojson. **`sol_process` is dropped.** No `cli/lib` module references `Sol_process` (only `internal/tooling/soldev` does, with its own dependency), so it was an unused dependency of `sol_cli`.

**Seams worth a follow-up, not changed here:**
- **workspace → kube:** the workspace model (`Sol_cli_manifest`, `Sol_cli_workspace`) depends on cluster access (`kubectl`, `port_forward`). The model shouldn't need a cluster; moving those calls to their callers would make `workspace` depend on `base` only.
- **deploy → cloud** is one edge (`profile_preflight → provider_capabilities`).
- **local → workspace** exists only because `Sol_cli_cmd_new.infer_sol_home` lives with `sol new`. Moving it to `base` would decouple local dev from the scaffold.

**Mechanical checks:**
- `git diff -M --name-status -- cli/lib` shows 156 `R100` (pure renames), six new `dune` files and the rewritten umbrella. No module was renamed or edited.
- 21 files that named `cli/lib/<module>.ml` by path now name `cli/lib/<domain>/<module>.ml`, including `provider_dispatch_allowlist.txt` (path-keyed). Two guard fixtures (`test_provider_dispatch_check.sh`, `test_qualification_transport_check.sh`) now mirror the domain layout.
- `check_provider_dispatch.sh` scans with a recursive `find`, so it still sees every module.

**Verified:**
- `dune build` and `dune test cli/test/` pass (0 `[FAIL]`);
- every `internal/ci/check_*.sh` and `test_*.sh` passes, as does `check_production_infra.sh`;
- `check_ocamlformat.sh --all` is clean.

**Demo/example:** not applicable (internal code layout). **Language parity (DEC-022):** no application-facing impact.
