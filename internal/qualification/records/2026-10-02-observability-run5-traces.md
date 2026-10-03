# Observability local qualification run 5 — `OBS-045`, the traces view

The fifth run of the observability workstream
([`../observability/README.md`](../observability/README.md)); the matrix it feeds
is
[`../observability/observability-diagnostic-matrix.md`](../observability/observability-diagnostic-matrix.md).
Runs 1–4 are
[`2026-10-02-observability-local-qualification.md`](2026-10-02-observability-local-qualification.md),
[`2026-10-02-observability-run2-local.md`](2026-10-02-observability-run2-local.md),
[`2026-10-02-observability-run3-alert-route.md`](2026-10-02-observability-run3-alert-route.md)
and [`2026-10-02-observability-run4-local.md`](2026-10-02-observability-run4-local.md).

Not a provider run. This run qualifies `OBS-045` (OB-T4): the
`sol open traces [SCOPE]` view over the identity `OBS-050` put on spans. It
found and fixed a defect in the shared Grafana Explore URL builder that also
affected the shipped `sol open logs` view.

## 1. Run identity

| Field | Value | Source |
|---|---|---|
| Sol revision | `OBS-045/open-traces`, based on `main @ 8357c0ba` | `git log` in the worktree |
| Date | 2026-10-02 (local, UTC-06) | |
| Kubernetes | **none** — the URL and query were exercised without a cluster | observed |
| Broker | Redpanda, native, `:9092` / schema registry `:8081` | already running |
| Tempo | 2.5.0, native, OTLP `:4318` / query `:3200` | already running |
| Dashboard shell | Grafana 11.3.0, native `:3000`, Tempo datasource uid `tempo` | already running |
| Producer of spans | `internal/fixtures/local-demo` (real `Sol_obs.of_env`) | |

## 2. The scope→query mapping, derived from what the spans carry

`OBS-045`'s open question was which attributes the scope→query mapping can use.
`OBS-050` (run 4) settled it: every span carries
`resource.workspace`/`resource.domain`/`resource.service` (plus `env`,
`primitive`, `release`). The view therefore selects on those, not on
`service.name` and not on a guessed convention:

| Scope | TraceQL |
|---|---|
| `sol open traces` (workspace) | `{ resource.workspace = "<workspace>" }` |
| `sol open traces payments` | `{ resource.workspace = "<workspace>" && resource.domain = "payments" }` |
| `sol open traces payments/charge-svc` | `{ ... && resource.service = "charge-svc" }` |
| `sol open traces resource/rds/<name>` | error — managed resources emit no Sol spans |

The unit is the bare Kubernetes name (`charge_svc` → `charge-svc`), the same
value the log selector and the pod label use.

## 3. The pane is valid JSON, and Grafana's Tempo datasource runs it

A workspace named `obs045` was scaffolded, the demo was run twice (once with
`SOL_DOMAIN=payments`, once with `SOL_DOMAIN=comms`), and each `sol open traces`
URL was decoded and its query executed through Grafana's own Tempo datasource
proxy — the same path the browser uses:

```text
sol open traces (workspace)                datasource=tempo queryType=traceql
  query:  { resource.workspace = "obs045" }
  traces: 6  (a3cef257, f6dc717c, b843fbd9, 8ff5cd4f, 7cc87079, 861dfd2c)
sol open traces payments                   datasource=tempo queryType=traceql
  query:  { resource.workspace = "obs045" && resource.domain = "payments" }
  traces: 3  (8ff5cd4f, 7cc87079, 861dfd2c)
sol open traces payments/order-svc         datasource=tempo queryType=traceql
  query:  { ... && resource.service = "order-svc" }
  traces: 3  (8ff5cd4f, 7cc87079, 861dfd2c)
sol open traces payments/fulfillment-worker
  query:  { ... && resource.service = "fulfillment-worker" }
  traces: 3  (8ff5cd4f, 7cc87079, 861dfd2c)   <- the same three
sol open traces comms/order-svc
  query:  { ... && resource.domain = "comms" && resource.service = "order-svc" }
  traces: 3  (a3cef257, f6dc717c, b843fbd9)
sol open traces nope/order-svc
  traces: 0                                   <- negative control
```

