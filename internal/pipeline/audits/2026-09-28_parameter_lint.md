# Advisory parameter-lint review — 2026-09-28

Scope: parameter families/sprawl and contextual grouping only. This is not a
new whole-codebase correctness, effect-boundary or type-safety audit.

Source revision: `1aaec96d` (`origin/main` at scan time). Checker revision:
`677ae55f`, PR #672. The checker was run from its separate owned worktree;
source review and this filing use the clean audit worktree.

## Reproduction and positive control

From `/home/lbendtly/Code/sol-parameter-lint-findings`:

```bash
/home/lbendtly/Code/sol-parameter-style-lint/_build/default/internal/tooling/style_audit/main.exe --json cli framework internal examples > /tmp/sol-parameter-audit-candidates.json
```

The scan exits 0 with 49 advisory locations: 45 `parameter-sprawl` and four
`parameter-family`. Counts include separately reported `.ml`/`.mli` declarations
and distinct functor/test bindings; they are not 49 independent refactoring tasks.
The positive control is `consume_partitioned`: its implementation at
`kafka_service.ml:362` reports 17 parameters, eight optional and six `on_*` names.
Consumer-hook changes are already owned by REFAC-155 / PR #671 and are not filed
again.

The root list includes CLI and framework tests, examples, internal tooling and
internal fixtures. No `examples/` or `internal/tooling/` location occurs in this
JSON; the same invocation does contain the consumer positive control and
`cli/test/test_release_id.ml:4`'s fixture. This is a statement about the checker’s
thresholds, not proof of architectural perfection or complete AST coverage.
Hidden/dependency directories and symlinks are excluded by the checker.

## Reviewed result

One new ticket: **CODEX_STYLE_AUDIT-078**, reuse the existing observability options
at `sol open`'s command boundary (`cli/bin/cmd_open.ml:15,60`). This location is
below the automated thresholds. Contextual review found the already-existing
concept in `cmd_logs.ml:91` and its subset construction in `cmd_status.ml:536`.
The remediation reuses that type and preserves the existing flag surface.

`Sol_jobs.Make.run`'s poll interval, lease and claim-failure budget were considered
as a possible claim-policy group. They share a loop, but remain independently
selectable controls and were deliberately retained in REFAC-152. This pass found
no additional cross-input invariant that warrants overturning that decision;
sharing an execution phase alone is not a requirement to add a record.

## Candidate inventory and disposition

Read public signatures, implementations and representative call sites/tests.
Existing semantic-record constructors and independently selectable execution
controls are retained; numerical warnings do not mandate a second wrapper.

