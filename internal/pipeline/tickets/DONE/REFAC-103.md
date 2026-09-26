---
id: REFAC-103
type: refactor
severity: low
title: Move maintainer tooling and demo leftovers out of platform/local
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rules 1 and 5
---

**Depends on:** REFAC-099.

**Premise verified (2026-09-25):** `ls cli/platform/local/scripts` includes `run_tests.sh`, `perf.sh`, `install-hooks.sh`, `prepare-framework-deps.sh`, `prove-workspace-independence.sh` and `check-schemas.sh` beside the `ensure-*.sh` scripts that `sol local` runs. `rg -n --hidden -g '!.git' 'local/k8s|deploy-local\.sh|demo-app\.yaml|svc-template\.yaml'`, excluding `internal/pipeline/`, matches only `cli/platform/local/k8s/deploy-local.sh:27`, the directory referencing itself.

## Remediation

- Move the maintainer scripts to `internal/tooling/` and update `soldev` (`merge-finish` runs `run_tests.sh`), the hooks, CI, `AGENTS.md` and `CONTRIBUTING.md`.
- `local/k8s/` appears unused: delete it, or move it to `internal/fixtures/` if a caller turns up. Re-run the search above first and record the output.
- `local/schemas/payments-value.json` and `check-schemas.sh`: the schema belongs to pluto's `payments` domain. Move it to `examples/pluto/` or `internal/fixtures/` depending on who runs the check.
- `local/config/grafana-dashboards/sol-demo-overview.json` is the demo's dashboard. Move it to `internal/fixtures/local-demo/` and point `ensure-grafana.sh` at it, or fold it into `shared/observability/` if it is product.

## Acceptance criteria

- `platform/local/` contains only what `sol local` executes or reads.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `internal/planning/WORK_SUMMARY.md`.

## Completion notes

**Premise re-verified (2026-09-25):** `platform/local/scripts/` mixed maintainer tooling with `ensure-*.sh`, and `platform/local/k8s/` still had no caller outside itself.

**What `platform/local` actually is, which corrects the ticket's rule.** The ticket said `platform/local` should hold "only what `sol local` executes or reads". But `sol local` reads **nothing** from `platform/local`. `rg -n 'platform/local|ensure-[a-z]+\.sh' cli --glob '*.ml'` matches only the `prepare-framework-deps.sh` instruction `sol new` prints. `sol local infra up` installs through Helm/k3d from `platform/shared/components.json`. The `ensure-*.sh` scripts start *native* local infrastructure, and users run them: `examples/pluto/README.md:17-18` and `examples/pluto/app/demo_ts/README.md:52-56` tell them to. So `platform/local` is the user-facing local-environment tooling, and the MECE line is user-run (stays) versus maintainer-run (moves to `internal/`).

**Moved to `internal/tooling/scripts/`** (maintainer-run): `run_tests.sh`, `perf.sh`, `install-hooks.sh`, `prove-workspace-independence.sh`. Same depth, so their `../../..` root navigation is unchanged. `run_tests.sh` calls the `ensure-*.sh` scripts via `$REPO_ROOT/platform/local/scripts/`, not `$SCRIPT_DIR`. References were updated in 14 files, including `soldev_merge.ml`, both hooks, `ci.yml` and `workspace-independence.yml` (its `paths:` filter passes `check_workflow_paths.sh`). `test_hook_install.sh`'s scratch layout was updated too.

**Kept, contrary to the ticket's list:**
- **`prepare-framework-deps.sh`:** `sol new` tells users to run it (`sol_cli_cmd_new.ml:186`, `sol_cli_scaffold_templates.ml:131`), so it's user-facing.
- **`config/grafana-dashboards/sol-demo-overview.json`:** it's what the user-run `ensure-grafana.sh` provisions. Moving it to `internal/fixtures/` would make a user-facing script read `internal/`.
- **`create-topics.sh`, `start-redpanda.sh`:** `ensure-broker.sh` calls them.

**Deleted as unused** (operator: "unused files can be deleted"). Each was checked with `rg --hidden -g '!.git' -g '!_build' '<name>' .`, excluding `internal/pipeline/` and dated records:
- `platform/local/k8s/`, where the only match was itself;
- `platform/local/schemas/payments-value.json` and `scripts/check-schemas.sh`, referenced only by each other and the dead `k8s/svc-template.yaml`, and not by CI;
- `scripts/setup-local.sh`, with no reference at all (a WSL2 Redpanda installer that `ensure-broker.sh` supersedes);
- `cli/migrations/{001_hosted_control_plane,002_hosted_release_digest}.sql`, unreferenced and unchanged since the history baseline, as flagged in REFAC-099;
- `platform/cloud/modules/platform/.terraform.lock.hcl`, left over from when `base` was a root. Terraform reads lock files only in roots, and both platform roots have their own.

**Verified:**
- `dune build` passes, and soldev builds with the new `run_tests.sh` path;
- `test_hook_install.sh`, `test_workflow_paths.sh`, `check_workflow_paths.sh` and `port-preflight_test.sh` pass;
- `bash -n` passes on every moved script, and `perf.sh status` runs from its new place;
- no live reference to any moved or deleted path remains.

**Demo/example:** the example READMEs' `ensure-*.sh` instructions are unchanged and still valid. **Language parity (DEC-022):** no application-facing impact.
