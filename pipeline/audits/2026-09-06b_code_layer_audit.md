# 2026-09-06 Code Layer Audit (b) — whole-codebase pass

Scope: the full `sun` monorepo (not just `platform/infra`/observability,
which the same-day `2026-09-06_code_layer_audit.md` and the `2026-09-05`
audit already covered). Traced `cli/sun/lib` + `cli/sun/bin` (largest,
least-audited surface — ~10k lines across 30 files), `framework/sun-svc`,
`framework/sun-worker`, `framework/sun-fn`, `framework/sun-obs`,
`integrations/kafka/kafka-eio-service`, and checked which standalone
`*-eio` packages (`aws-eio`, `dynamodb-eio`, `s3-eio`, `https-eio`,
`lambda-eio`, `pg-eio`) have real in-tree consumers today.

Method: read every framework primitive's public `.mli`, traced the
`Sun_cli_config` → `cmd_cloud_tf.ml` → `Sun_cli_terraform` call chain for
provider-formatting leaks, grepped for duplicate/thin-wrapper helpers
across `cli/sun/lib` and `tools/sundev/lib`, and checked package `dune`
files for actual cross-package dependency direction. This pass allows
breaking public API in `cli/sun` and the framework packages freely —
pre-alpha, no external consumers.

## Findings

### CODE_LAYER-012 — sun-svc/sun-worker/sun-fn never adopted the Sun_obs facade CODE_LAYER-003 built for them

Status: Open · Severity: Medium · Tag: `leak`