| Location | Binding | Rule | Total / optional | Disposition |
| --- | --- | --- | --- | --- |
| `cli/lib/base/sol_cli_process.ml:25` | `cmd` | `parameter-sprawl` | 5 / 4 | Retain: existing process-command constructor |
| `cli/lib/base/sol_cli_process.mli:25` | `cmd` | `parameter-sprawl` | 5 / 4 | Retain: existing process-command constructor |
| `cli/lib/deploy/sol_cli_command_request.ml:81` | `make_deploy_request` | `parameter-sprawl` | 13 / 0 | Retain: raw CLI normalization into request (REFAC-152) |
| `cli/lib/deploy/sol_cli_command_request.mli:44` | `make_deploy_request` | `parameter-sprawl` | 13 / 0 | Retain: raw CLI normalization into request (REFAC-152) |
| `cli/lib/deploy/sol_cli_deployment_plan.ml:679` | `of_services_result` | `parameter-sprawl` | 8 / 4 | Retain: grouped environment plus independent planning facts (REFAC-152) |
| `cli/lib/deploy/sol_cli_deployment_plan.mli:141` | `of_services_result` | `parameter-sprawl` | 8 / 4 | Retain: grouped environment plus independent planning facts (REFAC-152) |
| `cli/lib/deploy/sol_cli_factory.ml:6` | `plan_of_services` | `parameter-sprawl` | 8 / 4 | Retain: grouped environment plus independent planning facts (REFAC-152) |
| `cli/lib/deploy/sol_cli_factory.mli:6` | `plan_of_services` | `parameter-sprawl` | 8 / 4 | Retain: grouped environment plus independent planning facts (REFAC-152) |
| `cli/lib/deploy/sol_cli_release_inspection.ml:117` | `affected_service` | `parameter-sprawl` | 6 / 4 | Retain: constructor of existing semantic record |
| `cli/lib/deploy/sol_cli_release_inspection.ml:239` | `diagnostics` | `parameter-sprawl` | 6 / 5 | Retain: constructor of existing semantic record |
| `cli/lib/deploy/sol_cli_release_inspection.mli:85` | `affected_service` | `parameter-sprawl` | 6 / 4 | Retain: constructor of existing semantic record |
| `cli/lib/deploy/sol_cli_release_inspection.mli:108` | `diagnostics` | `parameter-sprawl` | 6 / 5 | Retain: constructor of existing semantic record |
| `cli/lib/workspace/sol_cli_manifest.mli:130` | `ingress_doc` | `parameter-sprawl` | 7 / 4 | Retain: independent routing/TLS options (REFAC-152) |
| `cli/lib/workspace/sol_cli_manifest_yaml.ml:522` | `ingress_doc` | `parameter-sprawl` | 7 / 4 | Retain: independent routing/TLS options (REFAC-152) |
| `cli/test/test_cloud_destroy.ml:179` | `fake_deps` | `parameter-sprawl` | 9 / 8 | Retain: focused fixture/test overrides |
| `cli/test/test_manifest_render.ml:12` | `render_spec_ok` | `parameter-sprawl` | 6 / 5 | Retain: focused fixture/test overrides |
| `cli/test/test_manifest_render.ml:60` | `workload` | `parameter-sprawl` | 5 / 4 | Retain: focused fixture/test overrides |
| `cli/test/test_release_id.ml:4` | `wl` | `parameter-sprawl` | 19 / 17 | Retain: focused fixture/test overrides |
| `cli/test/test_rollback.ml:1243` | `deployment_event` | `parameter-sprawl` | 7 / 6 | Retain: focused fixture/test overrides |
| `cli/test/test_supervised.ml:303` | `facts` | `parameter-sprawl` | 6 / 5 | Retain: focused fixture/test overrides |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:310` | `consume` | `parameter-sprawl` | 13 / 6 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:310` | `consume` | `parameter-family` | 13 / 6 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:362` | `consume_partitioned` | `parameter-sprawl` | 17 / 8 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:362` | `consume_partitioned` | `parameter-family` | 17 / 8 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.mli:219` | `consume` | `parameter-sprawl` | 13 / 6 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.mli:219` | `consume` | `parameter-family` | 13 / 6 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.mli:251` | `consume_partitioned` | `parameter-sprawl` | 17 / 8 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/kafka-eio-service/lib/kafka_service.mli:251` | `consume_partitioned` | `parameter-family` | 17 / 8 | Already owned: REFAC-155 / PR #671 |
| `framework/ocaml/sol-fn/lib/fn.ml:28` | `run` | `parameter-sprawl` | 6 / 4 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-fn/lib/fn.mli:19` | `run` | `parameter-sprawl` | 6 / 4 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-jobs/lib/sol_jobs.ml:225` | `run` | `parameter-sprawl` | 12 / 9 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-jobs/lib/sol_jobs.mli:30` | `run` | `parameter-sprawl` | 12 / 9 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml:247` | `run_slow` | `parameter-sprawl` | 6 / 4 | Retain: focused fixture/test overrides |
| `framework/ocaml/sol-svc/lib/service.ml:75` | `dispatch_unguarded` | `parameter-sprawl` | 10 / 4 | Retain: per-request inputs and distinct auth/body/metrics/readiness controls |
| `framework/ocaml/sol-svc/lib/service.ml:328` | `run` | `parameter-sprawl` | 10 / 8 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-svc/lib/service.mli:10` | `run` | `parameter-sprawl` | 10 / 8 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-svc/lib/service.mli:28` | `run` | `parameter-sprawl` | 11 / 8 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-svc/test/test_auth.ml:175` | `sign_hs256` | `parameter-sprawl` | 6 / 5 | Retain: focused fixture/test overrides |
| `framework/ocaml/sol-svc/test/test_auth.ml:190` | `hs256_verified_cfg` | `parameter-sprawl` | 5 / 4 | Retain: focused fixture/test overrides |
| `framework/ocaml/sol-svc/test/test_auth.ml:212` | `sign_rs256` | `parameter-sprawl` | 6 / 5 | Retain: focused fixture/test overrides |
| `framework/ocaml/sol-svc/test/test_auth.ml:226` | `rs256_verified_cfg` | `parameter-sprawl` | 5 / 4 | Retain: focused fixture/test overrides |
| `framework/ocaml/sol-worker/lib/worker.ml:189` | `run` | `parameter-sprawl` | 9 / 6 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.ml:260` | `run` | `parameter-sprawl` | 8 / 5 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.ml:266` | `run` | `parameter-sprawl` | 11 / 7 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.ml:371` | `run` | `parameter-sprawl` | 10 / 6 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.mli:46` | `run` | `parameter-sprawl` | 8 / 5 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.mli:59` | `run` | `parameter-sprawl` | 10 / 6 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.mli:75` | `run` | `parameter-sprawl` | 9 / 6 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |
| `framework/ocaml/sol-worker/lib/worker.mli:96` | `run` | `parameter-sprawl` | 11 / 7 | Retain: distinct runtime/lifecycle/policy options (REFAC-152) |

## Manual walk and overlap evidence

- `framework/ocaml/`: public worker/service/function/jobs interfaces, matching
  implementations, specs and representative tests. The consumer hooks positive
  control is already owned. Job claim knobs and the service shutdown timing pair
  were considered and retained; independent controls remain explicit.
- `cli/lib/`: process command builder, deployment request and plan/factory,
  release inspection constructors and ingress renderer, with interfaces and
  representative callers/tests. REFAC-152's explicit retention decisions were
  rechecked rather than reopened solely because the linter flags them.
- `cli/bin/`: open, logs/status options terms, deploy request term and up
  orchestration. The existing observability type makes the one filed remediation
  small; PR #670's controller cleanup remains outside this filing.
- Tests: cloud lifecycle dependency fixtures, manifest/release identity builders,
  rollback event/probe facts and framework auth/jobs helpers. Individual override
  values make assertions legible; another record layer would obscure the scenario.
- `examples/` and `internal/tooling/`: representative handler/launcher and tool
  signatures/callers inspected despite zero threshold warnings.
- `platform/shared/templates/{event,fn,worker,svc,workspace}`: signatures and
  representative bodies were manually read. Raw fn/worker templates contain
  placeholders and are not valid OCaml before rendering; no generated-workspace
  AST scan was performed. Short publisher/storage calls and launchers were
  retained. No code folder above was omitted from contextual review; external
  support repositories were not in this Sol-only filing scope.

Overlap search (read-only):

```bash
rg -n 'cmd_open|observability.*options|parameter.*famil|parameter.*sprawl|make_deploy_request' internal/pipeline/tickets -g '*.md'
```

Positive controls include DONE/REFAC-089's logs/status grouping and
DONE/REFAC-152's exact constructor inventory. The open-view feature in
BACKLOG/OBS-045 adds traces and does not implement this controller grouping.
PR #671's ticket and diff were also checked to avoid duplicating its hooks work.

## Validation

This filing changes documentation and one ticket only. Validate all ticket
frontmatter with the existing pipeline parser; no application tests apply.
The linter already has its own AST fixture harness in PR #672. Findings stay
in READY_FOR_ENGINEERING until implementation and its checks merge; no source
refactors were performed during this pass.
