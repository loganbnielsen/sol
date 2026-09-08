# 2026-09-06 Code Layer Audit — infra generation (local k3d vs. Terraform)

Scope:

- `cli/sun/lib/sun_cli_deployment_render.ml` / `.mli`
- `cli/sun/lib/sun_cli_manifest.ml` / `.mli`
- `cli/sun/lib/sun_cli_manifest_yaml.ml`
- `cli/sun/lib/sun_cli_dev_observability.ml`
- `cli/sun/lib/sun_cli_terraform.ml` / `.mli`
- `cli/sun/bin/cmd_up.ml`, `cmd_deploy.ml`, `cmd_dev.ml`, `cmd_cloud_tf.ml`
- `platform/infra/base/main.tf`, `platform/infra/aws/main.tf`, `platform/infra/gcp/main.tf`
- `platform/infra/base/alloy/logs.alloy.tftpl`, `platform/infra/base/dashboards/*.json`

Method: traced every Helm chart `cmd_dev.ml` (`sun dev up`) installs against the
matching `helm_release` in `platform/infra/base/main.tf`, diffed embedded
config content byte-for-byte where both sides hold a literal copy (Alloy River
config, Grafana dashboard JSON), and traced the two manifest-rendering call
chains (`sun up`/`sun deploy` → `Sun_cli_deployment_plan` →
`Sun_cli_deployment_render.render_spec` vs. the legacy `Sun_cli_manifest.render`)
to find dead orchestration code. This pass allows breaking public API in
`cli/sun` freely — pre-alpha, no external consumers.

## Findings

### CODE_LAYER-005 — No shared source of truth for any platform Helm chart between dev and prod

Status: Open · Severity: High · Tag: `duplicate`

`cmd_dev.ml` (`sun dev up`, k3d) and `platform/infra/base/main.tf` (Terraform,
real EKS/GKE) each hand-maintain a second, independent set of Helm
`chart`/`version`/`values` for every platform component they both install —
Redpanda, PostgreSQL, Loki, Grafana, Alloy, Tempo, Prometheus. The only thing
keeping them in sync is a code comment ("Dev mirrors prod exactly") repeated
across both files; there is no shared file, generator, or test enforcing it.

This is not hypothetical: BUG-013 fixed Loki's `commonConfig.replication_factor`
in `platform/infra/base/main.tf` only. Nobody thought to check `cmd_dev.ml`,
so its independent `helm_install "loki" ...` call still lacks the fix
(BUG-016, already filed, not re-filed here). CODE_LAYER-006 through -008 below
are three more concrete instances of the exact same failure mode, found by
diffing every other shared chart the way BUG-016 diffed Loki.

Replacement: give `cmd_dev.ml` and `platform/infra/base/main.tf` one shared,
versioned description of "what a Sun platform component is" (chart name,
pinned version, and the value overrides needed for the local/self-hosted
profile) that both consume, instead of two hand-typed copies. OCaml and HCL
can't share source directly, but they can share *data* — e.g. one YAML/JSON
file per chart under `platform/infra/base/charts/<name>.yaml` that
`main.tf` reads via `yamldecode(file(...))` and `cmd_dev.ml` reads via its
existing Yojson/toml plumbing — so a value or version change is one edit, not
a "remember to also update the other file" convention.

Locations:
- `/home/lbendtly/Code/sun/cli/sun/bin/cmd_dev.ml`
- `/home/lbendtly/Code/sun/platform/infra/base/main.tf`

### CODE_LAYER-006 — Alloy River log-shipping config hand-duplicated, no shared file

Status: Open · Severity: Medium · Tag: `duplicate`

`Sun_cli_dev_observability.alloy_config_river` (OCaml string literal) and
`platform/infra/base/alloy/logs.alloy.tftpl` (Terraform `templatefile`) both
hard-code the same River config — `discovery.kubernetes`, the taxonomy-label
`discovery.relabel` rules, `loki.source.kubernetes`, `loki.write`. The OCaml
file's own comment admits this: "keep this in sync by hand with the .tftpl if
either changes -- Terraform's HCL template language has no OCaml equivalent to
share the source with directly." Currently identical in effect (verified by
reading both), but nothing stops the next taxonomy-label change, endpoint
change, or Alloy version bump from landing in only one of the two.

Replacement: this file is real River config, not something that needs
Terraform's template interpolation for the local/no-auth case (`cmd_dev.ml`
never hits the `external`/basic-auth branch). Ship one static `logs.alloy`
file — e.g. under `platform/infra/base/alloy/` — that both `main.tf`
(`templatefile` for the two dynamic fields: push URL and optional basic auth)
and `cmd_dev.ml` (`Sun_cli_process`/file read, or embed the exact same file
content at build time) render from. At minimum, delete the OCaml copy and
have `cmd_dev.ml` read the `.tftpl` file directly, substituting only the
local values it needs (or expressing the local case as a `.tftpl` render with
empty basic-auth variables), rather than keeping a second full copy of the
config text.

