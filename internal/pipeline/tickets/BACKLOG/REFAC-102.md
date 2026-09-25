---
id: REFAC-102
type: refactor
severity: low
title: Collapse the 18 platform component values files into one profile-keyed components.json
source: internal/pipeline/audits/2026-09-25_organization_proposal.md § Platform component values
premise: "test -f platform/shared/components.json"
---

**Depends on:** REFAC-099.

**Premise verified (2026-09-25):** `ls cli/platform/components/*/`: 6 components × `values-{common,local,durable}.json`, and tempo's three are each `{}`.

## Remediation

- Replace `components/<c>/values-{common,local,durable}.json` with `platform/shared/components.json`, keyed `<component>.{common,local,durable}`. The layering doesn't change (ADR 0001: common deep-merged with the profile overlay).
- **Stays JSON.** Terraform keeps `jsondecode(file(...))`, and `Sol_cli_platform_component.merged_values_yaml` keeps `yojson`. No new parser. The proposal's § *Platform component values* explains why YAML was dropped: there is no YAML library in the CLI, and two YAML implementations would have to agree exactly on what reaches Helm.
- Update ADR 0001's paths and `internal/ci/check_platform_component_drift.sh`.
- **Key by profile only.** A key named after an env, provider or region is a review failure, per the proposal's rationale.

## Acceptance criteria

- For every component and profile, the merged values are byte-identical (after normalization) to what the JSON files produced. Show it with a before/after dump.
- `sol local infra up` and a module `terraform plan` show no values diff.
- `rg -n --hidden -g '!.git' '<old path>'` returns nothing outside `internal/pipeline/` and dated historical records. Put the exact commands and their empty output in the completion notes.
- `dune build`, `dune test cli/` and `internal/ci/check_ocamlformat.sh --all` pass, and CI is green.

## Completion notes (required)

- Demo/example: not applicable (repository layout; no change to what an app author writes) — state it.
- Language parity (DEC-022): no application-facing impact — state it.
- Update `docs/planning/WORK_SUMMARY.md`.
