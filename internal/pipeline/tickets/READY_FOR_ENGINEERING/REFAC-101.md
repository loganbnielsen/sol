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