Locations:
- `/home/lbendtly/Code/sun/cli/sun/lib/sun_cli_dev_observability.ml` (`alloy_config_river`, `alloy_values_yaml`)
- `/home/lbendtly/Code/sun/platform/infra/base/alloy/logs.alloy.tftpl`

### CODE_LAYER-007 — Grafana dashboard JSON duplicated byte-for-byte, no shared file

Status: Open · Severity: Low · Tag: `duplicate`

The four Grafana dashboards (`workspace-overview`, `domain-overview`,
`service-template`, `release-timeline`) exist as real files under
`platform/infra/base/dashboards/*.json`, loaded by `main.tf`'s
`kubernetes_config_map.grafana_dashboards` via `file(...)`. `cmd_dev.ml`'s
`install_local_grafana_config` instead applies dashboards from four OCaml
string literals in `Sun_cli_dev_observability.ml`
(`workspace_overview_json`, `domain_overview_json`, `service_template_json`,
`release_timeline_json`). A direct diff shows the content is currently
identical, but — unlike CODE_LAYER-006 — there is no comment anywhere
flagging that these two copies must be kept in sync, so the first dashboard
edit made in one place and not the other will silently diverge dev's Grafana
from prod's with no warning at all.

Replacement: delete the four OCaml string literals and have `cmd_dev.ml`
read `platform/infra/base/dashboards/*.json` directly — `cmd_cloud_tf.ml`
already resolves the Sun monorepo root via `Sun_cli_cmd_new.infer_sun_home`
for exactly this kind of "read a file that ships with the Sun checkout"
need; `cmd_dev.ml` can do the same instead of embedding a copy.

Locations:
- `/home/lbendtly/Code/sun/cli/sun/lib/sun_cli_dev_observability.ml` (four `*_json` bindings)
- `/home/lbendtly/Code/sun/platform/infra/base/dashboards/*.json`

### CODE_LAYER-008 — cmd_dev.ml pins no chart versions and drifts on individual values base/main.tf sets explicitly

Status: Open · Severity: High · Tag: `duplicate`

Every `helm_release` in `platform/infra/base/main.tf` pins an exact chart
`version` (redpanda 5.8.12, postgresql 15.5.1, loki 18.12.1, grafana 13.2.1,
alloy 1.12.1, tempo 2.3.0, prometheus 25.20.1). Every matching
`helm_install` call in `cmd_dev.ml` omits `version` entirely, so `helm repo
update` followed by `helm upgrade --install` resolves to whatever the chart
repo's latest release is at the moment `sun dev up` runs — a moving target
that `platform/infra/base/main.tf` explicitly refuses to be. This is the
mechanism that lets a chart's own default values (like Loki's
`replication_factor`, BUG-013/BUG-016) shift out from under dev without
warning, independent of any values drift.

Beyond versions, three concrete value-level diffs (found by the same
per-chart comparison BUG-016 did for Loki) currently sit unreconciled:

- Redpanda: `base/main.tf` sets `config.cluster.auto_create_topics_enabled =
  true` explicitly; `cmd_dev.ml`'s `helm_install "redpanda" ...` sets no
  such value.
