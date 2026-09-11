---
id: CODE_LAYER-008
type: bug
severity: high
source: project/audits/2026-09-06_code_layer_audit.md
branch: CODE_LAYER-008/pin-versions-reconcile-values
worktree: ../sun-CODE_LAYER-008-pin-versions-reconcile-values
pr: https://github.com/loganbnielsen/sun/pull/126
---

**Depends on:** None.

## Problem

Every `helm_release` in `platform/infra/base/main.tf` pins an exact chart
`version`: redpanda `5.8.12`, postgresql `15.5.1`, loki `18.12.1`, grafana
`13.2.1`, alloy `1.12.1`, tempo `2.3.0`, prometheus `25.20.1`. Every matching
`helm_install` call in `cmd_dev.ml` omits `version` entirely, so
`sun dev up`'s `helm repo update` + `helm upgrade --install` resolves to
whatever each chart repo's latest release happens to be at the moment it
runs — a moving target `platform/infra/base/main.tf` explicitly refuses to
be for the exact same charts. This is the mechanism that let a chart's own
shifting defaults (Loki's `replication_factor`, BUG-013/BUG-016) diverge
between dev and prod undetected, independent of any values drift.

Doing the same per-chart comparison BUG-016 did for Loki turned up three
more concrete, currently-unreconciled value diffs:

- **Redpanda**: `base/main.tf` sets `config.cluster.auto_create_topics_enabled
  = true` explicitly; `cmd_dev.ml`'s `helm_install "redpanda" ...` sets no
  such value, leaving it at whatever the chart defaults to.
- **PostgreSQL**: `base/main.tf` sets `primary.persistence.enabled`
  explicitly (`var.postgres_persistent_storage`); `cmd_dev.ml`'s
  `helm_install "postgresql" ...` leaves it at the bitnami chart's own
  default.
- **Grafana**: `base/main.tf` sets `adminPassword` explicitly
  (`var.grafana_admin_password`); `cmd_dev.ml`'s `helm_install "grafana" ...`
  leaves it at the chart's own default, so `sun dev up`'s Grafana admin
  credential is undocumented and chart-version-dependent rather than a known
  value.

None of these three has produced a reported failure yet, but each is the
same "hand-maintained matching values, no shared source" shape that already
produced BUG-013/BUG-016.

## Goal

A fresh `sun dev up` installs the exact chart versions
`platform/infra/base/main.tf` pins for the equivalent local profile, and its
per-chart values no longer silently disagree with `base/main.tf`'s explicit
overrides for the same chart.

## Remediation

- Add `~version:"<pinned>"` (or the `Sun_cli_helm` equivalent) to every
  `helm_install` call in `cmd_dev.ml` — redpanda, postgresql, loki, grafana,
  alloy, tempo, prometheus — matching the version currently pinned in
  `platform/infra/base/main.tf` for each.
- Add `("config.cluster.auto_create_topics_enabled", Bool true)` to the
  Redpanda `helm_install` call.
- Either add an explicit `primary.persistence.enabled` value to the
  PostgreSQL `helm_install` call (matching dev's ephemeral-cluster
  expectations) or document inline why dev intentionally leaves it at the
  chart default.
- Set an explicit, documented `adminPassword` value on the Grafana
  `helm_install` call (a fixed dev-only value is fine, matching Postgres's
  hardcoded `"dev"` password convention) so `sun dev up`'s Grafana login is
  predictable.

This can land ahead of CODE_LAYER-005's larger shared-source-of-truth
mechanism as an immediate safety fix; fold these same pinned
versions/values into that shared spec file once it exists so they don't
need re-syncing by hand a second time.

## Acceptance criteria

- Every `helm_install` call in `cmd_dev.ml` for a chart also installed by
  `platform/infra/base/main.tf` passes the same pinned `version`.
- Redpanda's `helm_install` call sets `auto_create_topics_enabled` to match
  `base/main.tf`.
- PostgreSQL's and Grafana's `helm_install` calls either match
  `base/main.tf`'s explicit values or carry an inline comment explaining the
  intentional difference.
- A fresh `sun dev down --cluster && sun dev up` installs the pinned chart
  versions (verified via `helm list -A` against the resulting cluster).
- Focused tests pass in `cli/sun`.