**One trace under two units.** Each demo trace has an `order-svc` span and a
`fulfillment-worker` span (a Kafka hop). The `order-svc` unit query and the
`fulfillment-worker` unit query return *the same three trace ids*: a trace is
selected when **any** span matches, so a trace crossing a unit boundary appears
under both. The domain dimension is the identical per-span match:
`resource.domain="payments"` returns only the payments run and
`resource.domain="comms"` only the comms run. A single trace whose spans carry
two *different* domains needs two units each with their own injected
`SOL_DOMAIN` (two ConfigMaps); the demo's units share one process environment,
so that exact case is the deployed/LIVE remainder, not a query-shape question.

**Backends.** Like the other views, the URL is resolved or explained, never
guessed:

```text
$ sol open traces payments --links --observability-backend self_hosted_durable --base-domain example.test
https://grafana.example.test/explore?orgId=1&left=...
$ sol open traces payments --links --observability-backend external --grafana-base-url http://grafana.example:3000
http://grafana.example:3000/explore?orgId=1&left=...
$ sol open traces payments --links --observability-backend external
Grafana traces: (no generated URL for the "external" backend -- check your configured observability provider directly)
```

**`sol status` advertises it.** `sol local status` prints the `Open` block, which
now includes `traces     sol open traces`; the workspace/domain/service variants
carry the same scope suffix as `logs`.

## 4. Defect found and fixed: the Grafana Explore pane was not valid JSON

Decoding the `left=` parameter **once** (which is what a browser does before
Grafana `JSON.parse`s it) produced invalid JSON. The inner quotes of the query
were percent-encoded once, so after the URL-decode they were raw and closed the
JSON string early:

```text
$ sol open logs payments/charge_svc --links     # before the fix
http://localhost:3000/explore?orgId=1&left=%7B%22datasource%22:%22loki%22,%22queries%22:%5B%7B%22expr%22:%22%7Bworkspace%3D%22obs045%22...

decoded left: {"datasource":"loki","queries":[{"expr":"{workspace="obs045", domain="payments", service="charge-svc"}"}]}
JSON.parse:   INVALID -> Expecting ',' delimiter: line 1 column 54
```

The same shape was true for the new traces URL. The fix is to JSON-encode the
pane (so a quote inside a string value becomes `\"`) and then percent-encode the
whole JSON — the convention Grafana itself emits. After the fix the decoded pane
parses and round-trips:

```text
$ sol open traces --links
http://localhost:3000/explore?orgId=1&left=%7B%22datasource%22%3A%22tempo%22...%22query%22%3A%22%7B%20resource.workspace%20%3D%20%5C%22obs045%5C%22%20%7D%22...

decoded left: {"datasource":"tempo","queries":[{"refId":"A","queryType":"traceql","query":"{ resource.workspace = \"obs045\" }"}]}
JSON.parse:   valid
```

`internal/.../cli/test/inline/test_open.ml` now decodes the `left` pane and
asserts it parses and that `queries[0].query`/`.expr` equals the intended
selector, for both traces and logs — the check that would have caught this. The
earlier runs verified the URL *string* and the datasource proxy, but never that
Grafana can parse the pane; that method gap is what let the defect ship.

## 5. Row roll-up

| Row | Before | After |
|---|---|---|
| OB-T4 traces CLI surface | `UNQUALIFIED` (documented gap) | `QUALIFIED (LOCAL)` — workspace/domain/unit URLs over the real identity; the unit query returns the unit's traces from a real run, and a cross-unit trace appears under both units |

## 6. What this run does not establish

- The literal two-`SOL_DOMAIN` trace under one trace id needs two units with
  their own ConfigMaps — the deployed case.
- Nothing here is `LIVE`.
- TypeScript units do not yet carry the `resource.*` attributes the query
  selects, so their spans are not resolvable by this view until `OBS-051` lands.

## 7. Findings

| Finding | Class | State |
|---|---|---|
| The Grafana Explore URL's `left` pane is invalid JSON after one URL-decode (`sol open logs` and the new traces view) | LOCAL | found and fixed by `OBS-045`; round-trip test added |
| TypeScript units' spans carry no `resource.workspace`/`domain`/`service` | MODELED | `OBS-051` owns reading the injected identity |