- PostgreSQL: `base/main.tf` sets `primary.persistence.enabled` explicitly
  (`var.postgres_persistent_storage`); `cmd_dev.ml`'s `helm_install
  "postgresql" ...` leaves it at the bitnami chart's own default.
- Grafana: `base/main.tf` sets `adminPassword` explicitly
  (`var.grafana_admin_password`); `cmd_dev.ml`'s `helm_install "grafana" ...`
  leaves it at the chart's own default, so `sun dev up`'s Grafana admin
  credential is whatever the chart generates, not a documented value.

None of these three has caused a reported bug yet, but each is the same
"hand-maintained matching values, no shared source" shape CODE_LAYER-005
names generally.

Replacement: pin the same chart `version` string in `cmd_dev.ml`'s
`helm_install` calls that `base/main.tf` pins for each chart, and reconcile
the three value diffs above (either match `base/main.tf`'s explicit value or
document why dev intentionally differs). This can land ahead of
CODE_LAYER-005's larger shared-source-of-truth mechanism as an immediate
safety fix.

Locations:
- `/home/lbendtly/Code/sun/cli/sun/bin/cmd_dev.ml`
- `/home/lbendtly/Code/sun/platform/infra/base/main.tf`

### CODE_LAYER-009 — Legacy `Sun_cli_manifest_yaml.render` orchestration path is dead code kept alive only by its own parity test

Status: Open · Severity: Low · Tag: `yagni`

`sun up` and `sun deploy` both build a `Sun_cli_deployment_plan.service_spec`
and render it via `Sun_cli_deployment_render.render_spec` (called from
`Sun_cli_executor`). Separately, `Sun_cli_manifest_yaml.ml` (re-exported as
`Sun_cli_manifest.render` through `include Sun_cli_manifest_yaml`, and
exposed in `sun_cli_manifest.mli`) still carries its own full second
orchestration function — `render ?toml svc ~workspace ~ns ~name ~image` —
that duplicates `render_spec`'s primitive/progressive-delivery matching
almost line for line, driven directly off `Sun_cli_toml.t` instead of a
`service_spec`.

A repo-wide search shows exactly one caller of this function anywhere:
`test/test_manifest_render.ml:451`, in `test_svc_render_spec_matches_render`
— a test whose entire purpose is asserting that `render_spec` produces the
same YAML as this "legacy render path" (the test's own comment calls it
that). No CLI command, executor, or scaffold path calls
`Sun_cli_manifest.render` today. Per this repo's no-backwards-compatibility
policy, a superseded orchestration path should not be kept alive as public
API (and re-exported through a `.mli`) purely to backstop a parity test for
a migration that already finished.

Replacement: delete `Sun_cli_manifest_yaml.render` (and the now-inaccurate
`sun_cli_manifest.mli` comment claiming the low-level doc builders are
"used by render and render_spec" — only `render_spec`, via
`Sun_cli_deployment_render`, uses them going forward) along with
`test_svc_render_spec_matches_render`. If the intent behind the parity test
was to lock down `render_spec`'s output shape, replace it with direct
golden-output assertions on `render_spec` itself rather than a
self-referential comparison against dead code.

Locations:
- `/home/lbendtly/Code/sun/cli/sun/lib/sun_cli_manifest_yaml.ml` (`render`, lines ~569-637)
- `/home/lbendtly/Code/sun/cli/sun/lib/sun_cli_manifest.mli` (re-export + stale comment)
- `/home/lbendtly/Code/sun/cli/sun/test/test_manifest_render.ml` (`test_svc_render_spec_matches_render`)

## Residual / non-findings (checked, no issue)

- `sun_cli_manifest_yaml.ml`'s manifest rendering (`network_policy_doc`,
  `deployment_doc`, taxonomy labels, etc.) is fully provider-agnostic — it
  hard-codes Sun's own namespace conventions (`redpanda`, `postgresql`,
  `monitoring`, `ingress-nginx`), which are identical whether the target is
  `aws`, `gcp`, or local k3d. No aws/gcp-specific branching leaks into this
  layer; confirmed by reading the full file.
- `sun_cli_terraform.ml`/`.mli` is a clean, minimal subprocess-transport
  wrapper around the `terraform` binary (init/plan/apply/destroy/output),
  correctly kept below the provider-specific policy in `cmd_cloud_tf.ml`
  (e.g. AWS-only post-destroy EKS/RDS/ECR verification). No changes needed.
- `platform/infra/aws/main.tf` and `platform/infra/gcp/main.tf` provision
  only cluster/network/database infrastructure (VPC, EKS/GKE, RDS/Cloud SQL,
  IRSA) and hold no `helm_release` resources of their own — the two-stage
  split (provider module for the cluster, `platform/infra/base` for
  everything installed onto it) is clean and correctly documented as a
  manual two-step operator flow.
- `sun_cli_deployment_render.ml`/`.mli` is a small, well-scoped public
  surface (`render_spec`, one function) with a thorough `.mli` doc comment;
  no thin-wrapper or leak concerns.
- GCP's `cloud destroy --apply` has no post-destroy verification
  (`cmd_cloud_tf.ml` prints "(GCP destroy verification not implemented
  yet)") where AWS has EKS/RDS/ECR checks. This is an honestly-disclosed
  gap, not a boundary leak, and out of scope for this pass (it's a
  completeness gap, not a code-layer issue).

## Recommended architecture sketch

Today (the actual shape found):

```
sun dev up  ─┐                                    sun up / sun deploy
             │                                           │
             ▼                                           ▼
   cmd_dev.ml (OCaml,              Sun_cli_deployment_plan.service_spec
   hand-typed helm values,                              │
   no version pins)                                     ▼
             │                        Sun_cli_deployment_render.render_spec
             ▼                                (the one real render path)
     helm install (k3d)
                                    sun cloud apply
                                          │
                                          ▼
                          platform/infra/base/main.tf (Terraform,
                          hand-typed helm_release values, version-pinned)
                                          │
                                          ▼
                                helm_release (EKS/GKE)
```

Recommended shape — one chart-spec source, two thin renderers:

```
platform/infra/base/charts/<name>.yaml   (chart, pinned version, values —
       (shared data, not code)            the actual source of truth)
        │                     │
        ▼                     ▼
main.tf (yamldecode +   cmd_dev.ml (read + Sun_cli_helm.upgrade_install,
 env-specific overrides   same local-profile overrides main.tf's
 via variables)            "local" branch already expresses)
        │                     │
        ▼                     ▼
 helm_release (EKS/GKE)   helm install (k3d)
```

`sun up`/`sun deploy` manifest rendering is already on the right shape and
needs no structural change beyond deleting the dead legacy path
(CODE_LAYER-009):

```
app -> Sun_cli_deployment_plan.service_spec -> Sun_cli_deployment_render.render_spec
    -> Sun_cli_manifest_yaml doc builders -> kubectl apply / emit-to-dir
```