CODE_LAYER-003 (done, PR #115) added `framework/sun-obs`'s `Sun_obs.t` so
generated app code stops composing `Obs_eio`/`Obs_loki`/`Obs_prometheus`/
`Obs_tempo` by hand. It succeeded for application code, but the three
framework primitives it was meant to sit in front of never actually
adopted it — `sun_obs.mli`'s own doc comment says so explicitly:

> "These exist for `sun-svc`/`sun-worker`/`sun-fn`'s own `run` functions,
> which each still take a lower-level `Obs_eio.t`/renderer pair directly
> ... rather than a `Sun_obs.t` — not for application code."

Concretely:
- `Sun_svc.Make(H).run` takes `?ot:Obs_eio.t` + `?metrics_renderer`.
- `Sun_worker.Make(W).run` takes the same shape.
- `Sun_fn.Make(F).run` takes a *third*, different shape:
  `?backend:(Obs_eio.backend * (unit -> string))` + `?pushgateway_url` +
  `?job`.

`Sun_obs` has to carry three separate bridge accessors purely to adapt its
own `t` back down to what each primitive still expects
(`Sun_obs.obs_eio`, `Sun_obs.metrics_renderer`,
`Sun_obs.backend_and_renderer` — `framework/sun-obs/lib/sun_obs.mli`).
Scaffolded app entrypoints (`cli/sun/lib/sun_cli_scaffold_templates.ml`)
call `Sun_obs.of_env` and then thread these three bridges through to the
primitive's `run` call — the composition CODE_LAYER-003 set out to hide
is still visible at every scaffold call site, just one level removed.

No circular dependency blocks fixing this: `framework/sun-obs/lib/dune`
depends only on `eio`/`obs-*`; none of `sun_svc`/`sun_worker`/`sun_fn`
depend on `sun_obs`, and `sun_obs` depends on none of them. They can take
`sun_obs` as a library dependency safely.

Replacement: have `Make(H).run`/`Make(W).run`/`Make(F).run` accept
`?ot:Sun_obs.t` directly (one shape across all three primitives, not two),
extracting whatever raw `Obs_eio.t`/renderer/backend each needs internally
via the same accessors `Sun_obs` already exposes. Delete the bridge
functions from `Sun_obs`'s public API once nothing outside `sun_obs`
itself calls them, and simplify every scaffold template's observability
wiring to pass the one `Sun_obs.t` handle straight through.

### CODE_LAYER-013 — Terraform var-string formatting leaks into the neutral config model

Status: Open · Severity: Low · Tag: `move`

`Sun_cli_config.terraform_vars` (`cli/sun/lib/sun_cli_config.ml:669-690`)
builds literal Terraform CLI var syntax — `"region=" ^ v`,
`"create_rds=" ^ string_of_bool has_postgres`, etc. — directly inside
what is otherwise the neutral `sun.yml`/`sun.toml` parsing/model module
(`Sun_cli_config` has no other awareness of Terraform anywhere else in the
file). The actual Terraform adapter, `cli/sun/lib/sun_cli_terraform.ml`,
already owns the next layer of the same format one level up
(`var_args`: `"-var=" ^ v` / `"-var-file=" ^ f`, lines 12-15) — so the
`key=value` join for a var is split awkwardly across two files instead of
living entirely in the adapter that already does the rest of the
Terraform-specific formatting.

`cmd_cloud_tf.ml:238-273`'s `config_vars` is the only caller: it takes
`Sun_cli_config.terraform_vars cfg`'s `string list` and passes it straight
into `Sun_cli_terraform.plan/apply/plan_destroy/destroy ~vars` unchanged.

Replacement: change `Sun_cli_config.terraform_vars`'s return type to a
neutral `(string * string) list` (key/value pairs, no `"="` join). Move
the `k ^ "=" ^ v` join into `Sun_cli_terraform.var_args` alongside the
existing `"-var=" ^ v` prefixing, so all Terraform CLI syntax lives in one
file. `cmd_cloud_tf.ml`'s `config_vars` changes its return type
accordingly; no behavior change for `terraform plan`/`apply` themselves.

## Areas checked, no ticket filed

- **`integrations/kafka/kafka-eio-service/lib/`** — already cleanly split
  by concern (`kafka_service_config`/`_http`/`_intf`/`_retry_topics`/
  `_schema`), each with its own `.mli`. No finding.
- **`cmd_dev.ml`'s `dev_up` (289 lines, `cli/sun/bin/cmd_dev.ml:62-351`)**
  — long, but single-reason-to-change ("bring up local dev infra" — the
  Helm *values* per component were already unified with Terraform's by
  CODE_LAYER-005/006/007/008/010; what's left is CLI-only sequencing that
  has no Terraform analog to share with). Every other `cmd_*.ml` in this
  codebase (`cmd_up.ml`, `cmd_deploy.ml`, `cmd_cloud_tf.ml`) carries
  similarly substantial logic directly in `bin/`, not `lib/` — this is
  this codebase's established (if debatable) convention, not an outlier
  worth a targeted fix.
- **`aws-eio`, `s3-eio`, `dynamodb-eio`** — zero in-tree consumers in
  `sun` today (confirmed via `dune` file grep across the whole repo,
  consistent with `~/Code/CLAUDE.md`'s note that `aws-eio` was "extracted
  before any in-tree consumer existed"). No live layer boundary to audit
  yet; premature to file a finding against code nothing here calls.
  `https-eio`, `lambda-eio`, and `pg-eio` do have real consumers
  (`sun-svc`, `sun-fn`, and `examples/pluto`/`examples/venus`
  respectively) and were checked — no findings.
- **`examples/local-demo/bin/demo.ml`** (511 lines) — recently passed a
  dedicated `/demo-review` persona-based pass as part of FEAT-030
  (2026-09-05, see `docs/planning/WORK_SUMMARY.md`); not re-audited here.
- **Duplicate small helpers** (`read_file`, `mkdir_p`-style utilities
  across `cli/sun/lib` and `tools/sundev/lib`) — each has at most two
  tiny call sites and no shared package dependency would be justified by
  sharing them (per the skill's "share only after the second real use,
  and only if it wins a meaningful line deletion" rule). Left duplicated
  deliberately.

## Layer Sketch

Recommended shape once CODE_LAYER-012/013 land:

`scaffolded app -> Sun_obs.t -> framework primitive (Make(H/W/F).run, ?ot:Sun_obs.t) -> obs-eio neutral event -> provider adapter`

`sun.yml config -> Sun_cli_config.t (neutral) -> Sun_cli_terraform (all Terraform CLI formatting) -> terraform binary`
