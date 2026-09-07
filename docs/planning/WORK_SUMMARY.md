# Work Summary — Self-hosted refocus complete (2026-06-22)

## Latest: FEAT-032 — sun -> sol rename (2026-09-06)

Renamed the project from Sun to Sol across code, CLI, config conventions,
and build/release tooling, completing the docs-only rebrand started in
PR #136. The GitHub repo was renamed first (`loganbnielsen/sun` ->
`loganbnielsen/sol`); this ticket did the rest:

- Directories: `cli/sun` -> `cli/sol`, `framework/sun-{svc,worker,fn,obs,env}`
  -> `framework/sol-*`, `tools/sundev` -> `tools/soldev`,
  `tools/sun_process` -> `tools/sol_process`.
- OCaml modules: `Sun_cli_*` -> `Sol_cli_*`, `Sun_obs`/`Sun_env`/`Sun_process`
  -> `Sol_obs`/`Sol_env`/`Sol_process`, `Sundev_*` -> `Soldev_*`, the
  `Sun_hosted` deployment-mode variant -> `Sol_hosted`, plus every dune
  library name and consuming `(libraries ...)` stanza.
- Config/env conventions the CLI reads from disk: `sun.toml` -> `sol.toml`,
  `sun.yml` -> `sol.yml`, the `sun/<env>/<provider>/<region>.yml`
  target-file directory -> `sol/...`, `SUN_HOME`/`SUN_TARGET`/
  `SUN_LOKI_USERNAME`/`SUN_LOKI_PASSWORD`/`SUN_API_KEY(_FILE)`/
  `SUN_SKIP_HOOKS`/`SUN_SKIP_PERF_HOOK` -> `SOL_*`. Scaffold templates
  now emit the new names into every freshly generated workspace
  (including the generated CI workflow, `sol-ci.yml`), and both bundled
  example workspaces (`examples/pluto/`, `examples/venus/`) were updated
  to match for real, not just in docs.
- `.github/workflows/release.yml`: bundle/binary naming (`sol-vX.Y.Z-...`,
  `bin/sol`). `sun.opam` regenerated as `sol.opam` from `dune-project`'s
  renamed package.
- Prometheus alert names `SunHighErrorRate`/`SunPodRestartLoop` ->
  `SolHighErrorRate`/`SolPodRestartLoop` in
  `platform/infra/base/main.tf` and docs.
- Every living doc (README, TUTORIAL, ROADMAP, PRODUCT_ARCHITECTURE,
  devops-pipeline, escape-hatches, this repo's own `.claude/` context and
  skills) updated throughout. Dated/historical records — past tickets,
  `project/audits/`, `project/dogfood/`, `docs/audits/`, and the
  root-level `*-audit.md` investigation docs — were deliberately left
  saying "Sun", since they describe what was true at the time.
- `dune build` and the full test suite (unit + kafka + e2e) pass clean
  from a fresh `_build/`.

## Latest: CODE_LAYER-011 — perf gate stops crying wolf; automatic revert unblocked (2026-09-06)

Picked up from `project/tickets/IN_PROGRESS/CODE_LAYER-011.md`. The
post-merge perf gate (`platform/local/scripts/run_tests.sh`, invoked by
`sundev pipeline merge`) flagged an e2e-suite "regression" 4 times in one
session (CODE_LAYER-005/006/007/009); every time, an immediate manual
re-run at no other change came back within baseline noise, and none of
the underlying diffs touched anything on the e2e path. Root cause:
inconclusive but consistent with the ticket's contention theory (this
session ran concurrent background `dune build`/`dune test` agents) —
mitigated rather than chased further, since the fix is correct either way.
`run_tests.sh` now re-runs a suite once in place before flagging a
regression (the same recovery step a human was already doing by hand);
only a confirmed second breach fails the gate. Separately, every time the
gate fired, the automatic `git revert` step in `sundev pipeline merge`
itself failed ("local changes would be overwritten by merge" on
`tools/perf/perf_baseline.json`) because `run_tests.sh` always appends a
history entry to that file, even on a plain run — `sundev_merge.ml` now
discards that uncommitted entry before reverting, so a real regression's
revert completes in one step instead of requiring manual `git status`
archaeology.

