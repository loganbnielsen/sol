---
id: CODE_LAYER-010
type: bug
severity: medium
source: CODE_LAYER-005 follow-up (scope deferred during implementation, 2026-09-06)
branch: CODE_LAYER-010/redpanda-postgresql-component-values
worktree: ../sun-CODE_LAYER-010-redpanda-postgresql-component-values
pr: https://github.com/loganbnielsen/sun/pull/129
---

**Depends on:** None.

## Problem

CODE_LAYER-005 (`docs/architecture/adr/0001-layer2-platform-component-source-of-truth.md`)
unified `cmd_dev.ml` and `platform/infra/base/main.tf`'s independently
hand-maintained Helm values for Loki, Grafana, Tempo, and Prometheus behind
`platform/components/<name>/values-{common,local,durable}.json`. Redpanda
and PostgreSQL were deliberately left out of that PR to keep it reviewable
and fully live-verified rather than growing further — they still have the
same duplication CODE_LAYER-005 fixed for the other four components:

- `cmd_dev.ml`'s `helm_install "redpanda" "redpanda/redpanda" ...` and
  `helm_install "postgresql" "bitnami/postgresql" ...` calls still carry
  inline OCaml value lists.
- `platform/infra/base/main.tf`'s `helm_release "redpanda"` and
  `helm_release "postgresql"` still carry hand-typed `set {}` blocks.

Same drift risk BUG-013/BUG-016 already demonstrated for Loki applies here
too — nothing has caught it yet only because no cloud-vs-local Redpanda/
PostgreSQL value has needed a fix since these went in.

## Goal

Redpanda and PostgreSQL join Loki/Grafana/Tempo/Prometheus under
`platform/components/`, closing the last gap in CODE_LAYER-005's migration.

## Remediation

Same pattern CODE_LAYER-005 already established — read
`cli/sun/lib/sun_cli_platform_component.mli`'s doc comment and
`platform/infra/base/main.tf`'s `loki`/`grafana`/`tempo`/`prometheus`
`helm_release` resources for the shape to replicate:

- `platform/components/redpanda/values-{common,local,durable}.json` and
  `platform/components/postgresql/values-{common,local,durable}.json`.
- `cmd_dev.ml`'s Redpanda/PostgreSQL `helm_install` calls read via
  `Sun_cli_platform_component.merged_values_yaml`.
- `platform/infra/base/main.tf`'s matching `helm_release` resources read
  via `jsondecode(file(...))`, same `local.<name>_component_values`
  pattern already used for the other four.
- Add both charts' migrated keys to `tools/ci/check_platform_component_drift.sh`'s
  `migrated_keys` list.

## Acceptance criteria

- `platform/components/redpanda/` and `platform/components/postgresql/`
  exist with the same common/local/durable split.
- `cmd_dev.ml` and `platform/infra/base/main.tf` contain no independently
  encoded Redpanda/PostgreSQL operational values.
- CI guardrail covers both charts' migrated keys.
- `dune build`/`cli/sun` tests and `terraform validate`/`fmt` pass; a real
  `helm upgrade` against a live cluster (same verification CODE_LAYER-005
  did) confirms both releases stay healthy.
