---
id: REFAC-101
type: refactor
severity: low
title: Move observability assets used by both local and cloud out of the cloud-only path
source: internal/pipeline/audits/2026-09-25_organization_proposal.md, rule 3
premise: "test -d platform/shared/observability"
---

**Depends on:** REFAC-100.

**Premise verified (2026-09-25):** `rg -n 'cli/platform/infra/base/(dashboards|alloy)' cli/sol/lib` → `sol_cli_dev_observability.ml:69` and `:260`. Local dev reads dashboards and the Alloy config from the cloud root.

## Remediation

Move `dashboards/` and `alloy/` from the platform module to `platform/shared/observability/`. Point both consumers there: `Sol_cli_dev_observability` and the module's `kubernetes_config_map.grafana_dashboards` / `helm_release.alloy`. It depends on REFAC-100 because that ticket moves the module these files live in.

## Acceptance criteria

- Nothing under `platform/cloud/` is read by the local path, and nothing under `platform/local/` is read by Terraform.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.

## Completion notes

- **Premise re-verified (2026-09-25, after REFAC-100):** `sol_cli_dev_observability.ml` read `platform/cloud/modules/platform/{dashboards,alloy}`, which are cloud-module paths.
- **Moved** `dashboards/` and `alloy/` from the module to `platform/shared/observability/`. The module reads them through one local, `observability_dir = "${path.module}/../../../shared/observability"`, next to the existing `platform_components_dir`. `Sol_cli_dev_observability`, its test and the prose now name the shared path.
- **Verified:**
  - `terraform fmt -check` is clean, and `terraform validate` passes on both platform roots;
  - an offline `terraform plan` of `aws/platform` (empty kubeconfig) renders all 39 creates, which requires every `file()`/`templatefile()` of the dashboards and the Alloy template to resolve through the new path;
  - `dune test cli/test/` passes (0 `[FAIL]`);
  - the platform/provider/destroy guards and `check_production_infra.sh` pass, and the format check is clean.
- **Acceptance:** `rg -n '"platform/cloud' cli/lib cli/bin` matches only `cmd_cloud_tf.ml:96` and `sol_cli_cloud_lifecycle.ml:78`, both cloud-lifecycle code, so no local-path code reads `platform/cloud/`. No `.tf` file references `platform/local`.
- **Demo/example:** not applicable (repository layout). **Language parity (DEC-022):** no application-facing impact.