An adversarial reviewer caught a real bug in the first pass: the
refactored per-suite runner restored `set -e` before returning, so
calling it as a bare `run_one "$suite"; exit_code=$?` under the script's
global `set -euo pipefail` silently aborted the whole script on any
suite's first failure/timeout instead of reaching the fail-handling code
below it — fixed by capturing the exit code through an `if`/`else`
(bash's standard errexit-safe pattern), then verified with a real repro
(a suite forced to fail on its first attempt) before a second fresh
reviewer confirmed no further issues.

## Latest: FEAT-031 — provisioned Grafana starter dashboard for the local demo (2026-09-06)

Follow-up to FEAT-030/BUG-008. `ensure-grafana.sh` only ever provisioned
Loki/Tempo datasources with no dashboards — anyone opening Grafana after
a demo run saw an empty Explore page unless they already knew LogQL, and
there was no path to metrics at all (`examples/local-demo`'s services are
short-lived, one-shot runs, not long-running `/metrics` scrape targets).
Wired the demo's existing but unused `PUSHGATEWAY_URL`/`Obs_prometheus.push`
path through to a real, provisioned "Sun Demo Overview" dashboard: request/
message counters, p50/p95 latency for both services (via
`histogram_quantile` directly on the pushed bucket snapshot — no `rate()`,
which returns `NaN` against a one-time batch-job push, not a continuously
scraped counter), a Tempo pointer panel, and a live logs panel. `ensure-
prometheus.sh` and `ensure-grafana.sh`'s Loki datasource now provision
fixed UIDs (`prometheus`, `loki`) instead of Grafana-assigned random ones,
matching Tempo's existing `tempo` UID, so the dashboard JSON can reference
them reliably across container recreations. `ensure-grafana.sh` also pins
`grafana/grafana:11.3.0` instead of `latest` (see BUG-008 — the previous
unpinned tag cost real debugging time chasing an unrelated auth regression
in whatever the newest release happened to be that day). Every panel query
verified individually against Grafana's own datasource proxy with live
demo data before landing.

## Latest: FEAT-030 — examples/local-demo dogfoods Sun_obs; fulfillment-worker gets real tracing (2026-09-05)

Picked up from `project/tickets/IN_PROGRESS/FEAT-030.md` (follow-up to
CODE_LAYER-003, requested after that ticket merged). `examples/local-demo`
predated `framework/sun-obs` and still hand-composed `Obs_eio`/`Obs_loki`/
`Obs_prometheus`/`Obs_tempo` directly; both `order-svc` and
`fulfillment-worker` now build their observability handle with one
`Sun_obs.of_env` call each, matching what generated scaffolds do. Each
keeps its own Prometheus registry (two real, separately-scraped
processes); the demo's own snapshot/assertions render and stitch both
together. `fulfillment-worker` gets a real `fulfill_order` Tempo span for
the first time, a child of `order-svc`'s `receive_order` span for the same
order (existing W3C trace-context propagation over Kafka) — Tempo tracing
is no longer `-svc`-only.

Reviewed with a new persona-based process (`/demo-review` skill, added
this session): a "demo agent" (does it actually run and show off the
platform) and a "client agent" (is the app-facing code proportionate, or
hiding boilerplate a library helper should absorb) each reviewed
independently, findings were fixed, both reconfirmed, then a fresh final
reviewer approved. The client-agent round surfaced a real gap in the
just-merged `Sun_obs` facade: it had no wrapper for
`Obs_eio.current_trace_context`, forcing app code to reach past the
facade for ordinary cross-service trace propagation — added
`Sun_obs.current_trace_context`/`Sun_obs.trace_id_string` to close it,
with new tests for parent/child trace-id inheritance and the hex format.

Also surfaced (not fixed here — pre-existing, unrelated to this diff, each
exhaustively investigated and ticketed): `BUG-008` (the local Docker Loki
container used by tests/demo rejects every write with a replication-factor
quorum error that persists even with a byte-for-byte upstream reference
config, across two Loki versions, and under both bridge and host Docker
networking — root cause not found, needs a non-sandboxed host or a
debugger) and `BUG-009` (Tempo silently drops most spans when two
independent `Sun_obs` handles push concurrently, reproduced twice). The
demo's Loki/Tempo assertions still run and fail honestly, annotated with
the ticket IDs, rather than being loosened or removed.

## Latest: CODE_LAYER-003 — new framework/sun-obs, Sun_obs.t facade (2026-09-05)

Picked up from `project/tickets/READY_FOR_ENGINEERING/CODE_LAYER-003.md`
(code-layer audit finding), via the `add-package` skill. Scaffolded app
entrypoints used to construct Loki/Prometheus/Tempo backends, compose them
with `Obs_eio.compose`, parse `LOKI_URL`/`TEMPO_URL` by hand, and pass
`?ot`/`?metrics_renderer` separately; app handlers called `Obs_eio.*`
directly. Added `framework/sun-obs/lib` (`sun_obs`, depends on `obs-eio`,
`obs-loki-eio`, `obs-prometheus-eio`, `obs-tempo-eio`): `Sun_obs.of_env`
owns reading those env vars and composing whichever backends are
configured (Prometheus always present); `log_debug`/`log_info`/`log_warn`/
`log_error`, `with_span`/`log`, `counter`/`gauge`/`histogram` (forwarding
straight to `Obs_eio.register_*` — no new metric DSL), and `with_context`
are the app-facing surface. Three bridge accessors (`obs_eio`,
`metrics_renderer`, `backend_and_renderer`) hand the framework primitives
exactly the shapes their existing `.mli`s already expect, so `sun-svc`/
`sun-worker`/`sun-fn` needed no signature changes.

Rewired all four scaffold templates that touched this (`ws_svc_bin_ml`,
`ws_worker_ml`+`ws_worker_bin_ml`, generic `worker_bin_ml`, generic
`fn_bin_ml`) to use `Sun_obs` instead of manual composition, and their
`dune` files to depend on `sun_obs` instead of the raw provider packages.
This is a net new capability for `-worker`/`-fn`, not just a refactor: the
generic worker/fn scaffolds previously had no way to pick up `LOKI_URL`/
`TEMPO_URL` at all (worker had Loki+Prometheus hardcoded manually, fn had
Prometheus only) — both now get all three backends automatically, the same
as `-svc`. Verified by actually running the built CLI's `sun new
workspace`/`sun new svc`/`sun new worker`/`sun new fn` and building every
generated scaffold (not just the source templates) — all compiled clean.
Updated one scaffold test's assertions (`cli/sun/test/test_scaffold.ml`'s
"startup helpers are flattened") to match the new expected generated
content (removed helpers no longer generated; asserts `Sun_obs.of_env` is
present, `Obs_loki.create` is not).

Found and ticketed (not fixed here — pre-existing, unrelated to this
diff): `BUG-007`, `sun new fn`'s generated `lib/dune` never depended on
`sun_fn`, so a bare `sun new fn` scaffold fails to build on its own; only
surfaced because verifying this ticket meant actually building a
standalone generic `fn` scaffold instead of just the bundled workspace one.

## Latest: CODE_LAYER-001 — aws-eio HTTP layer stops over-classifying responses (2026-09-05)

Picked up from `project/tickets/READY_FOR_ENGINEERING/CODE_LAYER-001.md`
(code-layer audit finding). `aws-eio`'s `Aws.Http.request`/`signed_request`
used to turn every non-2xx received HTTP response into `Error (Http_error
(status, body))`, forcing `s3-eio` and `dynamodb-eio` to carry a
`reclassify_transport_result` shim just to undo it. Both functions now
return `Ok (status, headers, body)` for any received response regardless
of status; `Error` means no usable response was ever received. Credential-
bootstrap call sites in `Aws_credentials` (STS/IMDSv2/ECS) now explicitly
classify non-2xx responses themselves, and the now-unconstructed
`Http_error` variant was removed from `Aws_error.t`. This repo has no
current consumer of `aws-eio`/`dynamodb-eio` (nothing under `framework/`
or `cli/` references them yet), so there is no sun-side code change beyond
this note — CI already tracks each package's `main` branch. Three PRs
opened against their respective repos, none merged yet:
[aws-eio#26](https://github.com/loganbnielsen/aws-eio/pull/26),
[s3-eio#19](https://github.com/loganbnielsen/s3-eio/pull/19),
[dynamodb-eio#16](https://github.com/loganbnielsen/dynamodb-eio/pull/16).

## Latest: CODE_LAYER-002 — dynamodb-eio gets an object representation layer (2026-09-05)

Picked up from `project/tickets/READY_FOR_ENGINEERING/CODE_LAYER-002.md`
(code-layer audit finding). `Dynamodb_table.Index` gave typed key/index
access, but reads still returned raw `Dynamodb_client.item`, and callers
had to remember to compose `Entity.stamp`/`Entity.check` by hand before
decoding a domain value. Added `Dynamodb_table.Object`, a functor that owns
caller-supplied `encode`/`decode` plus automatic entity-discriminator
stamping (on encode) and checking (before decode runs), with
`decode_option`/`decode_list`/`decode_page` helpers matching `Index`'s
result shapes. `Index` and `Entity` are unchanged; `Object` is built on
`Entity` as a higher-level default path. This repo has no current consumer
of `dynamodb-eio` yet, so there is no sun-side code change beyond this
note. PR (not merged yet):
[dynamodb-eio#17](https://github.com/loganbnielsen/dynamodb-eio/pull/17).

## Latest: FEAT-025/028 landed in parallel; picking up FEAT-026 (2026-09-03)

A parallel session implemented and merged `FEAT-025` (PR #96, "Harden target
file parser") and `FEAT-028` (PR #97, "Model target provider fields and
index keys") directly, outside the ticket pipeline — no ticket files were
moved. Verified the merged `sun_cli_config.ml`/`.mli` against both tickets'
acceptance criteria post-merge (quote-aware `strip_comment`, duplicate
rejection, `..`-traversal rejection, fail-loud unknown keys, the `index`
type, `target.provider_fields`, `resource.size`) — all present and correct.
Moved both tickets to `DONE` for bookkeeping accuracy. `FEAT-029` (also
unblocked, since it only depended on `FEAT-025`) is where that same
session said it would go next, so picking up `FEAT-026` instead to avoid
duplicate work — both `FEAT-026` and `BUG-004` were equally next per
`Depends on: FEAT-025`, and `FEAT-026` closes the higher-value gap (the
`env` label the observability design doc has been missing since OBS-008).

## OBS-031–035 merged, repo cleanup, Target Files ticketed (2026-09-03)

`OBS-031` through `OBS-035` (Loki read-auth, CLI observability messaging,
configurable Thanos/Loki retention, the GCP gate on `self_hosted_durable`,
and worker `/metrics`) all merged; ticket pipeline is fully drained
(`REVIEW`/`READY_TO_MERGE`/`IN_PROGRESS` empty). A follow-up commit
(`a4d4193`) added real e2e coverage for the worker `/metrics` endpoint and
`Sun_cli_loki.query` against a live local Loki — `examples/local-demo`'s
e2e suite now exercises both. Local observability (log levels, metrics,
Grafana Explore/dashboard links) verified working end-to-end against a live
local stack. AWS self-hosted durable remains unproven against a real
account — gated on `DOGFOOD-011` (blocked on an AWS account/cost decision),
and `alertmanager.enabled = false` plus the missing `env` label are known
gaps not covered by that dogfood ticket.

Repo hygiene: removed one stale fully-merged worktree
(`obs-durable-observability`) and 17 fully-merged local branches. Deleted
`docs/planning/POST_DOGFOOD_GAMEPLAN.md` — every ticket it named as
future/in-progress work (`FEAT-019`–`024`, `RELEASE-001`–`003`,
`ALPHA-001`–`002`, `HARDEN-001`, `CLOUD-004`/`005`) was already `DONE`, and
the hosted-control-plane work it described as upcoming (`CLOUD-004`/`005`)
had in fact already been built *and then deliberately removed* in the
self-hosted refocus — the doc was actively misleading despite its own
"historical" banner. `docs/planning/LIVE_DEV_DEPLOY_ROADMAP.md` is now the
only current plan; before today it had zero tickets filed against it.

First pass at "Project 3: Target Files" tickets wrongly assumed nothing
existed yet. Three rounds of fresh (no shared memory between rounds)
adversarial subagent review — each independently verifying claims against
the actual code before trusting them — converged on this state:

`Sun_cli_config` (`cli/sun/lib/sun_cli_config.ml`) already implements most
of Project 3 — `sun.yml` parsing, `target_of_path`/`target_file`,
`load_for_target` merge — consumed by `cmd_plan.ml`/`cmd_cloud_tf.ml`/
`sun_cli_observability_url.ml` already. What's actually missing is
correctness hardening and two genuinely new features, plus wiring `sun
deploy` (the one command not yet using it) and one unrelated dead-config
bug found along the way. Filed, chained via `Depends on`:

- `FEAT-025` — core parser hardening: `.mli`, fail-loud on duplicate
  names/unknown keys/malformed values, fixes for `#`-in-quotes truncation,
  `..` path traversal, stale-`root` phantom entries, and
  `load_for_target` discarding root `sun.yml`'s own `target:` defaults.
- `FEAT-028` (depends on `FEAT-025`) — new parsing: per-index DynamoDB
  `partition_key`/`sort_key` (currently silently dropped — proven by
  `test_config.ml`'s own `by_expires_at` fixture) and `aws:`/`gcp:`
  provider-boxed target fields.
- `FEAT-029` (depends on `FEAT-025`) — `uses` reference validation and
  absolute cross-region refs with the v1 cross-env/cross-provider
  rejection rules.
- `FEAT-026` (depends on `FEAT-025`) — wire `load_for_target` into `sun
  deploy`, emit the `env` label
  (`docs/architecture/observability-design.md`'s open gap), and fix the
  full blast radius of making target a required CLI positional: the real
  (non-comment) scaffold CI template, `test_scaffold.ml`'s substring
  assertions, `env_config`'s sharing with `sun up` (resolved as `env :
  string option`, not a forced default), and every doc showing a
  now-stale invocation example — via a repo-wide grep, not a hand-kept
  line list, since three rounds of review each found lines the previous
  pass missed.
- `BUG-004` (depends on `FEAT-025`) — replica scale is declared in both
  `sun.toml` (`replicas`, currently the live one) and `sun.yml`
  (`scale_min`/`scale_max`, currently dead — only a printout reads it). A
  fourth review round found the initial "migrate fully to `sun.yml`" plan
  wasn't actually implementable: `sun new workspace` doesn't scaffold a
  `sun.yml` at all (only `examples/pluto` has a hand-written one), and
  `sun up` never resolves one. Landed on a layered design instead —
  `sun.yml` scale overrides `sun.toml`'s `replicas` by service-name match
  only when a target resolved one; `sun.toml` stays the live default
  everywhere else, unremoved. That same round also caught two more
  `FEAT-025` gaps (a real fixture, `examples/pluto/sun/prod/aws/us-east-1.yml`,
  has an unknown `resources.app_db.size` key that item 3's new fail-loud
  rule would have broken — added `size` support; and the fail-loud rule
  needed to explicitly exempt the two shapes `FEAT-028` hasn't structured
  yet) and tightened `FEAT-026`'s grep instruction with `--exclude-dir`s
  for historical audit/dogfood/done-ticket directories (unfiltered: 274
  hits, ~47% historical noise). A fifth round confirmed all of the above
  landed correctly and found one more real gap: that grep's
  `--include=*.md --include=*.ml` missed two shipped, executed CI
  templates with no positional target,
  `platform/infra/ci/github-actions-{deploy,gitops}.yml` — added
  `--include=*.yml --include=*.yaml` and named both files explicitly.
  Also added a `FEAT-029` line for `LIVE_DEV_DEPLOY_ROADMAP.md` line 142
  (`sun plan` must print a resolved absolute ref as cross-region access,
  not silently the same as a local one).

Chose Target Files over `DOGFOOD-011`/Worker-Retry/Changed-Service-Build as
the entry point because "Project 2: Changed-Service Build and Deploy" has
nothing to resolve "changed" against without a target model — but per the
adversarial review, most of that model turned out to already exist, so the
real remaining work here is smaller than first scoped.

## Latest: deploy/runtime visibility decision — three-layer model (2026-09-01)

First live AWS smoke test (`tools/aws-live-smoke.sh` against real EKS) found a
real product gap, not just a test-tooling one: Loki only receives logs an app
explicitly pushes (`obs-loki-eio`), so a pod that never starts — Redpanda
OOMKilled on an undersized node, in this run's case — produces nothing in
Loki. The failure was only visible via an ad-hoc `kubectl logs` run outside
any logging pipeline. No code changed for this yet; recorded as a roadmap
decision (see `docs/planning/ROADMAP.md` §"Deploy & runtime visibility —
three-layer model") to unblock ticketing later:

- Deploy/build logs (terraform/helm/docker output) → local files under
  `.sun/runs/<run-id>/`, not Loki.
- Cluster/deployment diagnosis (why a pod never started) → `kubectl`
  events/pod state, powering `sun status`/`sun deploy status`. Does not
  depend on Loki — most reliable exactly when the app never runs.
- Runtime logs (app/worker output once running) → Loki, via promtail
  scraping pod stdout (not just app-pushed lines), with `sun logs` falling
  back to `kubectl logs` on a Loki query failure.

Explicitly rejected: hosted/managed logging infra run by Sun for users — that
commits to a different product shape (auth, billing, retention, abuse,
uptime) this stage doesn't need. Goal stays "make the user's own cluster
observable," not "Sun hosts the logs."

Separately, `tools/aws-live-smoke.sh` (new, this session) now wraps every
phase in `timeout $PHASE_TIMEOUT` (default 900s) and tails the last 40 log
lines to stdout on failure, and `platform/infra/aws/smoke-test.tfvars` bumped
to EKS 1.36 / two `t3.medium` nodes / `redpanda_memory=2Gi` — the smallest
shape that got past the scheduling and OOM failures found in this run.

## Latest: track every support package's `main` instead of stale tags (2026-08-29)

Local opam switch and both `.github/workflows/{ci,release}.yml` pin steps now track
`#main` for every one of the nine extracted support packages (`kafka-eio`, `aws-eio`,
`pg-eio`, `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`, `s3-eio`, `dynamodb-eio`,
`lambda-eio`), matching the `#main` convention `s3-eio`/`dynamodb-eio`/`lambda-eio`
already used since they have no tagged release. `kafka-eio`/`obs-eio`/
`obs-loki-eio`/`obs-prometheus-eio`/`pg-eio`/`aws-eio` previously pinned to fixed
version tags (`v0.2.0`/`v0.1.0`) that had fallen behind each repo's actual `main` —
deliberate for now, while all of these packages are under active parallel
development; revert to tagged pins once they settle. Accepted tradeoff: a sun
release build re-run later can pull different dependency code than what originally
shipped, until real tags come back.

Two real fixes were needed to build against kafka-eio's current `main` (2 commits
past `v0.2.0`, not yet re-tagged): `Kafka.Consumer.stream` was removed from the
public facade (PR #11, `kafka-eio`) — `kafka_service_retry_topics.ml`'s retry-topic
consumer loop switched from `Eio.Stream.take (Kafka.Consumer.stream ...)` to
`Kafka.Consumer.fetch`, the documented direct-style equivalent, treating
`Error Destroy` as a clean loop exit. `Kafka.Consumer.consume_partitioned` now
returns `(unit, 'e Kafka.Consumer.consume_error) result` instead of `(unit, 'e)
result` (PR #12) — both call sites in `kafka_service.ml`/`kafka_service_retry_topics.ml`
now unwrap `Handler_error e -> e` / `Invalid_config msg -> Kafka.Error.Config_error
msg` before returning, keeping `Kafka_service.consume_partitioned`'s own public
contract at `(unit, Kafka.Error.t) result` unchanged (`Invalid_config` is
unreachable in practice here — no caller passes a non-default `queue_capacity`).

Separately, the local opam switch had drifted from what CI/release actually pin:
`s3-eio` was pinned to a stray already-merged feature branch instead of `main`, and
`https-eio` was pinned via a plain local-dir pin (tracks the working tree, not a
commit) instead of a git ref. Both fixed as part of this pass.

`rm -rf _build && dune build @all` and `dune test framework/ integrations/ cli/`
pass clean against the re-pinned switch.

## Latest: adopt kafka-eio's public API cleanup (2026-08-28)

Upstream `kafka-eio` (`~/Code/kafka-eio`, PR #9, `codex/kafka-public-api-cleanup`)
collapsed its three sub-libraries (`kafka-eio-core`/`-producer`/`-consumer`) into a
single `lib/` and a single findlib library, `kafka-eio`. The public contract is now
the nested `Kafka.Producer`/`Kafka.Consumer`/`Kafka.Error`/`Kafka.Security` modules
declared in `lib/kafka.mli`; the flat `Kafka_producer`/`Kafka_consumer`/`Kafka_error`/
`Kafka_security`/`Kafka_raw` module names are `private_modules` and unreachable from
outside the package.

Updated in this repo to match: `framework/sun-worker/{lib,test}/dune` and
`integrations/kafka/kafka-eio-service/{lib,test}/dune` now depend on plain `kafka-eio`
(not `kafka-eio.core`/`.producer`/`.consumer`, which no longer exist). All call sites
in `framework/sun-worker/`, `integrations/kafka/kafka-eio-service/`,
`examples/local-demo/`, `examples/venus/`, and the kafka scaffold template in
`cli/sun/lib/sun_cli_scaffold_templates.ml` moved from the flat `Kafka_*` names to
`Kafka.*`. Re-pinned `kafka-eio` to the PR branch tip to verify before merge.

`dune build @all` and `dune test framework/` pass from a clean `_build`. The
`kafka-eio-service` integration test still needs a live broker
(`bash platform/local/scripts/ensure-broker.sh`) and was not exercised here.

## Latest: `aws-eio` extracted to a standalone opam package (2026-08-25)

Unlike every other extraction this repo has done (`kafka-eio`, `obs-eio` family,
`pg-eio`), this one happened with **zero in-tree consumers** — no `s3-eio`/`dynamo-eio`
exist yet, and nothing in `sun` calls `aws-eio` today. Extracted anyway, on explicit
request, to settle the package boundary before those backends start depending on it.
That tradeoff is real and stated plainly in the new repo's own README: the API shape
hasn't been proven by a real caller yet, the way `kafka-eio-core`/`obs-eio`'s shapes
were before they were pulled out.

`integrations/aws/` is gone from this repo (there was no Sun-specific policy layer to
keep in-tree, same as the `obs-eio` family). `dune-project`/`sun.opam` now depend on
`aws-eio`, pinned from `~/Code/aws-eio`, tagged `v0.1.0`, pushed to
`github.com/loganbnielsen/aws-eio`. `opam lint` passes; `dune build @install` and
`dune test` (47 cases) pass from a clean checkout in the new repo.

To change the extracted layer: edit in `~/Code/aws-eio`, commit there, then
`opam pin add aws-eio ~/Code/aws-eio -y` from this repo's switch to pick up changes.

`.github/workflows/release.yml`'s pin step now also pins `aws-eio#v0.1.0`.

**Still open, called out explicitly in the new repo's README:** no live AWS call has
ever been made from this package — everything is validated against AWS's published
SigV4 conformance suite and realistic sample payloads, not a real S3/DynamoDB/STS/IMDS
endpoint. Treat 0.1.0 as unproven against the real API until someone with actual AWS
access reports one working. `s3-eio`, `dynamo-eio`, and `lambda-eio` (see `aws-audit.md`,
repo root, updated to reflect this extraction) have not been started.

`dune build` and `dune test framework/ cli/` pass in `sun` after the cutover.

## Latest: `aws-eio` — SigV4 signing + credential resolution (Layer 1 of AWS support) (2026-08-25)

New in-tree package at `integrations/aws/aws-eio/` (not yet extracted — this is genuinely
new protocol work, not a migration of existing code, so it stays in-tree until `s3-eio`/
`dynamo-eio` exist alongside it, matching how `kafka-eio`/`obs-eio` were built out fully
before extraction). See `aws-audit.md` (repo root) for the pre-build design audit this
implements, and `integrations/aws/aws-eio/aws-eio.md` for the package spec.

**`Aws_sigv4`** (pure, no I/O) implements AWS Signature Version 4 request signing —
canonical request construction, string-to-sign, HMAC-SHA256 signing-key derivation, and
the final signature/Authorization header. Validated against AWS's own published SigV4
conformance suite (`awslabs/aws-c-auth`'s `tests/aws-signing-test-suite/v4`, mirrored
into `test/vectors/`, Apache-2.0, see `test/NOTICE-aws-c-auth`) — all 37 cases pass,
covering header duplication/ordering/trimming/obsolete-line-folding, path normalization
in both modes, UTF-8 query encoding, unreserved-character handling, and session-token
signing (both included in and excluded from the signature). Two corrections found
during implementation, both verified against the real test data before being trusted:

- The commonly-quoted "well-known" SigV4 tutorial secret key
  (`wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`) is wrong — the actual value has a `+`
  where memory suggested a `/` (`wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`, confirmed
  against `smithy-lang/smithy-rs`'s own SigV4 test as a second independent source).
  Caught by computing the reference `get-vanilla` signature independently in Python and
  `openssl` before writing any OCaml, and finding it didn't match.
- S3 is a documented exception to AWS's usual canonical-URI path normalization: object
  keys may contain literal `//` or `..`, so S3 requests must NOT dot-segment-remove or
  slash-collapse the path (still percent-encoded byte-for-byte). Modeled as a required
  `normalize_path : bool` field on `Aws_sigv4.request` — no default, every caller states
  which behavior their service needs. Verified against `aws-c-auth`'s paired
  `*-normalized`/`*-unnormalized` fixtures (this repo's copy of the test suite includes
  both; an earlier, since-replaced source for the vectors did not).

**`Aws_credentials`** resolves `(access_key_id, secret_access_key, session_token,
expiration)` from one of: static keys, EKS IRSA (`AssumeRoleWithWebIdentity` using a
Kubernetes-projected service-account JWT — the credential source a Sun service actually
uses in its real EKS deploy target, since `platform/infra/aws/main.tf` already
provisions EKS with IRSA for cert-manager), ECS/Fargate container credentials, IMDSv2,
or `Env_chain` (tries the above in that priority order). No implicit default source —
every `Aws_credentials.t` states one explicitly, matching `Kafka_security.t`'s "Security
on Day 1" posture. The credential-bootstrap HTTP calls (STS web-identity exchange, IMDS
token/metadata) are unsigned by design (signing them would need the credentials they
produce) and go through a separate `Aws_http.request` path, never `signed_request`.
Response parsing (a minimal, deliberately non-general XML leaf-tag extractor for STS's
XML response; JSON parsing for IMDS/ECS) is tested against realistic sample payloads —
network-backed sources can't be exercised against real AWS/IMDS endpoints from a unit
test in this environment.

**`Aws_http`** provides the shared HTTP transport: TLS via a private `Aws_tls` (same CA
-bundle-loading pattern as every other HTTPS caller in this repo — `kafka-eio-service`'s
`Kafka_service_tls`, `obs-loki-eio`'s `Obs_loki_tls`), and exponential backoff with full
jitter on 429/5xx (AWS's own documented retry strategy), on top of both an unsigned
`request` and a SigV4-`signed_request`.

Not built yet: `s3-eio`, `dynamo-eio` (including the `Table.Index`-per-GSI typed
modeling layer that's the actual point of that package — see `aws-audit.md`), and
`lambda-eio`. `digestif` added to `dune-project`'s depends (everything else `aws-eio`
uses was already a dependency via other packages).

`dune build` and `dune test integrations/aws/` (43 tests: 37 SigV4 + 6 credentials) pass.

**Follow-up hardening** (independent review pass on Layer 1, same session): an
independent reviewer caught a real signature-breaking bug in `signed_request` — it
built the actual wire URI via `Uri.make`/`Uri.to_string`, a *different* encoder than
`Aws_sigv4` signs with. RFC 3986 permits `! * ' ( ) : @ $ , +` unescaped in a query
value; SigV4's `UriEncode()` requires all of them percent-encoded. A signed request
containing any of those characters would be signed one way and sent another, and AWS
would reject the signature — every test in the package passed throughout because
nothing exercised those characters end-to-end, only internal consistency. Confirmed by
hand (`Uri.of_string "...%21..." |> Uri.to_string` comes back with `%21` un-escaped to
`!`) before fixing. `cohttp-eio`'s `Client` module turned out to have no way to
override the request line (`resource`) independent of a `Uri.t` — its low-level `Io`
module isn't part of that library's public interface — so `Aws_http` now builds and
sends the HTTP/1.1 request itself, constructing `Http.Request.t` directly with
`resource` set from `Aws_sigv4.canonical_uri`/`canonical_query_string` (the exact
functions used for signing, exposed as `wire_resource` and tested against the tricky
-character case that motivated this). Response parsing is hand-rolled too as a result:
`Content-Length`-delimited only, chunked `Transfer-Encoding` not handled (documented
gap, fine for v1's small-JSON/XML-response scope, not fine for streaming a large S3
GetObject later).

Also fixed, from the same review plus a second pass from another engineer looking at
the same code: `Random.float` for jitter used the global, unseeded `Random` module
(deterministic across fresh processes — same class of bug `Obs_trace`'s ID generator
had before its own fix); DynamoDB signals throttling via HTTP 400 with an
`x-amzn-errortype` header, not 429/5xx, and the retry classifier didn't check response
headers at all (`ThrottlingException`/`ProvisionedThroughputExceededException`/etc. now
recognized); IMDSv2 had no way to get the short, fail-fast timeout `aws-audit.md`
explicitly called for (SSRF-adjacent — now 1s, not the default 10s); and
`Aws_http.signed_request` computed the payload hash unconditionally, so
`aws-eio.md`'s documented `"UNSIGNED-PAYLOAD"` S3 streaming mode was unreachable
through the only I/O-capable entry point (`?payload_hash` override added). A retry
-against-a-real-throttling-response test (`test_aws_http.ml`, a local `Cohttp_eio`
mock server) was also added — `aws-audit.md`'s own checklist had called for this and
it was missing.

`dune test integrations/aws/` now runs 47 cases (37 SigV4 + 4 `aws_http` + 6
credentials); full repo build and `dune test framework/ cli/` still pass.

## Latest: sun-storage extracted to the standalone `pg-eio` opam package (2026-08-25)

Unlike `kafka-eio`/`obs-eio`, this extraction had no prior planning doc and no
`~/Code/pg-eio` repo already in progress — it started from a fresh audit
(`storage-audit.md`, repo root) written the same session, because `sun-storage` wraps
`caqti`/`caqti-eio`/`caqti-driver-postgresql` (already-published, independently
maintained packages) rather than containing Sun-authored FFI/protocol code the way
`kafka-eio-core` and `obs-eio` did. It turned out to have zero Sun framework coupling
already (no reference to `Sun_svc`/`Obs_eio`/`Kafka` anywhere in
`integrations/storage/sun-storage/lib/`), so extraction was straightforward once two
real bugs found during the audit were fixed in place first:

- `Migration`'s `?table` parameter built raw SQL via `Printf.sprintf` with no
  identifier validation, unlike `Table.Make`'s `table`/`id_column`/`columns` which
  already went through `Table.Identifier.of_string`. `Migration.apply`/`status`/
  `rollback` now validate `~table` the same way (`migration.ml`'s `validate_table`,
  reusing `Table.Identifier` rather than duplicating it) before it reaches any query.
  Not exploitable through Sun's own `sun migrate` CLI today (it derives `~table` from
  the workspace directory name), but the public `?table:string` parameter offered no
  protection to the next caller. Covered by a new test,
  `migration_pg.rejects_unsafe_table_name` — gated on `POSTGRES_URL` like every other
  integration test in this suite, so it wasn't runnable in this session's sandbox (no
  Docker/Postgres access) but will run in CI or any dev environment with Postgres up.
- `Db.transaction` discarded a rollback failure on the error path (`ignore
  (C.rollback ())`) — if rollback itself failed after the original error, the caller
  only ever saw the original error with no signal the transaction might not have
  actually rolled back. Now folds both into one `Storage_error.Query_error` when
  rollback fails; returns the original error unchanged when rollback succeeds. No
  dedicated test — forcing a genuine rollback failure needs fault injection (a killed
  connection mid-transaction) this test suite doesn't have infrastructure for yet.

`integrations/storage/` is gone from this repo. `dune-project`/`sun.opam` now depend
on `pg-eio` (opam-pinned from `~/Code/pg-eio`, tagged `v0.1.0`, pushed to
`github.com/loganbnielsen/pg-eio`). Every consumer (`examples/venus`, `examples/pluto`,
`examples/local-demo`, `cli/sun/bin`, the CLI scaffold templates, and
`sun_cli_workspace.ml`'s port-forward detection) was rewired from the `sun_storage`
findlib name to `pg-eio`. Module names are unchanged (`Storage_error`, `Db`,
`Migration`, `Table` — no `Obs`-style rename), though `README.md` in the new repo flags
`Db`/`Table` as generic enough to watch for collisions later; not renamed now since
nothing has actually collided. Verified by scaffolding a real workspace with `sun new
workspace` and running `dune build` against it (not just the tautological golden
tests) — compiles clean.

`platform/local/scripts/run_tests.sh`'s `storage` suite was removed entirely (same
treatment as the `observability` suite in the obs-eio cutover below) — there's no
storage-specific test surface left in this repo; Postgres-touching example code is
still covered by the `e2e` suite. `tools/perf/perf_baseline.json`'s `storage` entry
was removed to match. `.github/workflows/release.yml`'s pin step now also pins
`pg-eio#v0.1.0`.

`dune build` and `dune test framework/ cli/` pass after the cutover.

## Latest: obs-eio / obs-loki-eio / obs-prometheus-eio cut over to standalone opam packages (2026-08-25)

`integrations/observability/` (obs-eio core, obs-eio-loki, obs-eio-prometheus) is gone
from this repo. The three packages were already extracted to their own git repos —
`~/Code/obs-eio`, `~/Code/obs-loki-eio`, `~/Code/obs-prometheus-eio` — and released as
0.1.0 (tagged, opam-pinned), but this repo was still building the old in-tree copies
instead of consuming them. This entry is that cutover, same pattern as the kafka-eio
extraction below.

Package/library naming differs slightly from the original `obs-audit.md` /
`obs-extraction-plan.md` recommendation written before extraction: those docs said keep
the core module named plain `Obs` and never rename to `Obs_eio`. The standalone repo's
own post-extraction audit rounds (3–6) reversed that call — `Obs` was judged too generic
a name for a library other projects will `open`, so the core module is `Obs_eio` in the
released 0.1.0. `Obs_loki` / `Obs_prometheus` kept their original names (no rename risk
for those). Findlib/opam package names are `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`
— note `obs-loki-eio`/`obs-prometheus-eio`, not the in-tree `obs-eio-loki`/
`obs-eio-prometheus` naming used before extraction.

What changed in this repo:
- Deleted `integrations/observability/` entirely (no Sun-specific service layer sat on
  top of these three packages, unlike `kafka-eio-service`, so nothing stayed behind).
- `dune-project` now depends on `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`; `sun.opam`
  regenerated accordingly.
- Every consumer (`sun-svc`, `sun-worker`, `sun-fn`, `kafka-eio-service`, the CLI scaffold
  templates in `sun_cli_scaffold_templates.ml`, and the venus/pluto/local-demo examples)
  now references the opam packages by their public (hyphenated) findlib names in
  `(libraries ...)` stanzas, and all `Obs.` call sites became `Obs_eio.`.
- `sun_cli_workspace.ml`'s port-forward detection (`sun dev up` deciding whether to wire
  up Loki/Prometheus port-forwards for a scaffolded service) scans generated dune files
  for the library name substring — updated from `obs_eio_loki`/`obs_eio_prometheus` to
  `obs-loki-eio`/`obs-prometheus-eio` to match what scaffolded services actually emit now.
  This one is easy to silently break on a future rename: nothing else in the build would
  fail if it drifted, `sun dev up` would just quietly stop port-forwarding.
- `.github/workflows/release.yml` pinned `kafka-eio`/`obs-eio`/`obs-loki-eio`/
  `obs-prometheus-eio` via their GitHub remotes before `opam install . --deps-only` — this
  step didn't exist before for `kafka-eio` either, so the release workflow's dependency
  install was already broken pre-existing (a fresh CI runner has no local `~/Code` pins
  and these packages aren't in the public opam-repository). Fixed as part of this pass
  since it blocks verifying the cutover builds cleanly from scratch.
- `obs-audit.md` and `obs-extraction-plan.md` (repo root) are left as historical planning
  record, not rewritten — they documented the state and decisions accurately at the time.

To change the extracted layer: edit in the relevant `~/Code/obs-*` repo, commit there,
then `opam pin add <pkg> https://github.com/loganbnielsen/<pkg>.git -y` from this repo's
switch to pick up changes.

`dune build` and `dune test framework/ cli/` pass after the cutover.

## Latest: kafka-eio extracted to a standalone opam package (2026-08-24)

`kafka-eio-core`, `kafka-eio-producer`, `kafka-eio-consumer`, and the produce-then-consume
`demo/` binary moved out of this repo to their own git repository at `~/Code/kafka-eio`,
opam-pinned into this switch as package `kafka-eio` (findlib names `kafka-eio.core`,
`kafka-eio.producer`, `kafka-eio.consumer`). Pilot for splitting Sun's generic
Eio/librdkafka bindings from its opinionated application layer, so the binding can be
maintained (and eventually released) independently of Sun's own roadmap.

`kafka-eio-service` (typed message contracts, schema registry, Confluent wire framing,
Redpanda admin, retry topics/DLQ, `config_of_env`) stays in this repo — it's Sun-specific
policy, not generic Kafka bindings — and now depends on the external package instead of
in-tree libraries. `sun-worker` was rewired the same way.

To change the extracted layer: edit in `~/Code/kafka-eio`, commit there, then
`opam pin add kafka-eio ~/Code/kafka-eio -y` from this repo's switch to pick up changes.

`obs-eio` / `obs-loki-eio` / `obs-prometheus-eio` went through the same split — see the
entry above, dated 2026-08-25.

**Follow-up hardening in the extracted `kafka-eio-consumer`** (review pass on the
extraction, applied in the same session): `handler_result` is now polymorphic in the
application's own error type instead of forcing `Kafka_error.t`; `ack ()` returns
`(unit, Kafka_error.t) result` instead of silently discarding the commit outcome;
`consume`/`consume_partitioned` take an `?on_warning` callback instead of writing
directly to stderr with a hardcoded `"sun-worker:"` prefix; `consume_partitioned`'s
per-partition queues are bounded (`?queue_capacity`, default 16) with dispatch forked
per-message so a full queue on one partition can't stall routing to the others. This
rippled through every `ack` call site in this repo — `kafka-eio-service`, `sun-worker`
(including its own internal `WORKER` signature, which duplicates `worker.mli`), all
worker examples (`local-demo`, `pluto`, `venus`), and the `sun new worker` scaffold
templates in `cli/sun/lib/sun_cli_scaffold_templates.ml` — all updated to
`ignore (ack ())` (or, where warranted, to actually use the result) and to pin
`'e = Kafka_error.t` at Sun's own public API boundary, so no behavior changed for
Sun's existing users.

---

## Managed-hosting layer removed; self-hosted identity confirmed

Sun's product direction is confirmed: a self-hosted OCaml production platform.
Users always own their infrastructure. Sun never owns it on their behalf.

The managed-hosting layer (sun cloud deploy/releases/logs, control-plane registry,
in-memory registry vtables, Postgres-backed release history) was deleted on
2026-06-22. The README was rewritten to state the self-hosted identity clearly.
See commit `137328e` for the deletion diff.

All post-dogfood hardening tickets are complete:

| Ticket | State | Description |
|---|---|---|
| FEAT-020 | DONE | GitOps secret backend references |
| FEAT-021 | DONE | Deployment plan topics and migrations |
| FEAT-022 | DONE | Self-contained release artifact |
| FEAT-023 | DONE | `sun logs` Grafana pointer |
| ALPHA-001 | DONE | Release-user dogfood after FEAT-020..023 |
| ALPHA-002 | DONE | Public alpha docs/release readiness audit |
| FEAT-024 | DONE | Deployment plan v2 release-review contract |
| HARDEN-001 | DONE | Post-alpha security/reliability audit |

**Current open tickets:** DOCS-007 and DOCS-008 (docs cleanup from self-hosted refocus),
DOGFOOD-011 in BACKLOG (real AWS dogfood — blocked on AWS account).

---

## Previous: Post-dogfood gameplan and next tickets (2026-06-11)

Dogfood Alpha and the first release binary are complete. The planning focus
shifted to production hardening and the next larger feature tracks. See
`docs/planning/POST_DOGFOOD_GAMEPLAN.md`.

---

## Previous: Dogfood Alpha — all tickets done

All Dogfood Alpha tickets are complete. Sun proved the non-hosted product end-to-end.

**Tickets completed:** DOGFOOD-001 through DOGFOOD-006, DOGFOOD-008, DOGFOOD-009.
Full reports in `project/dogfood/`.

**What passed:** fresh install → workspace creation → local dev (`sun dev up`) → cluster
deploy (`sun up`) → migrations (`sun migrate`) → rollback (`sun rollback`) → ops loop
(secrets, logs, status) → customer-cloud contract (`sun deploy --emit-to`).

**Key fixes landed:**
- Kafka external advertised listener (DOGFOOD-008): worker pods now reachable from `sun dev run`
- Loki 2.x compatibility (DOGFOOD-009): `take_while` replaces `take 512` to avoid End_of_file on short HTTP bodies; Loki 2.x `[ts, line]` value tuple used instead of Loki 3.x 3-element tuple
- Docs reconciled (DOGFOOD-006): README + TUTORIAL updated with `sun logs` caveat, `sun secret set` restart caveat, GitOps secrets warning, correct PID file path

**Follow-up items (not blockers, captured in ROADMAP "Next" section):**

| Finding | Priority |
|---------|----------|
| GitOps YAML includes plain-text `stringData` secrets | High — fixed by FEAT-019 |
| Deployment plan JSON omits topics and pending migrations | Medium |
| DOGFOOD-007: publish release binary | Done |
| `sun logs` should point to Grafana LogQL URL for Loki | Low |
| `sun rollback` path format differs from `sun up` | Low |
| Fixed-tag pod restart on code change | Low |

---

## Previous: deployment lanes and Dogfood Alpha plan

The next product milestone was **Dogfood Alpha**, not deeper hosted work.

**Decision:** Prove Sun's non-hosted value first: install from release, create a
workspace, run locally, deploy to customer-owned infrastructure, and exercise
the operations loop. Hosted Sun remains the managed version of this workflow,
not a replacement for it.

**Deployment ownership lanes recorded in `docs/planning/ROADMAP.md`:**

| Lane | Summary |
|---|---|
| Local Dev | Developer machine; `sun dev up/run/up/status/logs` owns the local substrate loop. |
| Managed Customer Cloud | Customer cloud account; Sun owns the standard substrate shape and lifecycle. |
| Exported Self-Managed | Customer owns Terraform/manifests/apply/drift; Sun emits artifacts and can inspect. |

Sun Hosted (fourth lane, spiked in Phase 7) was removed on 2026-06-22 — see Latest section above.

---

# Previous — EXP-001 binary distribution complete; next hosted product wave queued

## Latest: EXP-001 — binary distribution via GitHub Releases (complete)

**What changed:**

- `.github/workflows/release.yml` — GitHub Actions release workflow: triggered on `v*` tags; builds `sun-linux-x86_64` on ubuntu-22.04 with OCaml 5.4.1 + librdkafka-dev; publishes binary to GitHub Releases via `softprops/action-gh-release@v2`.
- `README.md` — Quickstart install now shows the one-liner binary download (`curl … loganbnielsen/sun/releases/latest/download/sun-linux-x86_64`). Requirements section split into "Runtime (binary install)" and "Build from source (contributors)".
- `docs/guides/TUTORIAL.md` — Prerequisites now shows binary install first; build-from-source moved to a callout block; vendor-links note updated to reference `SUN_HOME` as the path for downloaded-binary users.

**Install path decision:** `~/.local/bin/sun` (no sudo required; matches existing conventions throughout repo).

**`SUN_HOME` note:** A downloaded binary cannot walk up to find framework templates. Users must set `SUN_HOME=/path/to/sun` before running `sun new workspace`. This is documented in both README and TUTORIAL.

**Ticket moves:**
- `EXP-001` → `DONE`
- `FEAT-017` → `READY_FOR_ENGINEERING` (all dependencies — DEC-005, FEAT-010, FEAT-016 — are DONE)
- `CLOUD-001`, `CLOUD-002`, `CLOUD-003` created in `BACKLOG`

## Next Up — hosted product wave

Priority order:

| Ticket | Description | State |
|---|---|---|
| FEAT-017 | Hosted default URLs and custom-domain flow | READY_FOR_ENGINEERING |
| CLOUD-001 | Project registry / control-plane stub | BACKLOG |
| CLOUD-002 | Hosted deploy API contract | BACKLOG (depends CLOUD-001) |
| CLOUD-003 | Release history and logs model | BACKLOG (depends CLOUD-002) |

Goal: after FEAT-017 + CLOUD-002, `sun cloud deploy` returns a real-looking release record with an openable Sun-managed URL.

---

# Previous — root layout cleanup in progress

## Latest: root layout cleanup

Reduced root-level clutter without changing core package boundaries.

**Moved:**
- Planning docs to `docs/planning/`.
- Product architecture and tutorial docs to `docs/architecture/` and `docs/guides/`.
- Audit checklists to `docs/audits/`.
- Deployment and hosted reference docs to `docs/deployment/` and `docs/hosted/`.
- Example workspaces/demos to `examples/`.

**Kept at root intentionally:**
- `README.md`, `dune-project`, `dune-workspace`.
- Core package groups: `cli/`, `integrations/kafka/`, `integrations/observability/`, `framework/`, `integrations/storage/`.
- Operational/project directories: `platform/local/`, `platform/infra/`, `project/tickets/`, `tools/perf/`, `project/audits/`.

---

# Previous — hosted release inspection

## Latest: FEAT-015 — hosted release inspection and diagnostics

Added a read-only release inspection model for hosted and customer-cloud release
visibility.

**Changed:**
- `Sun_cli_release_inspection` module with release summaries, affected services,
  rollout/health status fields, rendered manifest facts, diagnostic events, and
  diagnostics JSON serialization.
- `Sun_cli_hosted_executor.release` now embeds an inspection summary in the mock
  hosted release response.
- `docs/hosted/hosted-release-inspection.md` documents the default hosted release view,
  advanced diagnostics, customer-cloud manifest inspection, and non-goals.
- Tests cover release summary JSON, diagnostic manifest facts, secret-value
  absence, and hosted response inspection payloads.

**Verification so far:**
- `eval $(opam env) && dune test cli/sun/test`

---

# Previous — audit remediation + testing harness complete

## Latest: 2026-06-08 audit — all actionable findings resolved

All 5 numbered audit findings (AUDIT-010 through AUDIT-014) resolved. Four additional
unverified items investigated and fixed. Pre-commit hooks, performance baseline
tracking, and e2e assertions committed.

### AUDIT-010 — `sun_worker_decode_errors_total` Prometheus counter
`consume` and `consume_partitioned` now accept `?ot : Obs_eio.t option`. When provided,
a `sun_worker_decode_errors_total` counter is registered and incremented on every
`on_decode_error` call (bad wire format, JSON parse error, schema decode). `sun-worker`
forwards its `?ot` through to `consume_partitioned` automatically.

### AUDIT-011 — Worker template acks after business logic (committed earlier)
Both `ws_worker_ml` and `worker_lib_ml` scaffold templates now call `ack()` inside
the `Ok` branch of the DB insert, after all side effects succeed.

### AUDIT-012 — Retry path checks publish result before acking (committed earlier)
`publish_raw` now uses `Eio.Promise.await` on the producer result. On `Error`, it
logs to stderr and returns `Error e` without calling `ack()`, so the message is
not lost when the broker is unavailable.

### AUDIT-013 — HTTPS schema registry detected clearly (committed earlier)
`parse_base_url` now fails with a clear `failwith` message when an `https://` URL is
passed, avoiding a confusing DNS error. Test added for the rejection path.

### AUDIT-014 — `CAMLparam`/`CAMLreturn` in pause/resume partition stubs (committed earlier)
`ocaml_rd_kafka_pause_partition` and `ocaml_rd_kafka_resume_partition` now have full
`CAMLparam3` / `CAMLreturn(Val_unit)` discipline, consistent with all other stubs.

### Remaining unverified audit items investigated

**conf_of_config naked exceptions** — `kafka_consumer` and `kafka_producer` both had
`conf_of_config` calling `failwith` on `rd_kafka_conf_set` failure. Breaks the
`(t, Kafka_error.t) result` contract of `create`. Fixed: `conf_of_config` now returns
`(Kafka_raw.kafka_conf, string) result`; `create` logs the message to stderr and
returns `Error Kafka_error.Application`. Type annotation added to prevent OCaml
unifying the string error with `Kafka_error.t` (both `Result.Error` and
`handler_result.Error` constructors accept `Kafka_error.t` without annotation).

**Distributed tracing HTTP injection** — `Request.t` lacked a typed `trace_ctx` field.
Handlers had to manually extract `traceparent` from raw headers. Fixed: `Request.t`
now includes `trace_ctx : Obs_trace.t option`, populated by `service.ml` from the
incoming `Http.Header.t` via `Obs_trace.extract_from_headers`. Matches the UX of
worker handlers which already received `~trace_ctx`.

**Prometheus label cardinality** — Verified: route label is `route.Route.pattern`
(e.g. `/users/:id`), not the actual request path. Test added: two requests to
`/users/42` and `/users/999` confirm only `route="/users/:id"` appears in the
metrics output, never the concrete values.

**Migration tracking workspace isolation** — `sun migrate` already had `--table`.
Scaffold README and printed instructions updated to use `--table {{name}}_migrations`
so each workspace's version tracking is isolated from other workspaces sharing the
same postgres database.

### Testing harness (committed earlier in session)

- **Pre-commit hook** (`tools/perf/hooks/pre-commit`): blocks commits on build failure, unit
  test failure, or performance regression. Kafka tests gated on broker being up; e2e
  gated on broker + Loki + Postgres all running. Skip with `SUN_SKIP_HOOKS=1`.
- **Post-commit hook** (`tools/perf/hooks/post-commit`): shows perf table after commit.
- **Performance baselines** (`tools/perf/perf_baseline.json`): unit 0.2s, kafka 1.0s, e2e
  10.2s. Regression threshold 1.2×.
- **E2e assertions** (`examples/local-demo/bin/demo.ml`): HTTP 202 for all orders, Prometheus
  `sun_svc_requests_total > 0`, `sun_worker_messages_total > 0`, Loki query-back for
  service=order-svc, PostgreSQL row count ≥ orders sent.

### Remaining open audit items (not quick-fix)

- **Hermetic container portability**: Dockerfile copies host-built binary. Multi-stage
  OCaml builds via `ocaml/opam` image work but first-build time is 15–30 min and
  requires opam lockfile generation. Deferred to Phase 7 / infra hardening.
- **Zero-Knowledge Onboarding**: requires running `sun new workspace` end-to-end with
  k3d cluster provisioning; not verified in this session.
- **Hermetic test harnesses**: bash scripts with manual broker setup. Fixing requires
  Docker-in-CI or testcontainers support; deferred.
- **Atomic CLI transactions**: `sun up` applies workloads but doesn't roll back
  namespace on partial failure. Design-level issue; deferred.

---

## Previous: `Retry_topics` strategy + per-partition fiber retry + three code-review fixes

### `Kafka_service.retry_strategy` (new)

Two-mode union type added to `kafka_service.ml/mli`:

```ocaml
type retry_strategy =
  | In_memory    of Kafka_consumer.retry_policy  (* existing behavior, default *)
  | Retry_topics of { max_attempts : int }       (* new: Kafka-native retry *)
```

`consume_partitioned` now takes `?retry_strategy` (replacing `?retry`). Both
`Kafka_service` and `Worker.Make(W).run` surface this parameter.

**`Retry_topics` mechanics:**
- On handler `Error _`: raw bytes are published to `<topic>-retry` with
  `X-Sun-Attempt` and `X-Sun-Retry-At` headers; original offset committed
  immediately; main partition keeps flowing (returns `Continue`).
- Background retry consumer (`group_id ^ "-sun-retry"`) subscribes to
  `<topic>-retry`. Per message: reads `X-Sun-Retry-At`, calls
  `pause_partition`, sleeps until ready, calls `resume_partition`, then
  re-runs the handler.
- On re-failure: increments attempt and re-publishes to `<topic>-retry`
  (capped at 10 min backoff) or `<topic>-dlq` after `max_attempts`.
- Both topics auto-provisioned via AdminClient on startup.
- Retry consumer fiber runs in the caller's `sw`; Eio cancellation propagates
  naturally on shutdown — no explicit stop signal needed.

**Changed files (retry_strategy):**
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml[i]` — `retry_strategy` type, `default_retry_strategy`, modified `consume_partitioned`
- `framework/sun-worker/lib/worker.ml[i]` — `retry_strategy` type alias, `?retry_strategy` param in `Make.run`

**Three code-review fixes (stream capacity, stop race, `[@@noalloc]`):**
- `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml` — `Eio.Stream.create 64` → `max_int`; explicit `else ()` on interrupted retry
- `integrations/kafka/kafka-eio-core/lib/kafka_raw.ml` — `[@@noalloc]` on `pause_partition`/`resume_partition`
- `integrations/kafka/kafka-eio-core/lib/kafka_stubs.c` — dropped `CAMLprim`/`CAMLparam3`/`CAMLreturn` from pause/resume (required by `[@@noalloc]`)

**Test result:** 68 unit tests, all passing.

## Previous: Per-partition fiber consumer with retry + pause/resume

### `kafka_consumer.consume_partitioned` (new)

Routes messages to a per-partition `Eio.Stream.t`. One `Eio.Fiber.fork ~sw` per new partition. Each fiber runs the handler independently with exponential backoff retry. During retry sleep the partition is **paused at the librdkafka level** (`rd_kafka_pause_partitions`) so no messages accumulate in the partition stream — no memory buffer blowup and no head-of-line blocking in the routing loop.

**Key design points:**
- Routing loop uses `Eio.Fiber.first` to race `Stream.take t.stream` against a stop promise, so a `Stop` from any partition during a quiescent period doesn't block the routing loop forever.
- Sleeping partition fibers also use `Eio.Fiber.first` to race `Eio.Time.sleep clock delay` against the stop promise — so a `Stop` signal wakes them immediately; `resume_partition` is called before the fiber exits.
- Inner `Eio.Switch.run` inside `consume_partitioned` ensures all partition fibers join before the function returns, making it safe for the caller to immediately destroy the consumer handle.
- `worker.ml` no longer contains any retry logic. The handler returns `Kafka_consumer.Error Kafka_error.Application` for `W.handle` errors; `consume_partitioned` handles retry. The `_consume_loop` test-injection path bypasses partitioning (no sleep, no retry — tests remain fast).

**New C stubs:** `ocaml_rd_kafka_pause_partition`, `ocaml_rd_kafka_resume_partition` (local ops, no lock release needed).

**Changed files:**
- `integrations/kafka/kafka-eio-core/lib/kafka_stubs.c` — pause/resume stubs
- `integrations/kafka/kafka-eio-core/lib/kafka_raw.ml[i]` — `pause_partition`, `resume_partition` externals
- `integrations/kafka/kafka-eio-consumer/lib/kafka_consumer.ml[i]` — `retry_policy` type, `default_retry`, `consume_partitioned`
- `integrations/kafka/kafka-eio-service/lib/kafka_service.ml[i]` — `consume_partitioned` wrapper
- `framework/sun-worker/lib/worker.ml[i]` — simplified handler (no inline retry), calls `consume_partitioned`
- `framework/sun-worker/test/test_worker.ml` — updated `one_message`/`two_messages` for new `Error` semantic

**Test result:** 14/14 suites pass (121 tests). No hangs.

---

## What was done

### 1. `obs-eio` core library (complete, 18/18 tests)

New workspace at `integrations/observability/` with package `obs-eio`.

**Modules:**
- `Obs_trace` — W3C `traceparent` encode/decode, `generate`, `child_span`, `inject_to_headers`, `extract_from_headers`
- `Obs_metrics` — type aliases for `counter_fn`, `gauge_fn`, `histogram_fn` emitter closures
- `Obs` — main handle (`t`), `backend` record, `with_span`, `log`, `register_counter/gauge/histogram`, `with_context`, `noop`, `stdout`, `compose`

**Key design:** `Obs_eio.t` is immutable — `with_context` returns a new handle; safe to fork per-fiber. `span_event` carries `context : (string * string) list` so backends can use ambient fields as stream labels.

### 2. `obs-eio-loki` backend (complete, 8/8 tests)

New package at `integrations/observability/obs-eio-loki/`.

**API:**
```ocaml
val create
  :  net:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> url:string
  -> ?label_names:string list
  -> unit
  -> Obs_eio.backend
```

**What it does:**
- One logfmt log line per `Obs_eio.log` call: `level=info msg=... span=... key=val`
- `trace_id` and `span_id` in Loki 3.x **structured metadata** (third element of the value tuple) — indexed as filterable fields in Grafana, not buried in the log line text
- Stream labels: `service` always + whitelisted `label_names` from `Obs_eio.t` context (low-cardinality only)
- Spans with no `Obs_eio.log` calls emit a single `level=info span=... status=ok` completion line
- Unreachable Loki logs to stderr and returns normally — never raises

**Tests:**
- 6 mock-server tests verify payload structure without external infrastructure
- 2 live tests against real Loki: `log line ingested and queryable`, `trace_id indexed as structured metadata`
  (gated on `LOKI_URL` env var; run via full e2e matrix)

**Infrastructure added:**
- `platform/local/scripts/ensure-loki.sh` — starts `grafana/loki:3.0.0` via Docker
- `platform/local/scripts/ensure-grafana.sh` — starts Grafana, creates `sun-obs` Docker network, provisions Loki datasource
- Grafana UI at `http://localhost:3000/explore`; recommended query: `{service=~"..."} | logfmt`

### 3. Kafka Layer Hardening (complete, 26/26 tests)

All Kafka e2e tests green. See previous summary for details.

### 4. `obs-eio-prometheus` backend (complete, 10/10 tests)

New package at `integrations/observability/obs-eio-prometheus/`.

**API:**
```ocaml
val create : unit -> Obs_eio.backend * (unit -> string)
(* backend accumulates counter/gauge/histogram deltas;
   renderer produces Prometheus /metrics text on demand *)
```

**What it does:**
- Counter: accumulates `+= delta` per `(name, sorted_labels)` key, never resets
- Gauge: last-write-wins replacement per `(name, sorted_labels)` key
- Histogram: default buckets `[0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0]`;
  Prometheus cumulative semantics (increment all buckets where `le >= observation`)
- `emit_span` is a no-op — spans go to Loki
- `Mutex` (not `Eio.Mutex`) protects the registry — safe across Eio domains, no switch needed
- Renderer snapshots under the lock, then formats (does not hold lock while building the string)
- `# HELP` lines rendered — required adding `help: string` to `Obs_eio.metric_event` (additive, all existing tests still pass)

**Tests:**
- Counter accumulation across label sets, unlabeled counter
- Gauge last-write-wins, independent label sets
- Histogram correct bucket sorting, sum, count, labeled histogram lines
- Renderer: empty on zero events, `# HELP`/`# TYPE` lines, label value escaping
- Concurrent emit via `Eio.Fiber.all` — no lost updates under 100 fibers × 10 emits

**`push` implemented** — brought forward from Phase 2 for live verification.
Pushes Prometheus text body via HTTP PUT to `/metrics/job/<job>` on Pushgateway.
Same minimal TCP pattern as obs-eio-loki. Returns `(unit, string) result`; never raises.

### 5. `sun-svc` HTTP service layer (complete, 32/32 tests)

New package at `framework/sun-svc/`.

**Modules (wrapped library):**
- `Auth` — three-level auth: `` `Public ``, `` `Api_key `` (SUN_API_KEY / SUN_API_KEY_FILE), `` `Jwt of jwt_config `` (structure + exp + scope validated; `allow_unverified_v1_unsafe` guard for v1)
- `Response` — plain record `{ status; headers; body }` with typed constructors (`ok`, `json`, `created`, `bad_request`, `unauthorized`, etc.)
- `Request` — request record with `param_exn`, `query_param`, `header` helpers
- `Route` — `get`, `post`, `put`, `patch`, `delete` constructors; `match_path` with `:name` capture; trailing-slash distinction
- `Service` — `HANDLER` module type + `Make` functor; `run` with graceful shutdown, drain timeout, built-in `/healthz` and `/metrics` endpoints

**Key design decisions:**
- `cohttp-eio 6.2.1` as HTTP engine: `Server.run` takes listening socket, `?stop` promise for graceful shutdown
- Must add `Content-Length` header explicitly — cohttp-eio 6.x's `Body.String` read-method detection does not fire in practice (falls back to chunked)
- `Fiber.fork_daemon ~sw` in tests: `Eio.Net.run_server`'s io_uring accept doesn't respond to switch cancellation on WSL2; daemon fibers allow test switch to exit without waiting
- Graceful shutdown uses `Eio.Fiber.first serve drain_guard` — if connections drain before the timeout, the server exits immediately (no artificial delay); if drain_timeout_s elapses, `drain_guard` raises `Drain_timeout`, which is caught at the switch boundary with a log line
- Signal handling via self-pipe trick: `Unix.set_nonblock w` + `Unix.single_write` in the `Sys.Signal_handle` (async-signal-safe), `Eio_unix.await_readable r` in a forked fiber that resolves the stop promise from the Eio domain
- API key comparison uses constant-time XOR loop (`constant_time_equal`) to eliminate timing side-channels
- API key file reads are mtime-cached: `Atomic` ref holds `(mtime, key)`; fast path is `Unix.stat` + `Atomic.get` (no lock); `Mutex.protect` serialises the single writer on cache miss (double-checked locking); `In_channel.with_open_text` guarantees channel cleanup
- Double-slash paths (`/users//42`) rejected with 400 before routing via a zero-allocation tail-recursive `has_double_slash` using `String.unsafe_get`

**Tests (32 total):**
- `test_routing` — 10 tests: path matching, trailing slash, params, method mapping
- `test_auth` — 11 tests: Public, API key valid/wrong/missing, JWT valid/scopes/expired/malformed/unsafe-flag
- `test_service` — 11 tests: healthz, metrics, 404/405, public route, path params, POST body echo, JWT auth, handler exception resilience

### 6. `sun-fn` function primitive (complete, 7/7 tests)

New package at `framework/sun-fn/`.

**API:**
```ocaml
module type FN = sig
  val schedule : string                        (* cron expression *)
  val run : unit -> (unit, string) result
end

module Make (F : FN) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> ?pushgateway_url:string
    -> ?job:string
    -> ?backend:(Obs_eio.backend * (unit -> string))
    -> unit -> unit
end
```

**Lifecycle:** `Fiber.first` returns a typed outcome (`` `Completed result | `Signalled ``); metrics recording and push happen unconditionally OUTSIDE `Fiber.first` so they can never be cancelled mid-write.

**Signal handling:** Self-pipe (`fork_daemon ~sw`) — identical pattern to `sun-svc` but uses `fork_daemon` so the switch exits cleanly when `F.run ()` returns without any signal being received.

**Push safety:** `Obs_prometheus.push` has a 5s internal timeout; the outer `push_metrics` helper catches all exceptions and logs to stderr — push never blocks exit.

**`?backend` parameter:** Optional override for the default `Obs_prometheus.create ()` pair. Enables metric inspection in tests (without a real pushgateway) and fan-out to additional backends via `Obs_eio.compose`.

**Build structure change:** Removed `integrations/observability/dune-project` and `framework/dune-project`; created root `dune-project`. This merges both into the root project so cross-package library deps (`obs_eio`, `obs_prometheus_eio`) resolve correctly. `integrations/kafka/dune-project` is unchanged. All builds still work from subdirectories (dune finds workspace root via `dune-workspace`).

**Tests (7 total):**
- `run_ok` — `Ok ()` → returns normally
- `run_error` — `Error msg` → raises `Failure msg`
- `run_exception` — unhandled exception propagated
- `metrics_ok_counter` — renderer contains `sun_fn_invocations_total{status="ok"}`
- `metrics_error_counter` — renderer contains `status="error"`
- `metrics_duration` — renderer contains `sun_fn_duration_seconds`
- `push_error_no_raise` — connection-refused pushgateway → swallowed, returns in <5s

---

### 7. Phase 3 — Observability auto-wiring in `sun-svc` (complete, 13/13 tests)

Added `?ot:Obs_eio.t` parameter to `Service.Make(H).run`. When provided:
- Registers `sun_svc_requests_total{method, route, status_class}` counter and `sun_svc_request_duration_seconds{method, route}` histogram at startup (once, not per request)
- Per request: captures matched route pattern via `?route_observer` hook into `dispatch` (zero extra route-lookup cost), then emits counter + histogram after response is built
- Route label uses the declared pattern (`/users/:id`), not the actual path — no cardinality explosion

**Usage:**
```ocaml
let backend, render = Obs_prometheus.create () in
let ot = Obs_eio.create ~service:"payments-svc" ~mono_clock:env#mono_clock ~backend in
Service.Make(H).run ~env ~ot ~metrics_renderer:render ()
```

`-fn` already had `sun_fn_invocations_total` + `sun_fn_duration_seconds` from Phase 2. No additional changes needed.

**What's deferred:** `-worker` (no primitive yet), Grafana dashboards, k8s manifests (Phase 6), `Sun.Log`/`Sun.Metrics` wrappers (Phase 5).

### 8. `sun-worker` worker primitive (complete, 7/7 tests)

New package at `framework/sun-worker/`.

**API:**
```ocaml
module type WORKER = sig
  module Message : Kafka_service.MESSAGE
  val group_id : string
  val handle : Message.t -> ack:(unit -> unit) -> (unit, string) result
end

module Make (W : WORKER) : sig
  val run
    :  env:< net : _ Eio.Net.t; clock : _ Eio.Time.clock;
             mono_clock : _ Eio.Time.Mono.t; .. >
    -> config:Kafka_service.config
    -> ?ot:Obs_eio.t
    -> unit -> unit
end
```

**Lifecycle:** `create` → `register` → `consume` inside a switch. Signal handler sets an `Atomic.t` stop flag; handler checks it per message for graceful drain. Handler error (`Error msg`) captured via ref → raises `Failure` after consume exits cleanly via `Stop`.

**Signal handling:** Same self-pipe pattern as `-svc` and `-fn`. Uses `Atomic.t` rather than a promise because the stop is checked at message boundaries (not mid-message cancellation).

**Metrics (when `?ot` provided):**
- `sun_worker_messages_total{status}` — counter (`ok` or `error`)
- `sun_worker_message_duration_seconds` — histogram (per-message latency)

**Test injection:** `?_consume_loop` parameter bypasses the real Kafka stack and drives the wrapped handler with synthetic messages — same pattern as `?backend` in `sun-fn`.

**Build change:** Deleted `integrations/kafka/dune-project` to merge the kafka sub-project into the root project. `sun-worker` can now depend on both `kafka_eio_service` and `obs_eio` without cross-workspace issues. All 111 tests still pass.

**Tests (7 total):**
- `handle_ok` — Ok () handler → returns normally
- `handle_error_raises` — Error handler → raises Failure
- `no_ot_no_crash` — runs without ?ot, no crash
- `two_messages_both_processed` — two messages, both processed
- `metrics_ok_counter` — renderer contains `sun_worker_messages_total{status="ok"}`
- `metrics_error_counter` — renderer contains `status="error"`
- `metrics_duration` — renderer contains `sun_worker_message_duration_seconds`

---

### 9. E2E demo + Friction Log (complete)

New `examples/local-demo/` at repo root. Full stack in one binary: HTTP → svc → Kafka → worker.

**Shows:**
- `correlation_id` from HTTP `X-Correlation-Id` → Kafka event payload → worker log spans
- Auto-wired metrics: `sun_svc_requests_total`, `sun_svc_request_duration_seconds`, `sun_worker_messages_total`, `sun_worker_message_duration_seconds`  
- Prometheus text output; optional Loki (LOKI_URL) and Pushgateway (PUSHGATEWAY_URL)

**Run:** `KAFKA_BROKERS=localhost:9092 dune exec examples/local-demo/bin/demo.exe`

**Also:** `http/` folder renamed to `framework/`. See `examples/local-demo/FRICTION_LOG.md` for 7 friction items to reduce developer barrier to entry.

---

### 10. Friction log — Batch 1 (complete)

Three quick-win improvements from the demo friction log:

**`Worker.Make.run ?on_ready`** (`framework/sun-worker/lib/worker.ml/.mli`)
- Added `?on_ready:(unit -> unit)` parameter; threads directly to `Kafka_service.consume`.
- Demo updated to use real path — `~_consume_loop` friction hack removed.

**`Obs_eio.log_t`** (`integrations/observability/obs-eio/lib/obs.ml/.mli`)
- `val log_t : t -> level -> ?fields:(string * string) list -> string -> unit`
- Addresses friction items #4 and #7. Logs without an explicit span; creates an anonymous `"log"` span internally.

**`Kafka_service.config_of_env`** (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml/.mli`)
- `val config_of_env : unit -> config`
- Reads `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL` with sensible localhost defaults (`linger_ms=50`, `partitions=1`).
- Demo updated to use `{ (Kafka_service.config_of_env ()) with linger_ms = 5 }`.

All 111 unit tests pass. Full e2e demo runs clean (no hangs).

### 10b. Critical hang fix — `Eio.Cancel.protect` + stream-drain deadlock (complete)

Two shutdown bugs fixed, found while running e2e tests with long-running topics:

**Bug 1 — `Eio.Cancel.protect` missing** (`kafka_consumer.ml`, `kafka_producer.ml`):
Without `Eio.Cancel.protect` in `close`, an outer switch ending while `close` is waiting at `Eio.Promise.await t.poll_exited` (a yield point) raises `Eio.Cancel.Cancelled`, skipping `consumer_close`/`flush`/`destroy`. Librdkafka background threads leak, hold the consumer group open, and block any new consumer joining the same group in a rebalance that never completes. Fixed by wrapping the entire shutdown sequence in `Eio.Cancel.protect`.

**Bug 2 — stream-full deadlock** (`kafka_consumer.ml`):
When `close` is called explicitly (not from `on_release`) and the 256-message stream is full, the poll fiber is blocked in `Eio.Stream.add`. `close` waits for `poll_exited`, but the poll fiber can never see `t.closed = true` to exit. Fixed by draining the stream inside `close` before awaiting `poll_exited`:
```ocaml
let rec drain_until_exited () =
  while not (Eio.Stream.is_empty t.stream) do
    ignore (Eio.Stream.take_nonblocking t.stream)
  done;
  if Eio.Promise.peek t.poll_exited = None then begin
    Eio.Fiber.yield ();
    drain_until_exited ()
  end
in
drain_until_exited ();
```

**Results:** All 26 Kafka tests pass in <1.5s total (was hanging indefinitely). Demo runs to completion with clean process exit — no stale librdkafka threads.

### 11. Friction log — Batch 3: traceparent over Kafka headers (complete)

W3C `traceparent` automatically propagated from HTTP span → Kafka message header → worker span, creating a full distributed trace across the svc→kafka→worker boundary.

**Changes (9 layers):**
- `kafka_stubs.c` — `consumer_poll` extended to 7-tuple (adds `headers:(string*string) list`); new `produce_v` stub using `rd_kafka_producev` for header-bearing produces
- `kafka_raw.ml/.mli` — updated externals for 7-tuple poll and `produce_v` with bytecode trampoline
- `kafka_consumer.ml/.mli` — `message` type gains `headers` field; `tuple_to_message` updated
- `kafka_producer.ml/.mli` — `produce`/`produce_await` gain `?headers:(string*string) list`; routes through `produce_v` when non-empty
- `kafka_service.ml/.mli` — `publish` gains `?trace_ctx:Obs_trace.t`; `consume`'s handler type gains `~trace_ctx:Obs_trace.t option`
- `framework/sun-worker/lib/worker.ml/.mli` — `WORKER.handle` gains `~trace_ctx:Obs_trace.t option`
- All tests updated for the new handler signatures
- `examples/local-demo/bin/demo.ml` — extracts `trace_ctx` from HTTP span via `Obs_eio.current_trace_ctx`, passes to `publish`; worker uses `?parent:trace_ctx` to link the fulfillment span

**Trace continuity:** HTTP span → `traceparent` header in Kafka message → extracted in `kafka_service.consume` → passed to `WORKER.handle` as `~trace_ctx` → `?parent:trace_ctx` in `Obs_eio.with_span` → linked child span in Loki/Grafana.

### 12. Demo friction log — all items closed (complete)

All 7 friction items from `examples/local-demo/FRICTION_LOG.md` are resolved:

| # | Item | Resolution |
|---|------|------------|
| 1 | `Worker.Make.run ~on_ready` | `?on_ready:(unit -> unit)` threaded to `Kafka_service.consume` |
| 2 | Worker clean stop mechanism | `?stop:bool Atomic.t` + `?max_messages:int`; 2 dedicated test cases |
| 3 | `(wrapped)` inconsistency | All three primitives now `(wrapped false)` |
| 4 | Logging boilerplate | `Obs_eio.log_t : t -> level -> ?fields -> string -> unit` |
| 5 | Correlation ID manual end-to-end | W3C `traceparent` over Kafka headers (Batch 3) |
| 6 | Two Kafka credentials | `Kafka_service.config_of_env ()` |
| 7 | `Obs_eio.log` requires span | Same fix as #4 |

### 13. Error handling and test-speed hardening (complete)

Two targeted cleanups:

**Narrowed broad exception catches** (`integrations/kafka/kafka-eio-service/lib/kafka_service.ml`):
- `with _ ->` catches in schema registry JSON parsing narrowed to `Yojson.Json_error _`
- Previously swallowed `Out_of_memory`, `Stack_overflow`, and other fatal exceptions silently

**Loki live test sleep reduced** (`integrations/observability/obs-eio-loki/test/test_loki.ml`):
- `Eio.Time.sleep 2.0` → `0.5` in both live round-trip tests
- Justified: `emit_span` pushes synchronously (HTTP POST completes before `with_span` returns); Loki query latency after ingestion is <100ms in practice
- Full e2e suite: **1.64s** (was 4.15s), all 84 tests green

### 14. Phase 4 — Storage (PostgreSQL) (complete, 8/8 tests)

New package at `integrations/storage/sun-storage/`.

**Modules:**
- `Storage_error` — typed error ADT: `Connection_failed`, `Query_error`, `Not_found`, `Constraint_violation`, `Migration_error`
- `Db` — connection pool (`create_pool`), `exec`, `find`, `collect`, `transaction`; polymorphic record field trick hides caqti's type variable; `App_error` exception bridges `Pool.use` callback type boundary
- `Migration` — migration runner: `apply pool ~dir` applies pending `NNNN_description.sql` files in order; idempotent; tracks applied versions in `sun_schema_migrations`; `status pool ~dir` returns per-migration status
- `Table.Make(SCHEMA)` — functor producing `find`, `insert`, `delete`, `list` from a schema description; SQL generated at functor instantiation time

**Key design decisions:**
- No storage abstraction layer — PostgreSQL is the answer, not a pluggable option
- `caqti` + `caqti-driver-postgresql` + `caqti-eio.unix` (C-binding driver requires `.unix` sub-library, not plain `caqti-eio`)
- `Caqti_eio.stdenv` coerced from full env with `:>` — requires `< net; clock; mono_clock >`
- `Pool.use` callback must return caqti error type; `App_error` exception trick enables `Storage_error.t` across that boundary without losing type safety
- `transaction` builds a `tx_pool = { use_conn = fun g -> g conn }` — routes all queries to the same connection
- Migration files: `NNNN_description.sql`; `sun_schema_migrations (version INT PK, name TEXT, applied_at TIMESTAMPTZ)`
- All integration tests gated on `POSTGRES_URL` env var; 2 pure unit tests run without database

**Tests (8 total):**
- Unit: `error_to_string`, `migration_parse_filename` (no database)
- Integration: `pool_create`, `exec_find_collect`, `transaction_commit`, `transaction_rollback`, `migration_apply` (idempotent), `table_make` (full CRUD via `Caqti_type.custom`)

**Infrastructure:** `platform/local/scripts/ensure-postgres.sh` — starts `postgres:16-alpine`, waits for `pg_isready`, prints `export POSTGRES_URL=...`

**Build:** `dune build integrations/storage/` clean first try. 8/8 tests pass in 217ms.

### 15. Venus reference workspace (complete)

New `examples/venus/` workspace that uses Sun rather than defines it — a realistic two-team example.

**Architecture:**
```
payments / charge-svc  →  Kafka (venus-payments-charges)  →  comms / notify-worker  →  PostgreSQL
```

**Structure:**
```
examples/venus/
  events/payments/charged.ml         ← Charged event contract (payments team owns, comms team imports)
  app/comms/notify_worker/lib/
    notification.ml                  ← Table.Make(Schema) for notifications table
    notify_worker.ml                 ← Worker.WORKER impl via Make(Config) functor
  db/migrations/0001_notifications.sql
  bin/run.ml                         ← orchestration runner (replaces examples/local-demo/)
```

**Key patterns demonstrated:**
- Two autonomous teams collaborating through a typed Kafka event contract
- `Notify_worker.Make(Config)` functor: injects `pool` and `ot` without module-level mutable state
- `~table:"venus_schema_migrations"` in `Migration.apply` — per-workspace migration table avoids cross-contamination when multiple workspaces share a dev database
- `Notification.Schema.t` + `include Table.Make(Schema)` pattern for storage modules
- `Obs_eio.with_context` wires `team` label into Loki stream labels per service

**Bug fixed during implementation:**
- `Migration.apply`/`status` now accept `?table:string` (default `"sun_schema_migrations"`)  
- Storage test updated to use a random per-run table name for isolation
- Root cause: demo's migration ran first and recorded version 1 in `sun_schema_migrations`, causing venus's `0001_notifications.sql` to be silently skipped

**Run:** `KAFKA_BROKERS=... POSTGRES_URL=... LOKI_URL=... dune exec examples/venus/bin/run.exe`

## In Progress

### 16. Phase 5 — CLI skeleton and scaffold commands (in progress)

**Package:** `cli/sun/`  
**Binary:** `_build/default/cli/sun/bin/main.exe` (install as `sun`)

**`Sun_cli` library (`cli/sun/lib/`):**
- `Sun_cli_scaffold` — `subst`, `write_file`, `normalize`, `capitalize_name`; template substitution using `{{key}}` placeholders; directory creation via `Sys.command "mkdir -p"`
- `Sun_cli_workspace` — workspace scanner: walks `dune` files under a directory and returns `infra_requirements { kafka; postgres; loki; prometheus }` for use by `sun dev up`

**Full CLI surface wired via `cmdliner` 2.x:**

| Command | Status |
|---------|--------|
| `sun new workspace <name>` | ✓ fully implemented |
| `sun new svc <domain>/<name>` | ✓ fully implemented |
| `sun new worker <domain>/<name>` | ✓ fully implemented |
| `sun new fn <domain>/<name>` | ✓ fully implemented |
| `sun new event <team>/<name>` | ✓ fully implemented |
| `sun dev up/down/status` | stub — Phase 5 step 2 |
| `sun up [path] [--dry-run] [--tag]` | stub — Phase 5 step 3 |
| `sun status [domain]` | stub — Phase 5 step 4 |
| `sun migrate [status\|rollback]` | stub — Phase 5 step 7 |

**Scaffold contract (verified with `dune build`):**
- `sun new workspace acme` → 15 files; `dune build acme/` passes first try
- Generated workspace contains: typed `Charged` event (satisfies `MESSAGE`), `charge_svc` handler (satisfies `Service.HANDLER`), `notify_worker` (satisfies `Worker.WORKER`), migration SQL, Dockerfiles, `sun.toml` stubs
- `sun new svc/worker/fn` → minimal but complete primitive that compiles immediately; worker bin uses `let module W = Worker.Make(Notify_worker)` pattern (required by OCaml parser for functor access in expression position)
- `sun new event` → typed `MESSAGE` module + dune file; appends note if `events/<team>/dune` already exists

**Phase 5 step 2 complete — `sun dev up/down/status`:**
- `cmd_dev.ml` fully implemented: k3d cluster lifecycle, Helm chart installs (Redpanda, PostgreSQL, Loki, prometheus-community/prometheus), port-forward manager (PID files in `.sun/`), endpoint summary table
- `type set_val = Val of string | Str of string` distinguishes `--set` (YAML-parsed) from `--set-string` (always string) — prevents int64 coercion from rejecting Redpanda `cpu.cores` and `statefulset.replicas`
- Helm chart/service name corrections: `grafana/loki-stack` (not separate loki + grafana), `prometheus-community/prometheus` (lightweight; includes pushgateway), service names `loki` and `loki-grafana` (not `loki-stack*`)
- Schema registry (8081) and Pushgateway (9091) port-forwards wired
- Workspace scanner wired via `Sun_cli_workspace.scan ~dir:"."` — detects which infra charts to install
- Graceful error messages when k3d/helm/kubectl are not in PATH (prints install URL and exits 1)

**Phase 5 step 7 complete — `sun migrate`:**
- `cmd_migrate.ml` fully implemented: thin Eio + caqti wrapper over `Sun.Storage.Migration`
- `sun migrate` / `sun migrate apply` — applies pending migrations from `--dir` (default `db/migrations/`)
- `sun migrate status` — prints per-file applied/pending table with timestamps
- `sun migrate rollback` — prints helpful stub (no-op rollback; manual down-migration suggested)
- Reads `POSTGRES_URL` from env; clear error if missing
- `--table` flag for per-workspace migration tracking (same pattern as `Migration.apply ~table`)
- Verified end-to-end against live postgres: status → apply → status shows correct timestamps

**Workspace scaffold additions:**
- `.ocamlformat` and `README.md` now generated by `sun new workspace`; total 17 files
- README includes build instructions, run commands, CLI reference, and project layout

**Kafka security layer complete — `Kafka_security` module:**
- New shared module `integrations/kafka/kafka-eio-core/lib/kafka_security.{ml,mli}` — `type t` with `protocol`, `ssl_ca_location`, `sasl_mechanism`, `sasl_username`, `sasl_password`; `default` (Plaintext); `of_env()` reads `KAFKA_SECURITY_PROTOCOL` etc.; `apply conf t` calls `Kafka_raw.conf_set`
- `security : Kafka_security.t` field added to `Kafka_producer.config`, `Kafka_consumer.config`, `Kafka_service.config`, and the internal `Kafka_service.t` handle
- `Kafka_security.of_env()` called from `Kafka_service.config_of_env()` — every production deployment automatically reads security from the environment
- All test files updated: `security = Kafka_security.default` in integration tests for producer, consumer, service; `fake_config` in sun-worker tests; both demo binaries
- Build clean (`dune build` zero errors); 9/9 unit tests pass

**Orientation improvements:**
- README.md: "Security on Day 1" and "Dev mirrors prod exactly" added to Design Principles
- CLAUDE.md: "Current development focus" updated; `Kafka_security` entry added to key design decisions; "Core design principles every engineer must know" section added

## Next Up

**Step 3 — `sun up`** (template-based v1, design locked):
- Scan `app/<domain>/<name>-{svc,worker,fn}/` for Dockerfiles
- Docker build + push to `localhost:5000/<workspace>/<name>:<git-sha>`
- Render YAML from embedded string templates (not a typed AST — that's Phase 6)
- `kubectl apply --dry-run=server` validates before live apply
- In-cluster env vars hardcoded: `redpanda.redpanda.svc.cluster.local:9093`, etc.
- Namespace convention: `<workspace>-<domain>`
- See docs/planning/ROADMAP.md Phase 5 Step 3 for the complete locked-down spec

**Step 3 complete — `sun up`** (template-based v1):
- `cmd_up.ml` fully implemented: service discovery, docker build+push, YAML template rendering, `kubectl apply --dry-run=server` validation, live apply
- `type primitive = Svc | Worker | Fn` — inferred from directory suffix (`_svc`, `_worker`, `_fn`)
- Schedule extraction for `_fn`: scans `lib/<name>_fn.ml` for `schedule = "..."` literal; defaults to `"0 * * * *"` if not found
- Namespace convention: `<workspace>-<domain>` (e.g. `venus-comms`)
- k8s name: underscores replaced with hyphens (e.g. `notify_worker` → `notify-worker`)
- Image: `localhost:5000/<workspace>/<k8s_name>:<git_sha>`, tag overridable with `--tag`
- `--dry-run` skips docker build/push and prints YAML to stdout — validated against live venus workspace
- Five cluster env vars injected via ConfigMap: Kafka, schema registry, Postgres, Loki, Pushgateway (in-cluster DNS, verified against live cluster)
- `-svc` manifests include NodePort Service + liveness/readiness probes on `/healthz:8080`
- `-worker` manifests omit ports and probes (Kafka poll loop is the health signal)
- `Deploy_failed` exception halts pipeline at first error with clear message

**Step 4 complete — `sun status`**:
- `cmd_status.ml` fully implemented: discovers domains from `app/`, derives namespaces, checks existence with `kubectl get ns`, shows pods or "(not deployed — run 'sun up')"
- Domain filter arg: `sun status comms` limits to one namespace

**Venus notify_worker now deployable**:
- Added `examples/venus/app/comms/notify_worker/bin/main.ml` — standalone entrypoint wiring Obs, Db, Kafka from env vars; instantiates `Notify_worker.Make` functor with injected dependencies
- Added `examples/venus/app/comms/notify_worker/bin/dune`
- Added `examples/venus/app/comms/notify_worker/Dockerfile` — builds from repo root, `librdkafka1` runtime

**Step 3b complete — Logistics/fulfillment acceptance test (venus)**:
- `examples/venus/events/billing/payment_confirmed.ml` — `Payment_confirmed` event: `payment_id`, `charge_id`, `customer_id`, `amount_cents`, `currency`; library `venus_billing_events`
- `examples/venus/app/logistics/fulfillment_worker/` — `Fulfillment_worker` wired to `Message = Payment_confirmed`; standalone `bin/main.ml` with env-var driven Kafka config; `Dockerfile` for k8s deploy
- `sun up --dry-run` from venus discovers both `comms/notify_worker` and `logistics/fulfillment_worker`; correct namespaces `venus-comms` and `venus-logistics`

**Library naming bug fixed — workspace-prefix all generated library names**:
- Root cause: `sun new event/worker/svc/fn` generated bare library names (e.g., `billing_events`) that collide when two workspaces coexist in the same dune build graph
- Fix: `ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))` added to `cmd_new.ml`; all four `new_*` functions prefix `lib` with workspace name:
  - `new_event`: `lib = ws ^ "_" ^ team ^ "_events"` (e.g., `acme_billing_events`, `venus_billing_events`)
  - `new_worker`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_worker"` (e.g., `venus_logistics_fulfillment_worker`)
  - `new_svc`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_svc"`
  - `new_fn`: `lib = ws ^ "_" ^ domain ^ "_" ^ name ^ "_fn"`
- Output message from `sun new event` now correctly shows `(libraries venus_billing_events)`
- Both acme and venus coexist in full `dune build` with no name collisions

**Full e2e CLI acceptance test passed**:
- `sun new workspace acme` → 17 files → `dune build acme/` → clean
- From inside acme: `sun new event billing/payment_confirmed` + `sun new worker logistics/fulfillment` + `sun new svc ops/admin` + `sun new fn billing/invoice` → all build clean in single monorepo alongside venus
- `sun up --dry-run` from acme discovers all 5 services: `[worker] logistics/fulfillment_worker`, `[worker] comms/notify_worker`, `[svc] payments/charge_svc`, `[fn] billing/invoice_fn`, `[svc] ops/admin_svc`
- CronJob schedule `"0 * * * *"` extracted from fn source via literal scan

**Live `sun up` against venus — all pods Running (k3d cluster `sun-local`)**:
Ran `sun up` from `examples/venus/` against the live k3d cluster and discovered 6 real issues fixed in sequence:
1. **Namespace dry-run order**: Server-side dry-run fails if namespace doesn't exist yet. Fix: split manifest — apply namespace first (cluster-scoped, idempotent, always safe), then dry-run+apply workload resources against the now-existing namespace.
2. **Registry hostname split**: k3d's `registries.yaml` maps `sun-registry:5000` inside the cluster, but host pushes via `localhost:5000`. Fix: `push_image = localhost:5000/...`, `cluster_image = sun-registry:5000/...`; manifest references use `cluster_image`.
3. **`imagePullPolicy: Always`**: k3d/containerd caches images by tag, so re-pushing the same tag doesn't trigger a fresh pull. Fixed by adding `imagePullPolicy: Always` to all generated Deployments and CronJobs.
4. **GLIBC mismatch**: Binary compiled on Ubuntu 24.04 (GLIBC 2.39) but `debian:bookworm-slim` only has 2.36. Fixed by changing Dockerfile base to `ubuntu:24.04` in template and existing venus Dockerfiles.
5. **Missing `libpq5`**: `notify_worker` links against PostgreSQL client (`caqti-driver-postgresql` → `libpq.so.5`). Added `libpq5` to the Dockerfile template alongside `librdkafka1`.
6. **Migrations in-cluster**: Worker called `Migration.apply ~dir:"examples/venus/db/migrations"` (relative path, doesn't exist in container). Fixed: migrations dir now configurable via `MIGRATIONS_DIR` env var; skipped when env var is absent. Cluster workers connect to DB but don't run migrations — that's `sun migrate`'s job.
7. **`sun status` output order**: `Printf.printf` is OCaml-buffered, `Sys.command` writes directly to OS stdout. "Namespace:" header appeared after pod table. Fixed by adding `%!` flush before each `Sys.command` call.

Final state: `fulfillment-worker` and `notify-worker` both `1/1 Running`; consumer groups `venus-logistics-fulfillment-worker` and `comms-notify-worker` both **Stable** in Redpanda (verified via `rpk group list`). Logs ship to Loki (LOKI_URL set in ConfigMap).

**`sun status` NodePort port-forward hint** — NodePort service detection switched from `--field-selector spec.type=NodePort` (unsupported by kubectl for Services) to jsonpath filter: `'{.items[?(@.spec.type=="NodePort")].metadata.name}'`. Prints `→ kubectl port-forward svc/<name> -n <namespace> 8080:80` after pods table when a NodePort service is present.

**Full pluto e2e end-to-end verified** (sun new workspace → sun up → sun migrate → live API calls):

Workspace scaffold was extended to include DB integration by default: `sun new workspace pluto` now generates 19 files including a shared `lib/notification.ml` storage module (used by both svc and worker), `lib/dune` (pluto_storage library), and `db/migrations/0001_notifications.sql`. The scaffold wires:
- `app/payments/charge_svc`: `POST /charges` writes to DB; `GET /notifications` reads from DB
- `app/comms/notify_worker`: consumes `Charged` Kafka events, writes to DB via `Notification.insert`
- Both services wire Obs (Loki + Prometheus) with `~backend:(Obs_eio.compose log_backend prom)` and `Obs_eio.with_context`
- `MIGRATIONS_DIR` env var: workers skip migrations when absent (migrations are `sun migrate`'s job)

Verified sequence:
1. `sun new workspace pluto` → 19 files; `dune build examples/pluto/` → clean
2. `sun up` from examples/pluto/ → both pods `1/1 Running`; `sun status` shows port-forward hint
3. `sun migrate` → auto-detects cluster postgres, forks `kubectl port-forward` background process, applies `0001_notifications.sql`
4. `kubectl port-forward svc/charge-svc -n pluto-payments 8080:80`
5. `curl localhost:8080/health` → `ok`
6. `curl -X POST localhost:8080/charges` × 2 → `{"id":"ch_XXXXXX","accepted":true}`; both written to DB
7. `curl localhost:8080/notifications` → returns stored charges as JSON array

**Quickstart documentation written** — README.md §Quickstart: complete five-minute tutorial covering `sun dev up` → `sun new workspace` → `sun up` → `sun migrate` → API calls → Grafana. Includes scaffold structure table and "Adding a new domain" commands.

## Phase 5 — CLI Complete

All Phase 5 deliverables are done:

| Command | Status |
|---------|--------|
| `sun new workspace <name>` | ✓ |
| `sun new svc/worker/fn/event` | ✓ |
| `sun dev up/down/status` | ✓ |
| `sun up [--dry-run] [--tag]` | ✓ |
| `sun status [domain]` | ✓ |
| `sun migrate [status\|rollback]` | ✓ |

## Phase 6 — Production Deployment Pipeline (complete)

### `sun deploy` command

New `cli/sun/bin/cmd_deploy.ml`:
- `--image-tag <sha>` — image tag to deploy (defaults to short git SHA)
- `--registry <url>` — production container registry (ECR, Artifact Registry, Docker Hub); omit for local k3d
- `--emit-to <dir>` — GitOps mode: write per-service YAML files instead of applying to the cluster
- `--dry-run` — print YAML to stdout without applying

YAML rendering logic extracted from `cmd_up.ml` into `cli/sun/lib/sun_cli_manifest.ml` (new library module) so both commands share it. `Sun_cli_manifest` exports `discover_services`, `render`, `apply`, `emit_to_dir`, and all template helpers. Added `unix` to `cli/sun/lib/dune` deps for `Unix.mkdir` in `emit_to_dir`.

Verified end-to-end:
- `sun deploy prod/aws/us-east-1 --dry-run` → correct YAML with `sun-registry:5000` image refs
- `sun deploy prod/aws/us-east-1 --emit-to /tmp/pluto-manifests --image-tag abc1234 --registry 123456789.dkr.ecr.us-east-1.amazonaws.com` → wrote `pluto-comms-notify-worker.yaml` and `pluto-payments-charge-svc.yaml`; `image:` field contains `123456789.dkr.ecr.us-east-1.amazonaws.com/pluto/charge-svc:abc1234` ✓

### Terraform modules

**`platform/infra/base/`** — cluster-agnostic Helm bootstrap (any k8s):
- cert-manager (CRDs, Let's Encrypt staging + prod `ClusterIssuer`)
- ingress-nginx (LoadBalancer or NodePort)
- Argo CD + Ingress at `argocd.<base_domain>`
- Redpanda (configurable replicas, CPU, memory, persistent volumes)
- PostgreSQL via Bitnami chart (optional — set `install_postgresql=false` for RDS/Cloud SQL)
- Loki + Grafana stack + Ingress at `grafana.<base_domain>`
- Prometheus + Pushgateway

**`platform/infra/aws/`** — EKS cluster provisioning:
- VPC module (public + private subnets, 3 AZs, single or HA NAT gateway)
- EKS managed node group (configurable instance types, min/max/desired size)
- ECR repositories (one per service, `for_each` over `var.ecr_repositories`)
- ECR lifecycle policy (keep last 30 images)
- RDS PostgreSQL 16 (encrypted, private subnet, backup retention 7 days)
- Route53 hosted zone
- cert-manager IRSA role (IAM policy for Route53 DNS01 challenge solving)
- Outputs: `kubeconfig_command`, `ecr_registry`, `ecr_login_command`, `postgres_url`, `cert_manager_irsa_arn`

**`platform/infra/gcp/`** — GKE Autopilot cluster provisioning:
- Custom VPC with secondary ranges for GKE pods/services
- Cloud Router + NAT
- GKE Autopilot cluster (private nodes, REGULAR release channel)
- Artifact Registry repository
- IAM binding: GKE node SA → `artifactregistry.reader`
- Cloud SQL PostgreSQL 16 (private IP, configurable tier + HA)
- Private service connection for Cloud SQL
- Cloud DNS managed zone
- Outputs: `kubeconfig_command`, `artifact_registry`, `docker_auth_command`, `postgres_url`

### CI/CD reference workflows

**`platform/infra/ci/github-actions-deploy.yml`** — direct deploy mode:
1. Build OCaml binaries, build + push Docker images to ECR
2. `sun deploy "$SUN_TARGET" --image-tag $SHA --registry $ECR_REGISTRY`
3. `sun status`

**`platform/infra/ci/github-actions-gitops.yml`** — GitOps mode:
1. Build + push images to ECR
2. `sun deploy "$SUN_TARGET" --emit-to manifests/ --image-tag $SHA`
3. Commit + push `manifests/*.yaml` to separate GitOps repo
4. Argo CD reconciles cluster

**`platform/infra/argocd/application.yaml`** — Argo CD `Application` manifest (one-time cluster setup):
- `syncPolicy.automated.prune = true` — removes resources deleted from GitOps repo
- `syncPolicy.automated.selfHeal = true` — reverts manual kubectl changes
- `ServerSideApply=true` — handles multi-owner field management

### Documentation

`docs/guides/TUTORIAL.md` §CLI reference updated with `sun deploy` flags. New §Part 8 — Production deployment covers:
- Direct deploy and GitOps deploy modes
- AWS (EKS) and GCP (GKE) provisioning commands
- `platform/infra/base/` platform bootstrap
- Argo CD one-time setup

## Current State — Phase 6 Complete

The production deployment pipeline is complete. All Phase 6 deliverables are done:

| Deliverable | Status |
|---|---|
| `Sun_cli_deployment_plan` — typed deployment plan | ✓ |
| `Sun_cli_env_target` — `Local_k3d`, `Customer_k8s_direct`, `Customer_k8s_gitops`, `Sun_hosted` | ✓ |
| `Sun_cli_executor` — `local`, `direct`, `gitops` executors | ✓ |
| `sun deploy --image-tag --registry --emit-to --dry-run` | ✓ |
| `sun deploy --emit-plan-to FILE` — plan JSON serialization | ✓ |
| `Sun_cli_toml` — `sun.toml` parser (scale, env, deploy, labels) | ✓ |
| `platform/infra/aws/`, `platform/infra/gcp/`, `platform/infra/base/` Terraform modules | ✓ |
| Argo CD `Application` manifest + GitOps emit mode | ✓ |
| `docs/deployment/escape-hatches.md` — four-level escape hatch hierarchy | ✓ |
| `docs/deployment/self-hosted-substrate-contract.md` | ✓ |
| CI workflow references (`platform/infra/ci/`) | ✓ |

## Phase 7 — Core deliverables complete

| Ticket | Description | Status |
|---|---|---|
| FEAT-010 | Sun-hosted executor spike | ✓ DONE |
| FEAT-011 | Argo Rollouts canary/blue-green support | ✓ DONE |
| FEAT-012 | CI workflow scaffold in `sun new workspace` | ✓ DONE |
| FEAT-013 | Docs aligned with implementation reality | ✓ DONE |
| FEAT-014 | Sun-hosted secret management | ✓ DONE |
| FEAT-016 | Hosted account/environment model | ✓ DONE |
| FEAT-018 | Hosted executor (full impl) | ✓ DONE |
| FEAT-015 | Hosted release inspection and diagnostics | BACKLOG — blocked on DEC-007 |
| FEAT-017 | Hosted default URLs and custom-domain flow | BACKLOG — blocked on DEC-005 |

**Note on `sun.toml` parsing:** `Sun_cli_toml` is fully implemented and reads all supported fields from user files. `[infra.rollout]` canary/blue-green is now backed by Argo Rollouts manifest synthesis (FEAT-011). Remaining unimplemented `sun.toml` fields: `[infra.kafka]` extra topics, `secrets` in `[infra.env]`.

**Kafka security wiring to C — verify `apply` correctness with live cluster:**
- `Kafka_security.apply` calls `Kafka_raw.conf_set`; verified at compile time; exercise with a SASL-authenticated Redpanda to confirm end-to-end
- TLS dev gap: Redpanda in k3d runs with `tls.enabled=false` because cert-manager CRDs aren't provisioned in the dev cluster; this is a documented conscious choice, not an oversight — production deployments set `KAFKA_SECURITY_PROTOCOL=ssl` and the code picks it up automatically

---

## Files

| File | Status |
|---|---|
| `integrations/observability/obs-eio/lib/obs_trace.ml/.mli` | Complete |
| `integrations/observability/obs-eio/lib/obs_metrics.ml/.mli` | Complete |
| `integrations/observability/obs-eio/lib/obs.ml/.mli` | Complete — added `context` field to `span_event` |
| `integrations/observability/obs-eio/test/test_obs.ml` | Complete — 18 tests |
| `integrations/observability/obs-eio-loki/lib/obs_loki.ml/.mli` | Complete |
| `integrations/observability/obs-eio-loki/test/test_loki.ml` | Complete — 8 tests |
| `integrations/observability/obs-eio-loki/obs-eio-loki.md` | Complete — spec |
| `platform/local/scripts/ensure-loki.sh` | Complete |
| `platform/local/scripts/ensure-grafana.sh` | Complete |
| `integrations/observability/obs-eio/lib/obs.ml/.mli` | Updated — added `help` field to `metric_event` |
| `integrations/observability/obs-eio-prometheus/lib/obs_prometheus.ml/.mli` | Complete |
| `integrations/observability/obs-eio-prometheus/test/test_prometheus.ml` | Complete — 10 tests |
| `platform/local/scripts/ensure-pushgateway.sh` | New |
| `platform/local/scripts/ensure-prometheus.sh` | New — also provisions Prometheus datasource in Grafana |
| `platform/local/config/prometheus.yml` | New — 5s scrape interval, Pushgateway target |
| `docs/planning/ROADMAP.md` | Updated — prometheus done, HTTP service layer next |
| `framework/sun-svc/lib/auth.ml/.mli` | Complete |
| `framework/sun-svc/lib/response.ml/.mli` | Complete |
| `framework/sun-svc/lib/request.ml/.mli` | Complete |
| `framework/sun-svc/lib/route.ml/.mli` | Complete |
| `framework/sun-svc/lib/service.ml/.mli` | Complete |
| `framework/sun-svc/test/test_routing.ml` | Complete — 10 tests |
| `framework/sun-svc/test/test_auth.ml` | Complete — 11 tests |
| `framework/sun-svc/test/test_service.ml` | Complete — 11 tests |
| `framework/sun-svc/sun-svc.md` | Complete — design spec |
| `framework/sun-fn/lib/fn.ml/.mli` | Complete |
| `framework/sun-fn/lib/dune` | Complete |
| `framework/sun-fn/test/test_fn.ml` | Complete — 7 tests |
| `framework/sun-fn/sun-fn.md` | Complete — design spec |
| `dune-project` | New root project (merged obs + http) |
| `framework/sun-svc/lib/service.ml` | Updated — `?ot:Obs_eio.t`, `?route_observer`, per-request metrics |
| `framework/sun-svc/lib/service.mli` | Updated — `?ot:Obs_eio.t` exposed |
| `framework/sun-svc/lib/dune` | Updated — added `obs_eio` dep |
| `framework/sun-svc/test/test_service.ml` | Updated — 2 new metrics tests (13 total) |
| `framework/sun-svc/test/dune` | Updated — added `obs_eio obs_prometheus_eio` deps |
| `framework/sun-worker/lib/worker.ml/.mli` | Complete |
| `framework/sun-worker/lib/dune` | Complete |
| `framework/sun-worker/test/test_worker.ml` | Complete — 7 tests |
| `framework/sun-worker/test/dune` | Complete |
| `framework/sun-worker/sun-worker.md` | Complete — design spec |
| `integrations/kafka/dune-project` | Deleted — merged kafka into root project |
| `examples/local-demo/lib/events.ml` | Complete — OrderPlaced message contract |
| `examples/local-demo/lib/dune` | Complete |
| `examples/local-demo/bin/demo.ml` | Complete — orchestrated e2e demo |
| `examples/local-demo/bin/dune` | Complete |
| `examples/local-demo/FRICTION_LOG.md` | Complete — 7 friction items |
| `http/` → `framework/` | Renamed — updated CLAUDE.md, README, ROADMAP, WORK_SUMMARY |
| `integrations/storage/sun-storage/lib/storage_error.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/db.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/migration.ml/.mli` | Complete |
| `integrations/storage/sun-storage/lib/table.ml/.mli` | Complete |
| `integrations/storage/sun-storage/test/test_storage.ml` | Complete — 8 tests |
| `integrations/storage/sun-storage/sun-storage.md` | Complete — design spec |
| `platform/local/scripts/ensure-postgres.sh` | New |
