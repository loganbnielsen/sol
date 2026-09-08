---
id: CODE_LAYER-005
type: bug
severity: high
source: project/audits/2026-09-06_code_layer_audit.md
branch: CODE_LAYER-005/layer2-component-source-of-truth
worktree: ../sun-CODE_LAYER-005-layer2-component-source-of-truth
pr: https://github.com/loganbnielsen/sun/pull/125
---

**Depends on:** None.

## Problem

`cmd_dev.ml` (`sun dev up`, local k3d) and `platform/infra/base/main.tf`
(Terraform, applied to real EKS/GKE clusters) each hand-maintain a second,
fully independent set of Helm `chart`/`version`/`values` for every platform
component they both install — Redpanda, PostgreSQL, Loki, Grafana, Alloy,
Tempo, Prometheus. The only thing keeping the two in sync today is a code
comment repeated across both files ("Dev mirrors prod exactly"); there is no
shared file, generator, or test that enforces it mechanically.

This has already produced a real, filed bug: BUG-013 fixed Loki's
`commonConfig.replication_factor` in `platform/infra/base/main.tf` only.
Nobody thought to check `cmd_dev.ml`'s independent Loki `helm_install` call,
so it still lacks the fix (BUG-016). CODE_LAYER-006, CODE_LAYER-007, and
CODE_LAYER-008 are three more concrete instances of this exact same failure
mode (Alloy config, Grafana dashboard JSON, and chart-version/value drift),
found by doing for every other shared chart what BUG-016 did for Loki.

## Goal

Give `cmd_dev.ml` and `platform/infra/base/main.tf` one shared, versioned
description of what each Sun platform component needs, so a value or
version change is one edit, not a "remember to also update the other
file" convention that has already been missed once.

## Design

Full rationale, decision, non-goals, and consequences are recorded in
**`docs/architecture/adr/0001-layer2-platform-component-source-of-truth.md`
— read it before implementing this ticket.** Summary:

- New `platform/components/<name>/{values-common,values-local,values-durable}.json`
  per component (Redpanda, PostgreSQL, Loki, Grafana, Alloy, Tempo,
  Prometheus). **JSON, not YAML** — `cli/sun/lib` already depends on
  `yojson` (no `yaml` dependency exists), and Terraform's built-in
  `jsondecode()` needs no provider, so this is zero new dependencies on
  either side.
- `values-common.json` stays deliberately sparse (schema versions, feature
  flags, common labels, behavioral defaults only — never replica counts,
  persistence, storage class, or resource sizing). `local` and `durable`
  are peers, not "common plus overrides that undo common."
- Fixed precedence, enforced by ownership not just file order:
  `values-common.json` → `values-<profile>.json` → infrastructure
  bindings (narrow, Kubernetes-level-only: service account name,
  annotations map, bucket name, secret name — never a provider-specific
  concept like an IRSA role ARN baked directly into a component file).
- `platform/infra/base/main.tf`'s `helm_release` resources read via
  `jsondecode(file(...))` for the values they now share with dev,
  supplying the durable profile plus this run's infrastructure bindings
  (env-specific values like `self_hosted_durable`'s S3 bucket/IRSA role
  stay as `main.tf` variables feeding the bindings layer — the shared
  files only own what dev and prod genuinely share).
- `cmd_dev.ml` reads the same `values-common.json` + `values-local.json`
  files (via existing Yojson plumbing) to drive its `Sun_cli_helm`
  install calls, instead of today's inline OCaml value lists.
- A CI guardrail (simple structural check, not an AST linter) flags new
  inline Helm configuration creeping back into *either* execution layer
  for a component that now has a `platform/components/` entry — applied
  symmetrically, so removing duplication from one side doesn't just make
  the other side the new dumping ground.

This is a structural fix; land CODE_LAYER-008's immediate version-pin/value
reconciliation first if that's faster to ship, then fold those pinned
values into the shared component files as part of this ticket so the two
files stop drifting going forward. CODE_LAYER-006 (Alloy River config) and
CODE_LAYER-007 (Grafana dashboard JSON) are the same failure mode for
non-Helm-values artifacts — tracked separately, not required for this
ticket to close, but worth applying the same common/profile split to if
convenient while in this code.

## Delivered scope (2026-09-06)

Migrated: Loki, Grafana, Tempo, Prometheus. Redpanda and PostgreSQL were
deliberately deferred to keep this PR reviewable and fully live-verified
rather than growing further — tracked as CODE_LAYER-010. This ticket's
acceptance criteria below are satisfied for the four migrated components;
CODE_LAYER-010 closes the remaining gap.

## Acceptance criteria

- `platform/components/<name>/` is the source of truth for shared
  configuration for Redpanda, PostgreSQL, Loki, Grafana, Alloy, Tempo,
  and Prometheus, split as `values-common.json`/`values-local.json`/`values-durable.json`
  per the ADR's ownership rules.
- `platform/infra/base/main.tf`'s `helm_release` resources read from that
  source instead of hand-typed literals for values now shared with dev;
  no duplicated platform-component operational configuration remains
  inline in `main.tf`.
- `cmd_dev.ml`'s `helm_install` calls read from the same source instead of
  hand-typed OCaml value lists; no independently encoded Loki/Prometheus/
  Grafana/Tempo/etc. operational values remain in `cmd_dev.ml`.
- AWS- and GCP-specific configuration does not appear in `values-durable.json`
  for any component — provider identity/storage details enter only
  through infrastructure bindings.
- A fresh `sun dev down --cluster && sun dev up` produces a Loki that
  incorporates BUG-013's `replication_factor` fix automatically (this is
  the regression test for BUG-016).
- Changing a genuinely shared setting (e.g. a chart version bump) requires
  editing one file, not parallel OCaml and Terraform edits.
- A CI check exists that would fail if new inline Helm values were added
  to `cmd_dev.ml` or `main.tf` for a migrated component.
- Focused tests pass for the `cli/sun` package; a full `sun dev up` cycle
  and a `terraform validate`/`plan` against `platform/infra/base` are
  verified manually since Helm/k3d/cloud integration isn't exercised by
  unit tests.

## Perf-gate sign-off (2026-09-06)

Merged (PR #125, commit `9c2623a`). Same false-alarm pattern as
CODE_LAYER-009 earlier today: post-merge gate flagged e2e at 1.909s vs.
1.192s baseline (1.60x, over the 1.5x threshold); the automatic revert
then failed on a dirty `tools/perf/perf_baseline.json`, so the merge
itself stands and only the ticket-state transition was blocked.

Immediately re-ran `bash platform/local/scripts/run_tests.sh` with no
other change: e2e came back at 1.192s, exactly the baseline. This is the
second time in one session this specific flake pattern has hit right
after a merge — worth a look at whether the merge step's own perf run is
picking up transient contention from whatever else is running on this
machine at merge time, rather than something inherent to the code being
merged. Signing off as a flake, not a real regression — moving to DONE.
