# Cross-language framework contract audit

**Formerly** `internal/pipeline/audits/2026-10-02_cross_language_contract_audit.md`, moved here on
2026-10-04 when the audit report area became rulebooks only. The old path is named so citations in
closed tickets still resolve to this file.

**Date:** 2026-10-02
**Base:** `origin/main` @ `54f53c8e` (PR #883). OCaml line references are to that
commit. TypeScript references are to each package's own `origin/main` at the
commits named in § *Method*.
**Scope:** the public Sol framework contract — every convention and package API
an application author programs against — as implemented by the OCaml framework
(`framework/ocaml/*`) and the published TypeScript packages (`@sol-fab/kafka`,
`@sol-fab/obs`, `@sol-fab/svc`, `@sol-fab/worker`, each in its own repository).
**Trigger:** DEC-022 makes behavioural parity a per-capability obligation and
`internal/specs/framework-conventions.md` is the index of record. The existing
per-language verdicts live in the 2026-09-07 spike addendum
(`2026-09-07_typescript_demo_spike.md`, FEAT-080), which was scoped to what a
hand-ported demo exercised, not to the whole contract. This pass is the complete
inventory DEC-022 asks for, and it is the per-language verdict record the
conventions index now points at.

Parity here is **capability and behavioural**, not implementation (DEC-022): the
contract must hold across languages while the code underneath need not be
shared. Two conformance levels both matter — the TypeScript golden path
(FEAT-082) and the capability matrix. This audit covers the capability matrix.

## Method

Every claim is **observed**: a command was run and its output is recorded in
§ *Verification*, or a line of the defining source is quoted. Nothing was
mutated; the operator's checkout and the sibling repositories were read only.
No broker, registry or database was started, so this is a code-level audit: it
does not claim to reproduce runtime behaviour, only to compare the two
implementations of each contract.

Read at these revisions (all fetched at audit time; the local worktree copies
were stale, so `git show origin/main:<path>` was used):

| Repository | `origin/main` | Package version |
|---|---|---|
| `loganbnielsen/sol` (this repo) | `54f53c8e` | — |
| `loganbnielsen/sol-kafka` | `3956fea` (`@sol-fab/kafka`) | 0.3.0 |
| `loganbnielsen/sol-obs` | `13128e6` (`@sol-fab/obs`) | 0.1.1 |
| `loganbnielsen/sol-typescript` | `9d48eca` (`@sol-fab/svc`, `@sol-fab/worker`) | 0.1.0 |

## 1. The contract surfaces

The contract is defined once in `internal/specs/framework-conventions.md` and
`docs/reference/runtime.md`. Each row below is the implementation of one
convention on each side.

| Convention | OCaml | TypeScript |
|---|---|---|
| Discovery and build | CLI-owned (`Sol_cli_manifest`), not a framework library | same — CLI-owned |
| `-svc` lifecycle | `Sol_svc.Service.Make` (`service.ml`) | `@sol-fab/svc` `runService` + Fastify/Express |
| `-worker` lifecycle | `Sol_worker.Worker.Make` (`worker.ml`) | `@sol-fab/worker` `runWorker` + `kafkajs` |
| `-fn` lifecycle | `Sol_fn.Fn.Make` (`fn.ml`) | none |
| Kafka wire format | `Kafka_service.Confluent_wire` | `@sol-fab/kafka` `encodeWire`/`decodeWire` |
| Schema registry | `Kafka_service_schema` + `Contract.projection` | `@sol-fab/kafka` `registerSchema`/`registerTopic` |
| Partitioning and key | `Kafka_service.MESSAGE` (`partitions`, `key`) | `@sol-fab/kafka` `TopicContract`/`registerTopic`/`publish` |
| DLQ | `Kafka_service_dlq` | `@sol-fab/kafka` `retry.ts`/`routing.ts` |
| Trace propagation | `Sol_obs`, `Kafka_service` | `@sol-fab/obs` `traceparentOf`/`extractTraceparent` |
| Metric names and labels | `worker.ml`, `service.ml`, `fn.ml`, `sol_jobs.ml` | `@sol-fab/obs` constants/helpers |
| Semantic workload identity | `Sol_obs.of_env` / `Sol_obs.taxonomy` | `@sol-fab/obs` `workloadIdentity`/`resourceAttributes` + `makeLokiPusher` |
| Config and secrets | `Kafka_service.config_of_env`, `Sol_obs.of_env` | none (apps read env directly) |
| Job semantics | `Sol_jobs` | none |
| Transactional publication | `Sol_outbox` | `@sol-fab/outbox` (`publish`, `runRelay`) |
| Auth | `Sol_svc.Auth`, `Route` DSL | none |
| Synchronous peer calls | `Sol_svc.Peer`, `sol.toml` `calls` | none |
| Env access | `Sol_env`, `Sol_runtime` | `process.env` (names are the contract) |

## 2. Verdicts

One verdict per capability, from {implemented, already equivalent, intentionally
deferred, not applicable}. A row with no verdict is the failure DEC-022 names.
"Gap" rows name the ticket that owns the alignment.

| # | Capability | OCaml behaviour | TypeScript behaviour | Verdict |
|---|---|---|---|---|
| 1 | Discovery / build | CLI-owned, language-neutral | CLI-owned | already equivalent |
| 2 | `-svc` lifecycle | `PORT`, `GET /healthz`, `GET /readyz` (503 once stop begins), `?shutdown_delay_s` (5 s) then a bounded `?drain_timeout_s` drain (`service.ml:106-125,339-340,468-482`) | `runService` installs an idempotent signal path and a bounded drain; **no `/readyz`, no shutdown delay** (`packages/svc/src/index.ts:44-105`) | gap — FEAT-096 |
| 3 | `-worker` lifecycle | `run` owns create→register→consume; `?on_ready` fires at partition assignment; `?stop`; clean drain (`worker.mli:28-53`) | `runWorker` installs an unbounded drain and hooks; **no `on_ready`** (`packages/worker/src/index.ts:38-70`) | gap — FEAT-102 (trigger 1) |
| 4 | `-fn` lifecycle | `Fn.Make` contract: exit codes 0/1/130, Pushgateway push, metrics (`fn.ml`) | none | intentionally deferred — FEAT-084/FEAT-082 |
| 5 | Confluent wire format | magic `0x00` + BE u32 id + JSON | `encodeWire`/`decodeWire` byte-compatible (`wireFormat.ts`) | implemented |
| 6 | Schema registry | `register_contract` sets `FULL` compatibility **then** registers, **both failures fatal** (`kafka_service_schema.ml:143-149`); registration is a deployment step, runtimes read only; the projection is the language-neutral object emitted by the workspace's `contract/run` | `registerContract` sets `FULL` **then** registers, both fatal; `connectTopic` provisions the topic and resolves the registered id read-only, failing an unregistered contract (`register.ts`); `contractProjection`/`runContractCli` emit the same object and implement `--json`/`--check`/`--apply` (`projection.ts`) | implemented — FEAT-119 (2026-10-02) |
| 7 | Partitioning and key | `MESSAGE.partitions`/`key`; create at declared count, never reduce | `TopicContract`; `registerTopic` refuses a reduction, `publish` keys the record (FEAT-117 part B) | implemented |
| 8 | Worker outcome vocabulary | exactly `Ack \| Fail`; `Fail` leaves the offset uncommitted and stops the consumer (`worker.mli:1-9`) | `Ack \| Fail`; `fail(reason)` throws `MessageFailError` and `wireCrashListener` stops the consumer and exits 0 (`outcome.ts`, `consume.ts`) | implemented — FEAT-118 (2026-10-02) |
| 9 | DLQ naming | `<source>.<canonical-group>.dlq`, `canonical-group` = sanitized id **always** suffixed with `-` + 12 hex of MD5 (`kafka_service_dlq.ml:29-57`) | `<source>.<canonical-group>.dlq`, `canonical-group` = sanitized id **always** suffixed with `-` + 12 hex of MD5 (`dlq.ts`) | implemented — BUG-117 (2026-10-02) |
| 10 | Trace propagation | W3C `traceparent` in HTTP + Kafka headers, out on peer calls and produced messages | `traceparentOf`/`extractTraceparent` (spec-correct flags); re-exported through `@sol-fab/kafka` | implemented (FEAT-038) |
| 11 | Worker metric vocabulary | `sol_worker_messages_total{status}`: exactly `ok`, `fail`, `ack_failed`; decode failures on `sol_worker_decode_errors_total` (`worker.ml:63-65,151-156,214`) | `WorkerMessageStatus` is exactly `ok \| fail \| ack_failed`; decode failures stay on `sol_worker_decode_errors_total` (`metrics.ts`) | implemented — FEAT-118 (2026-10-02) |
| 12 | svc metric vocabulary | `sol_svc_requests_total{method,route,status_class}`, `sol_svc_request_duration_seconds{method,route}` (`service.ml:363-368`) | `@sol-fab/obs` constants + `httpMethodLabel`/`statusClassOf`/`routeLabel` match | implemented |
| 13 | Config | `config_of_env` requires `KAFKA_BROKERS`, `SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL`, `KAFKA_SECURITY_PROTOCOL`, validates `SOL_KAFKA_DURABILITY` (`kafka_service_config.ml`) | `kafkaConfigFromEnv` requires `KAFKA_BROKERS` and `KAFKA_SECURITY_PROTOCOL`, maps the TLS/SASL variables (FEAT-097); the rest is recorded in § 4.4 | partial — FEAT-097 (2026-10-02) |
| 14 | Secrets | `Sol_obs.of_env` reads `LOKI_URL`/`TEMPO_URL`; stdout always; `?context` keys promoted to Loki stream labels; async export + `flush` (`sol-obs.md:77-85`) | `makeLokiPusher({ lokiUrl?, service, labels? })` logs to the console always, carries context-derived stream labels, and exposes `flush()` (`loki.ts`) | implemented — FEAT-099 + FEAT-125 (2026-10-02) |
| 15 | Job semantics | `Sol_jobs` (`FOR UPDATE SKIP LOCKED`, lease, fenced finalize, dedupe) | `@sol-fab/jobs`: transactional, dedupe-keyed `enqueue` plus a leased `runJobs` runner (`packages/jobs`) | implemented — FEAT-126 (2026-10-02) |
| 16 | Transactional outbox | `Sol_outbox` (FEAT-111; proven by VERIF-001) | `@sol-fab/outbox@0.1.0` (`packages/outbox`: transactional `publish`, per-key `runRelay`, `sol_outbox_*` metric names), wired into the golden path | implemented — FEAT-124 (2026-10-02): `0.1.0` is published (bootstrap; `loganbnielsen/sol-typescript#8`, `c1ea404`) with its OIDC trusted publisher configured, and `examples/pluto/app/demo_ts/fulfillment_worker` composes the domain write, the `send_confirmation` job and the intent in one transaction and hosts the relay; `test/outbox.test.ts` covers the composition, rollback, per-key order and the blocked-key boundary against Postgres, and a live run published keyed schema-encoded facts to Redpanda in `ord` order. Both languages gate the job and the intent on the domain insert actually applying (the OCaml `notify_worker` uses `INSERT … ON CONFLICT DO NOTHING RETURNING charge_id`), so a redelivered fact is a no-op in either rather than a second `(key, ord)` collision |
| 17 | Auth | `Auth` levels (`Public`/`Api_key`/`Jwt` with scopes) declared per route via `Route`; principal in `Request.t.auth` | none — left to the app's Fastify/Express plugins | intentionally deferred — trigger: the first TypeScript app that needs Sol-declared auth (see § 5) |
| 18 | Synchronous peer calls | `Peer.url`/`Peer.headers` (`x-api-key` + `traceparent`), `sol.toml` `calls` opens the NetworkPolicy pair | none | intentionally deferred — trigger: the first TypeScript app that declares a `calls` edge |
| 19 | Env access | `Sol_env.timed`, `Sol_runtime.setting` | `process.env`; the variable **names** are the contract | already equivalent |
| 20 | Consumer idempotency (duplicate delivery) | A unique key plus `ON CONFLICT DO NOTHING` on the consumer's domain write, and a dedupe-keyed job for the follow-up effect (`BUG-112` in `notify_worker`) | Same: `fulfilled_orders_ts` primary key + `ON CONFLICT DO NOTHING`, and a `send_confirmation` job dedupe-keyed by the order id | implemented — FEAT-123 (2026-10-02), tested in `demo_ts/test/delivery.test.ts` |
| 21 | Semantic workload identity | `Sol_obs.of_env` reads the six `SOL_*` variables the manifest injects and composes them into the Loki stream labels and the OTLP resource attributes, `SOL_SERVICE` (the workload's bare Kubernetes name) winning over the passed `~service` (`sol_obs.ml:29-89`) | `@sol-fab/obs@0.4.0` `workloadIdentity`/`resourceAttributes` read the same six and `makeLokiPusher` composes them into the stream labels, injected values winning over caller labels; the `demo_ts` units build their OTLP resource from `resourceAttributes(...)` | implemented — OBS-051 (2026-10-03): `v0.4.0` published through the OIDC/`provenance` workflow (`loganbnielsen/sol-obs#9`), the TypeScript golden-path smoke asserts each trace's `service.name` is the Sol name (`order-svc`) and that its resource carries every identity label the pod injects, and `check_platform_component_drift.py` guards the TypeScript side |

## 3. Findings filed

### BUG-117 — `@sol-fab/kafka` dead-letters to a different topic than an OCaml worker on the same group

**Observed, high.** The canonical-group rule differs, so the two languages never
produce the same DLQ topic from the same source topic and group:

- OCaml (`framework/ocaml/kafka-eio-service/lib/kafka_service_dlq.ml:29-57`)
  **always** appends `-` + the first 12 hex of MD5 of the original group id, on
  every id, and truncates the readable prefix to 51 chars when needed.
- TypeScript (`sol-kafka@3956fea`, `src/retry.ts:111-117`) appends a hash **only
  when the sanitized id exceeds 64 chars**, and then the first **8** hex.

Observed names (`md5sum` for the OCaml hash, the package's own `canonicalGroupSegment`
for the TypeScript one; full commands in § *Verification*):

| group id | OCaml DLQ topic | TypeScript DLQ topic |
|---|---|---|
| `payments` | `orders.payments-84d5eaf713c9.dlq` | `orders.payments.dlq` |
| `sol-demo-ts-fulfillment-worker` | `orders.sol-demo-ts-fulfillment-worker-a239c8cce37d.dlq` | `orders.sol-demo-ts-fulfillment-worker.dlq` |

The convention is explicit (`framework-conventions.md` § DLQ: "sanitized to
`[A-Za-z0-9-]` followed by a short hash of the *original* id (BUG-080)"), and the
OCaml test suite pins it (`test_kafka_service.ml:332-360`). The TypeScript test
that claims to check it asserts the divergent values —
`test/retry.test.ts:64-67` is titled "match the OCaml naming" and asserts
`relayTopicName("orders", "payments", "dlq") === "orders.payments.dlq"`.

Impact is cross-language interop: a TypeScript worker's undecodable records and
an OCaml worker's on the same logical consumer group land in different topics,
so a DLQ reader watching the contract name sees only one of them. The rule
survives FEAT-118 (only DLQ publication remains after the retry relay is
removed), so it is filed separately rather than folded into the outcome
alignment. Filed as `BUG-117` (BACKLOG, parity stream).

### FEAT-125 — `@sol-fab/obs`'s Loki façade does not match `Sol_obs` on labels or delivery

**Observed, medium.** Two behavioural differences beyond FEAT-099's console
copy (`sol-obs.md:77-85`; `sol-obs@13128e6`, `src/loki.ts:16-48`):

1. **Stream labels.** `Sol_obs.of_env ?context` promotes every context key
   (team/domain/env) to a Loki **stream label**. `makeLokiPusher` hard-codes
   `stream: { service }`, so an OCaml and a TypeScript workload in the same
   workspace produce differently-labelled streams and a label-scoped dashboard
   or alert matches only one of them.
2. **Delivery.** OCaml (OBS-048 part B) exports asynchronously on the switch and
   calls `flush` when `run` returns, so a slow or unreachable Loki never blocks a
   log call and queued lines are sent at a known point. TypeScript issues one
   fire-and-forget `fetch` per line with no flush, so lines still in flight at
   process exit are lost — the same gap FEAT-099 names for the console copy, on
   the delivery side.

Filed as `FEAT-125` (BACKLOG, parity stream). Related to, not a dependency of,
FEAT-099.

## 4. Divergences already owned by an existing ticket

These are real and recorded here so the inventory is complete, but they already
have a ticket and are not re-filed.

1. **Worker outcome, retry/DLQ topology and metric vocabulary.** OCaml is
   `Ack | Fail` with retry and application-level dead-lettering removed
   (FEAT-113); TypeScript still ships `Ack | Retry | Dead_letter`, a retry
   policy, a relay, and the matching seven-value `WorkerMessageStatus`
   (`outcome.ts`, `retryable.ts`, `relay.ts`; `metrics.ts:42-49`). Owned by
   **FEAT-118**. The `@sol-fab/obs` vocabulary comment (`metrics.ts:31-40`)
   still describes the pre-FEAT-113 contract and must be rewritten with it.
2. **`-svc` readiness.** OCaml turns `/readyz` 503 and keeps serving for
   `shutdown_delay_s` before it stops accepting and drains; `@sol-fab/svc` has
   no `/readyz` and no shutdown delay. Owned by **FEAT-096**; the TS manifest
   exception in `Sol_cli_deployment_render` is its other half.
3. **Kafka transport posture.** `Kafka_service.config_of_env` requires
   `KAFKA_SECURITY_PROTOCOL`; no TypeScript package reads it, so a TypeScript
   workload would stay plaintext under a `sasl_ssl` manifest. Owned by
   **FEAT-097**. **Note for that ticket:** the same helper should cover the
   other required names `config_of_env` enforces (`KAFKA_BROKERS`,
   `SCHEMA_REGISTRY_URL`, `REDPANDA_ADMIN_URL`) and reject an unknown
   `SOL_KAFKA_DURABILITY`, not only the security variables.
4. **Schema registration ordering and fatality.** Current OCaml
   `register_contract` sets `FULL` compatibility **before** registering and
   treats either failure as fatal (`kafka_service_schema.ml:143-149`); the
   TypeScript `registerTopic` did the reverse and swallowed the compatibility
   failure (`register.ts:66-72`). Registration is now a deployment step
   (BUG-105), and **FEAT-119 resolved this (2026-10-02)**: `registerTopic` is
   replaced by `registerContract` (set `FULL` first, then register, both fatal),
   the runtime `connectTopic` is read-only, and both languages emit the same
   projection object from a `contract/run` entry point.
5. **Duplicate delivery, outbox and jobs.** Resolved. FEAT-123 (idempotent
   redelivery), FEAT-118 (`Ack | Fail`), FEAT-126 (`@sol-fab/jobs`) and FEAT-124
   (`@sol-fab/outbox@0.1.0`) are implemented, and the TypeScript golden path
   composes the domain write, the job and the outbox intent and hosts the relay
   (see row 16).

## 5. Recorded, not raced — the secrets/identity workstream

DEC-029 (secret authority and runtime delivery), DEC-062 (workload cloud
authorization) and DEC-063 (Sol-to-Sol identity) are resolving the
application-facing secret and identity contract now. Their implementation
branches (`DEC-029/secret-authority-properties`,
`DEC-062/authorization-lifecycle`, `DEC-062/safe-grant-set`, PR #886) are open,
and DEC-029 § *Four layers* fixes only the shape (`Secret.get "stripe"`, layered
declaration → authority → projection → consumption), not the final API.

This audit therefore **records** the secret/identity rows and files nothing
against them:

- The portable consumption contract is `Secret.get` in both languages
  (DEC-029 layer 4). No TypeScript `@sol-fab` secret-consumption surface exists
  yet, and one is owed — but it must implement the **stabilised** DEC-029
  contract, not a snapshot taken while the decision is in flight.
- `KAFKA_SECURITY_PROTOCOL` (SEC-007) is the one secret-adjacent item already
  settled and is tracked by FEAT-097 (§ 4.3). It is not in flux.
- The identity rows (`DEC-062`, `DEC-063`) change operator and workload-pod
  wiring, not an app-author API, so they add no new cross-language gap: the
  application contract stays "the framework obtains the credential and hands it
  to `Secret.get`". Re-check this row when DEC-029's implementation lands, not
  before.

The per-language verdicts for secrets/identity are deliberately left at
"recorded — in flux" rather than assigned a verdict this audit would then have
to retract. That is the one place the inventory is intentionally incomplete, and
it is named here so it is not read as silence.

## 6. Existing-ticket reconciliation

- **FEAT-095 is stale and is withdrawn.** It asks for `dead_letter` and
  `relay_failed` statuses "the starter alerts read", on the premise that OCaml
  `sol_worker` emits them. FEAT-113 removed `Dead_letter` and the relay from
  OCaml; `worker.ml` now emits only `ok`/`fail`/`ack_failed`, and
  `rg -n 'dead_letter|relay_failed' platform/ docs/ cli/` matches nothing (the
  OBS-047 alerts themselves are gone). The correct ticket is FEAT-118, which
  takes the vocabulary to `Ack | Fail`. FEAT-095 carries a withdrawal note.
- **FEAT-037's premise is stale.** Its Problem section quotes
  `kafka_service.ml`'s `register` as "`register_schema` first and fatal,
  `set_subject_compatibility` second and non-fatal". BUG-105/FEAT-119 moved
  registration into the deployment step and inverted both properties:
  `register_contract` sets compatibility first, and either failure is fatal.
  The extraction ticket's *goal* still stands; the quoted ordering does not.
  FEAT-037 carries a correction note.

## 7. Verification of this audit

Sibling repositories at the versions in § *Method*, read through `git show`
because the local worktree copies were stale:

```text
$ git -C ~/Code/sol-kafka show origin/main:src/retry.ts | rg -n 'canonicalGroupSegment|hashSuffix|MAX_GROUP_SEGMENT_LEN'
97:export const MAX_GROUP_SEGMENT_LEN = 64;
111:export function canonicalGroupSegment(groupId: string): string {
113:  if (sanitized.length <= MAX_GROUP_SEGMENT_LEN) return sanitized;
114:  const hashSuffix = createHash("md5").update(groupId).digest("hex").slice(0, 8);
115:  const prefixLen = MAX_GROUP_SEGMENT_LEN - hashSuffix.length - 1;
116:  return `${sanitized.slice(0, prefixLen)}-${hashSuffix}`;
```

```text
$ git -C ~/Code/sol-kafka show origin/main:test/retry.test.ts | sed -n '64,67p'
test("relayTopicName / retryConsumerGroupId match the OCaml naming", () => {
  assert.equal(relayTopicName("orders", "payments", "retry"), "orders.payments.retry");
  assert.equal(relayTopicName("orders", "payments", "dlq"), "orders.payments.dlq");
  assert.equal(relayTopicName("orders", "orders.worker", "retry"), "orders.orders-worker.retry");
```

```text
$ git -C ~/Code/sol-kafka show origin/main:src/register.ts | rg -n 'registerSchema|setSubjectCompatibility'
66:  const schemaId = await registerSchema(opts.registryUrl, contract.name, contract.schema);
69:    await setSubjectCompatibility(opts.registryUrl, contract.name);
```

```text
$ sed -n '143,149p' framework/ocaml/kafka-eio-service/lib/kafka_service_schema.ml
let register_contract net ~clock ~registry_url ~topic_name ~schema =
  let open Result.Syntax in
  let* () = set_subject_compatibility net ~clock ~registry_url ~topic_name in
  register_schema net ~clock ~registry_url ~topic_name ~schema
;;
```

The DLQ names in § 3 were computed from the two rules directly, not inferred:

```text
$ for g in payments sol-demo-ts-fulfillment-worker; do \
    h=$(printf '%s' "$g" | md5sum | cut -c1-12); \
    s=$(printf '%s' "$g" | tr -c 'a-zA-Z0-9-' '-'); \
    printf '%s -> OCaml orders.%s-%s.dlq | TS orders.%s.dlq\n' "$g" "$s" "$h" "$s"; done
payments -> OCaml orders.payments-84d5eaf713c9.dlq | TS orders.payments.dlq
sol-demo-ts-fulfillment-worker -> OCaml orders.sol-demo-ts-fulfillment-worker-a239c8cce37d.dlq | TS orders.sol-demo-ts-fulfillment-worker.dlq
```

Positive control for the "OCaml emits no `dead_letter`/`relay_failed`" claim in
§ 6: the same statuses are present in the TypeScript vocabulary the audit points
at, so the search matches when a value exists:

```text
$ rg -n 'dead_letter|relay_failed' framework/ platform/ docs/ cli/
(no matches)
$ git -C ~/Code/sol-obs show origin/main:src/metrics.ts | rg -n 'dead_letter|relay_failed'
46:  | "dead_letter"
49:  | "relay_failed";
```

## Non-goals

- Does not change any convention, package, or contract defined here; the two
  findings are filed for their own tickets.
- Does not re-run the `demo_ts` golden path or start a broker; this is a
  source-level comparison.
- Does not touch DEC-029/DEC-062/DEC-063 or their implementation branches
  (§ 5).
