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
- Update `docs/planning/WORK_SUMMARY.md`.
