# 2026-09-05 Code Layer Audit

Scope:

- `/home/lbendtly/Code/sun`
- `/home/lbendtly/Code/*-eio`

Method: traced public APIs, neutral models, adapters, transport helpers, and
shared-code placement. This pass allows breaking APIs in Sun and the foundation
packages when the current boundary is wrong.

## Findings

### CODE_LAYER-001 - AWS signed transport classifies service errors too early

Status: Open
Severity: High
Tag: move

`Aws.Http.signed_request` returns `Error (Http_error (status, body))` for every
non-2xx response even though service packages need the raw status/body to
classify provider-specific errors. Both `s3-eio` and `dynamodb-eio` now carry
`reclassify_transport_result` shims to undo that transport decision:

- `/home/lbendtly/Code/aws-eio/lib/aws_http.mli`
- `/home/lbendtly/Code/s3-eio/lib/s3_client.ml`
- `/home/lbendtly/Code/dynamodb-eio/lib/dynamodb_client.ml`

Replacement: break `Aws.Http.signed_request` so HTTP responses return
`Ok (status, headers, body)` regardless of status. Reserve `Error` for signing,
credential, network, timeout, and protocol failures. Delete the S3/DynamoDB
reclassification shims and let service adapters own service-level error
classification.

### CODE_LAYER-002 - DynamoDB typed table layer still returns raw items

Status: Open
Severity: Medium
Tag: leak

`Dynamodb_table.Index` is documented as the ElectroDB-replacement typed indexing
layer, but its `get`/`query_page`/`query_all` APIs still return
`Dynamodb_client.item`. `Entity.stamp`/`Entity.check` are separate helpers that
callers must remember to compose by hand, so the layer only types key shape and
does not actually own entity decode/check boundaries.

- `/home/lbendtly/Code/dynamodb-eio/README.md`
- `/home/lbendtly/Code/dynamodb-eio/lib/dynamodb_table.mli`
- `/home/lbendtly/Code/dynamodb-eio/lib/dynamodb_table.ml`

Replacement: either rename the current module honestly as key-index helpers, or
break the API into a real typed entity/index functor that combines key formatting,
entity discrimination, and encode/decode so callers get domain values back.

### CODE_LAYER-003 - Sun observability provider wiring leaks into generated apps

Status: Open
Severity: Medium
Tag: move

Generated service and worker entrypoints construct Loki, Prometheus, Tempo,
compose `Obs_eio` backends, manage `LOKI_URL`/`TEMPO_URL`, and pass
`?ot`/`?metrics_renderer` separately into framework runners. The framework APIs
also expose different observability shapes per primitive:

- `sun-svc`: `?ot` plus `?metrics_renderer`
- `sun-worker`: `?ot` plus `?metrics_renderer`
- `sun-fn`: `?backend` plus `?pushgateway_url`

Relevant files:

- `/home/lbendtly/Code/sun/cli/sun/lib/sun_cli_scaffold_templates.ml`
- `/home/lbendtly/Code/sun/framework/sun-svc/lib/service.mli`
- `/home/lbendtly/Code/sun/framework/sun-worker/lib/worker.mli`
- `/home/lbendtly/Code/sun/framework/sun-fn/lib/fn.mli`

Replacement: add one Sun-owned observability bootstrap module, not another
foundation-package layer. It should read Sun env conventions and return the
small primitive-specific bundle each runner needs. Then generated apps call that
one helper instead of knowing provider composition.

### CODE_LAYER-004 - Obs trace model cannot represent parent span IDs

Status: Open
Severity: Medium
Tag: leak

`Obs_eio.span_event` carries only the current `trace_ctx`. `obs-tempo-eio`
documents that it cannot set `parent_span_id`, so spans sharing a trace ID are
not linked into a parent/child waterfall in Tempo.

- `/home/lbendtly/Code/obs-eio/lib/obs_eio.mli`
- `/home/lbendtly/Code/obs-tempo-eio/lib/obs_tempo.ml`

Replacement: break the neutral trace event shape so it carries parent span ID
when a span was opened from a parent. Keep provider adapters dumb: Tempo should
translate that field into OTLP, Loki can ignore it or log it, and Prometheus can
remain a no-op for spans.

## Layer Sketch

Recommended shape:

`app/scaffold -> Sun bootstrap/framework API -> foundation public API -> neutral model -> provider adapter -> transport helper`

`obs-eio` itself should stay:

`caller -> Obs_eio API -> span/metric event -> Obs_loki/Obs_prometheus/Obs_tempo -> https-eio`

Do not add a generic `internal-rep` package for observability; the event records
already are that boundary.
