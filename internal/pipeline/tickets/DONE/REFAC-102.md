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

## Completion notes

- **Premise re-verified (2026-09-25, `origin/main` after REFAC-100):** `platform/components/*/` held 6 × `values-{common,local,durable}.json`, and tempo's three were `{}`.
- **The change.** The 18 files became `platform/shared/components.json`, keyed `<component>.{common,local,durable}`. Every component carries all three layers, and key order within each layer is preserved. `platform/components/` is removed.
  - **Terraform** decodes the file once (`local.platform_components`), and each `helm_release` takes `jsonencode(local.platform_components.<c>.common)` plus `[<profile>]`.
  - **`Sol_cli_platform_component`** reads the same file with `yojson`. There's no YAML and no new parser.
- **Proof, before vs after:**
  - **CLI:** a temporary probe executable, not committed, dumped `merged_values_yaml` for every component × {local, durable} plus a nonexistent component, before and after. All 14 documents are **byte-identical** (`diff` empty).
  - **Terraform:** an offline `terraform plan` of `aws/platform` (empty kubeconfig) dumped every `helm_release`'s rendered `values`. They're **identical** before and after for the local profile (9 releases) and the durable profile (10 releases, `observability_backend=self_hosted_durable`).
- **Behaviour change:** a missing `components.json` is now an error. Before, a missing per-component file was silently empty. A layer or component the file doesn't name is still an empty object, and there's a new unit case for the unnamed component.
- **Profile-only keying is now enforced.** `check_platform_component_drift.sh` fails unless every component has exactly `common`/`local`/`durable`. Mutation: adding `loki.prod` fails it; the real file passes.
- **Docs:** ADR 0001's decision section now shows the one-file format, with an amendment note that the layering and every rule are unchanged. Comments in `cmd_local.ml`, `main.tf`, the GCP cluster root and the drift guard now name layers instead of files.
- **Verified:**
  - `dune test cli/test/` passes (0 `[FAIL]`), including the 4 `platform_component` cases;
  - the drift, production-infra, provider-roots, destroy-completeness, workflow-paths and examples guards pass;
  - the format checks for OCaml and Terraform are clean.
- **Demo/example:** not applicable (platform-internal values format; nothing an app author writes). **Language parity (DEC-022):** no application-facing impact.
