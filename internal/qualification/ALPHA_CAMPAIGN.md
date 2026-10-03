# Alpha reference-application & live-qualification campaign

**As of:** 2026-10-03 · **Base revision:** `origin/main @ cacc48f9`
**Owner:** the campaign lead (this artifact); each row/stream has its own owner.
**Status:** Phase 1 — established; implementation streams not yet started.

This is the canonical coordination artifact for the alpha campaign. It answers one
question:

> Does the complete Sol product, as currently specified, work coherently for a new
> user on real supported infrastructure?

It is the *coordination* layer: the surface under test, one reference scenario, the
acceptance matrix that maps every supported capability to its evidence, the clean-user
starting condition, the ownership boundaries, and the operator gates. It does not
replace the executable contracts it references — the AWS matrix, the GCP matrix and
the observability matrix stay authoritative for their own rows, and tickets stay
authoritative for their own work.

**The surface is frozen for this campaign.** A feature deliberately deferred during
pre-alpha adjudication (`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`)
is not an alpha requirement because it remains in the backlog. New product features
are not added to make the demonstration richer; a gap in the frozen contract is
recorded as a gap.

## How to read the acceptance matrix

- **Row** — the campaign's own stable id (`A1`, `B4`, …), grouped by capability area.
- **Observable behaviour** — what a user or an independent inspector can see.
- **OCaml / TS evidence** — where the per-language observation is produced or recorded.
- **Shared / substrate evidence** — the language-neutral or infrastructure observation.
- **Target(s)** — where the row must be observed: `local` (k3d/this host),
  `aws`, `gcp`, `clean` (no-checkout install).
- **Existing obligation** — the ticket or qualification row this row is satisfied by,
  so evidence is not duplicated and status is reconciled in one place.
- **Status** — exactly one of `PASS` / `FAIL` / `NOT RUN` / `N/A` / `BLOCKED`.
  `PASS` carries its evidence class in parentheses: `(OFFLINE)` (static, mechanism or
  CI), `(LOCAL)` (real backends on this host, no Kubernetes), `(LIVE)` (a real
  deployed target).

**Evidence discipline (unchanged from the ledger, and binding here).**

1. A unit/integration test establishes a prerequisite, never a live row. Rows whose
   claim is about a deployed target stay `NOT RUN` until observed there.
2. `STATIC` / `MECHANISM` / `BEHAVIORAL` (and `MODELED` / `LOCAL` / `LIVE`) are not
   interchangeable; nothing is promoted to make a row look green.
3. `ABSENT` must be positively established. `UNKNOWN`, a timeout, an auth failure, a
   malformed response or an unavailable API is never read as `ABSENT` or success.
4. Application output alone does not establish an infrastructure claim; the
   authoritative boundary is inspected independently (provider API, Kubernetes,
   PostgreSQL, broker/registry, telemetry backend, durable release metadata).
5. Never weaken an acceptance criterion to accommodate an implementation failure —
   file the defect, fix it if bounded and unowned, test the failure mechanism, merge,
   rerun the affected rows.

## 1. The alpha surface being qualified

The frozen feature set, grouped by what it lets an app author do. Everything here is
already implemented or intentionally supported on `origin/main`; the campaign
establishes that it works coherently, not that it exists.

**Entry and declaration**

- `sol new workspace` / `sol new svc|worker|fn|event` (OCaml scaffold), and `sol check`
  validating a declaration without a cluster.
- One canonical declarative contract per scope (`events/<team>/sol.toml`) with
  `sol contract generate` writing checked-in, drift-checked bindings for OCaml and
  TypeScript (FEAT-116, FEAT-129, DEC-065).
- `sol plan` and `sol deploy <env>/<provider>/<region>` reading the declaration and the
  target, with the production-profile preflight (FEAT-089, FEAT-116, FEAT-130).

**Runtime primitives and data**

- `-svc` (HTTP routes with declared auth), `-worker` (Kafka consumer with an explicit
  `Ack | Fail` outcome contract — FEAT-113/118), `-fn` (cron), and `sol-jobs` hosted by
  a worker.
- PostgreSQL via `pg-eio`, migrations applied by `sol migrate`, per-migration checksums
  and the deploy's `required ⊆ applied` gate (AUDIT-069, FEAT-094).
- Transactional outbox (`sol_outbox`), durable leased jobs (`sol_jobs`), and their
  TypeScript counterparts (`@sol-fab/outbox`, `@sol-fab/jobs`).

**Messaging**

- Redpanda/Kafka, schema registry, Confluent wire format, declared partitions and
  message keys, retry/DLQ topics with `X-Sol-Retry-At`, decode-error DLQ routing.

**Security**

- `KAFKA_SECURITY_PROTOCOL` required everywhere; local plaintext; the production
  profile's SASL_SSL transport (FEAT-093, SEC-007).
- Runtime secret delivery (`sol secret set`, `<service>-secrets`), and the DEC-029
  projection mechanism on `byo` (Kubernetes Secrets by default).
- Scoped provisioning/cluster-access/deploy/operator identities, effective-surface
  revocation, and the DEC-062 `sol grants` workload-authority lifecycle.

**Deployment and release**

- Immutable artifact digests, the durable release record and pointer, `sol rollback`,
  retention, GitOps emit, and the observed → desired contract change (FEAT-110,
  FEAT-130).
- The released install: `sol-<version>-linux-x86_64.tar.gz` (binary + platform bundle)
  plus the version-aligned migration-runner image (DEC-049, FEAT-101).

**Observability and operations**

- Logs, metrics and traces carrying Sol's six semantic identity dimensions
  (`workspace`, `env`, `domain`, `service`, `primitive`, `release`) — DEC-064.
- Grafana dashboards and `sol open`, `sol status`, `sol logs`, `sol check`; the
  observability block's `UNKNOWN` for an unanswerable read.
- The alert rule set, the `sol alert test` delivery route, and the DLQ/decode alerts.

**Lifecycle**

- `sol cloud bootstrap/apply/destroy`, `sol uninstall`, retention, and the independent
  absence verification (DEC-045, DEC-048), from every infrastructure-holding state.

### Deliberately not in the alpha surface (recorded, not omitted)

| Excluded | Why |
|---|---|
| `sol new --language typescript` (FEAT-084) | Real gap, not alpha: the TS reference app is hand-authored; the golden-path scaffold is post-alpha DX. |
| TypeScript under the production profile (FEAT-102) | DEC-026 §2 staged it behind an external `@sol-fab/worker` readiness hook; the alpha TS claim is local + the reference scenario, not the production profile. |
| GCP under the production profile | No production profile is selected for GCP rows (`production_qualified = false`); GCP is qualified as a provider lifecycle, not as a profile claim. |
| Public-opam distribution (RELEASE-005) | Deferred against its trigger; the workspace-owned immutable pins are the interim. |
| `self_hosted_durable` / `external` observability backends (OB-R2/R3) | AWS-only or endpoint-gated; recorded `BLOCKED`, not qualified by omission. |
| `byo` cheap-provider recipe (INFRA-014) | Supported substrate, unqualified; a separate live run, not an alpha gate. |
| Analytics/cache/edge surfaces (FEAT-043/044/048), admission control (SEC-005), `-fn` capacity isolation (INFRA-015) | Out of the alpha by adjudication, each with its own reconsideration trigger. |
| Delivered-and-acknowledged alert (AWS G2) | Needs a named owner who can acknowledge; operator-gated, never substituted by a local sink. |

## 2. The reference application scenario

One realistic backend workflow, implemented independently in OCaml and TypeScript with
**equivalent externally observable behaviour** (not source-level API symmetry). It
exercises the supported primitives together rather than as disconnected endpoints.

**Scenario: "Pluto orders".**

```
client
  │  POST /orders {order_id, item, quantity}
  ▼
orders_svc  (-svc)
  │  BEGIN
  │    INSERT orders        (order_id PK, item, quantity, status)   ON CONFLICT DO NOTHING
  │    INSERT sol_jobs      (kind = send_confirmation, dedupe_key = order_id)
  │    INSERT sol_outbox    (kind = OrderPlaced, key = order_id, ord = 1)
  │  COMMIT
  │  outbox relay  ──►  Kafka topic  orders.v1            (3 partitions, key = order_id)
  ▼
fulfilment_worker  (-worker)
  │  consume OrderPlaced
  │  BEGIN
  │    INSERT fulfilled_orders (order_id PK, item, quantity, status) ON CONFLICT DO NOTHING
  │    INSERT sol_jobs       (kind = release_inventory, dedupe_key = order_id)
  │    INSERT sol_outbox     (kind = OrderFulfilled, key = order_id, ord = 1)
  │  COMMIT
  │  ack
  │  outbox relay  ──►  Kafka topic  orders-fulfilled.v1   (3 partitions, key = order_id)
  ▼
downstream behaviour
  • the job runner executes send_confirmation (writes the confirmation effect)
  • GET /orders/{order_id} reads fulfilment back:  accepted → fulfilled → confirmed
```

**Observable contract (identical in both languages):**

| Aspect | Contract |
|---|---|
| HTTP | `POST /orders` → `202 {order_id, status}`; `GET /orders/{order_id}` → `200`/`404`; duplicate `POST` is idempotent |
| Events | `OrderPlaced`, `OrderFulfilled`; declared in `events/<scope>/sol.toml`; 3 partitions; key `order_id` |
| Atomicity | domain row + job + outbox intent commit or roll back together; the relay removes a row only after the broker acknowledged it |
| Duplicate delivery | absorbed at every effect (row `ON CONFLICT`, job dedupe key, outbox unique `(key, ord)`), so one fact yields one row, one job, one intent, one effect |
| Failure | an undecodable record yields the structured decode log, `sol_worker_decode_errors_total`, and a DLQ record on `<topic>.<group>.dlq` with the raw bytes; `Dead_letter` fails closed with no DLQ |
| Identity | every log, metric and trace carries the six dimensions; one request's three signals agree |
| Lifecycle | deploy, idempotent re-deploy, failed deploy not advancing the pointer, rollback, recovery, destroy to verified absence |

**Two namespaces, one scenario.** The OCaml and TS implementations are independent
deployments: separate domains, topics, tables and job kinds (e.g. `orders` vs
`orders_ts`), each inside the one `examples/pluto` workspace, so both can run side by
side. The declarative event declarations are the same two events with the same
schema — the cross-language contract row (`B7`) checks that, it does not require
shared topics.

The scenario is defined by ticket `FEAT-131` (the shared contract) and implemented by
`FEAT-132` (OCaml) and `FEAT-133` (TypeScript).

## 3. Acceptance matrix

Legend: `local` = this host / k3d; `aws` / `gcp` = a real cloud target; `clean` = a
machine with only the released bundle and no checkout.

### A. New-user entry, install and scaffold

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| A1 | Released install | download `sol-<version>-linux-x86_64.tar.gz`, `sol assets` reports every asset present; no `SOL_HOME`, no checkout | — | — | release archive; `sol assets` | clean | FEAT-101 (DONE), `RELEASE-006` | NOT RUN (no release since `v0.1.0-alpha.6`, 2026-06-11) |
| A2 | OCaml workspace scaffold | `sol new workspace` builds first try | scaffolded workspace `dune build` | — | CLI | local, clean | DOGFOOD-001, FEAT-085 | PASS (OFFLINE) |
| A3 | Unit scaffold | `sol new svc/worker/fn/event` adds units the workspace builds | scaffolded units | — | CLI | local | ROADMAP Phase 5 | PASS (OFFLINE) |
| A4 | TypeScript unit scaffold | — | — | — | — | — | FEAT-084 | N/A (deferred; TS app is hand-authored) |
| A5 | `sol check` without a cluster | valid workspace `ok`; failed check non-zero; unreadable declaration diagnosed | workspace | TS units are ordinary units | CLI | local | OB-S5, BUG-124 (DONE) | PASS (LOCAL) |

### B. Reference scenario behaviour

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| B1 | Service accepts a request | `POST /orders` → `202`; duplicate is idempotent | `orders_svc` | `order_svc` | HTTP probe | local, aws, gcp | FEAT-131/132/133 | NOT RUN (unified scenario); TS demo PASS (LOCAL) |
| B2 | Request transaction | domain row + job + outbox commit or roll back together | new `orders_svc` tx | new `orders_svc` tx | Postgres inspection | local | FEAT-111/120/124 | NOT RUN (the service-side tx is the scenario's new work in both languages; the existing worker-side tx is B4) |
| B3 | Outbox relay | fact published only after the domain commit, in `ord` order, removed only after broker ack | `Notification_sent_outbox.relay` | `runRelay` | Kafka topic inspection | local, aws, gcp | FEAT-120, FEAT-124 | PASS (LOCAL, worker-side in both) |
| B4 | Worker consumes and mutates | `OrderPlaced` → one `fulfilled_orders` row + job + outbox intent | `notify_worker` | `fulfillment_worker` | Postgres + broker | local, aws, gcp | FEAT-120, FEAT-124 | PASS (LOCAL) |
| B5 | Downstream behaviour | job runner executes the confirmation; read-back reflects `fulfilled`/`confirmed` | `Sol_jobs` runner | `@sol-fab/jobs` runner | HTTP read-back, DB | local | FEAT-077, FEAT-111 | NOT RUN |
| B6 | Duplicate delivery absorbed | one fact yields exactly one row/job/intent/effect | `~dedupe_key` (BUG-112 guard) | `ON CONFLICT` + dedupe (`delivery.test.ts`) | DB row counts | local | BUG-112, FEAT-124 | PASS (LOCAL, TS); partial (OCaml) |
| B7 | Cross-language contract equivalence | the two declarative scopes declare the same schema; both bindings generate and drift-check | generated OCaml binding | generated TS binding | `sol contract generate --check` | clean | FEAT-116/129, DEC-065, FEAT-131 | NOT RUN (the two scopes declare different events today; the generate/drift mechanism is PASS OFFLINE) |
| B8 | Cross-language wire interop | a fact produced by one language is consumed by the other's worker | producer | consumer | broker | local | DEC-022 (stretch; not an alpha requirement) | NOT RUN |

### C. Data: PostgreSQL, migrations, jobs, outbox

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| C1 | Migrations apply | `sol migrate apply` reaches `Done.`; the runner image is digest-pinned | workspace migrations | TS scenario migrations | `schema_migrations`, Job logs | local, aws, gcp | matrix C, SEC-011, Run 7 | PASS (LIVE, AWS Run 7); NOT RUN (local/GCP campaign) |
| C2 | Deploy migration gate | `required ⊆ applied` verified before any mutation; a missing required migration fails closed | deploy gate | deploy gate | Job logs, `schema_migrations` | aws, gcp | matrix C1–C5, AUDIT-069 | PASS (OFFLINE); LIVE partial |
| C3 | Per-migration checksum | an edited applied migration fails the gate / `sol migrate status` reports it | `sol-jobs`/migrate CLI | migrate CLI | `schema_migrations` | local, aws | FEAT-094 (DONE) | PASS (OFFLINE); NOT RUN (LIVE) |
| C4 | Postgres durability (AWS) | Multi-AZ; failover RTO ≤ 120 s, RPO ≈ 0; PITR RPO ≤ 300 s | — | — | `aws rds describe-*` | aws | matrix E1–E4 | NOT RUN |
| C5 | Durable leased jobs | claim-by-kind, attempt-fenced finalize, retry; no lost job | `Sol_jobs` | `@sol-fab/jobs` | Postgres | local, aws | FEAT-077, FEAT-114, BUG-044/050 | PASS (LOCAL) |
| C6 | Transactional outbox | no fact lost, none duplicated, ordering per key | `Sol_outbox` | `@sol-fab/outbox` | Postgres + broker | local, aws | FEAT-111/120/124 | PASS (LOCAL); NOT RUN (LIVE) |

### D. Messaging and contracts

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| D1 | Topic provisioning | topic created at the declared partition count; reduction refused | `MESSAGE.partitions` | `TopicContract` | broker admin API | local, aws | BUG-099, FEAT-117 | PASS (OFFLINE/LOCAL) |
| D2 | Wire format + registration | Confluent framing; a service fails at startup if its contract is not registered | `Kafka_service.register` | `registerTopic` | schema registry | local | FEAT-034, BUG-105 | PASS (LOCAL) |
| D3 | Partitioning + key | same-key records consumed once, in order, by one member | declared key | `publish` key | broker | local | FEAT-117 | PASS (LOCAL) |
| D4 | Retry/DLQ topology | group-scoped `.retry`/`.dlq`, `X-Sol-Retry-At`, ack only after durable publish; `Dead_letter` fails closed | `kafka_service_retry_topics.ml` | `@sol-fab/kafka` (`FEAT-118`) | broker topics | local, aws | FEAT-076/078, FEAT-118 | PASS (LOCAL) |
| D5 | Decode-error DLQ | structured log + `sol_worker_decode_errors_total` + DLQ record with raw bytes; source offset advances | `worker.ml` | `@sol-fab/kafka` | broker + Loki | local, aws | OB-F2 | PASS (LOCAL); NOT RUN (LIVE) |
| D6 | Contract drift | `sol contract generate --check` fails on drift for both languages | generated binding | generated binding | CI guard | clean | FEAT-116/129 | PASS (OFFLINE) |
| D7 | Broker durability (AWS) | RF ≥ 3, `acks=all`, write caching off | — | — | topic/cluster describe | aws | matrix E7 | NOT RUN |
| D8 | Broker loss + resume | zero acknowledged-message loss; consumers resume ≤ 60 s | — | — | broker, lag samples | aws | matrix E5/E6 | NOT RUN |

### E. Security: transport, secrets, identity

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| E1 | Transport posture declared | absent `KAFKA_SECURITY_PROTOCOL` is an error; local sets `plaintext` | `config_of_env` | `@sol-fab/kafka` config | env/manifest | local | SEC-007 | PASS (LOCAL) |
| E2 | Production SASL_SSL | Redpanda TLS + SASL, projection, registry/admin HTTPS; a live workload connects over SASL_SSL | workload | workload | broker security config | aws | FEAT-093 (DONE) | PASS (OFFLINE); NOT RUN (LIVE) |
| E3 | Runtime secret delivery | the declared secret reaches the pod; `<service>-secrets` identity agrees | `sol secret set` | same CLI path | Kubernetes Secret, pod spec | local, byo | matrix F2, VERIF-020 | PASS (LOCAL, Vault mechanism); NOT RUN (LIVE) |
| E4 | Managed secret projection | rotation updates the mount within the stated bound; an ungranted identity is denied | — | — | provider + CSI driver | aws, gcp | VERIF-021 | BLOCKED (operator/live) |
| E5 | Projected SA tokens | caller `403`, no-token `401`, wrong-`aud` refused; no API access | caller/callee | caller/callee | cluster OIDC | aws, gcp, byo | VERIF-022, DEC-063 | BLOCKED (live) |
| E6 | Workload cloud authority | declared grant is effective before deploy; missing grant fails the deploy at plan time | `sol grants` | same CLI | provider IAM | aws, gcp | DEC-062, VERIF-021 | PASS (OFFLINE); NOT RUN (LIVE) |
| E7 | Scoped identities | provisioner/cluster-access/deploy/operator hold only their declared capabilities; revocation removes the effective surface | matrix I3/F5 | same | IAM + RBAC | aws, gcp | INV-AUTH-1..6, DEC-034 | PASS (LIVE, AWS partial); NOT RUN (GCP) |
| E8 | No ambient token / no leaked secret | `automountServiceAccountToken: false`; zero secret values in plan/record/log/bundle | — | — | manifests, redaction scan | aws | matrix F1/F4 | PASS (OFFLINE); NOT RUN (LIVE) |

### F. Deployment, release and provenance

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| F1 | Profile preflight | each unmet guarantee named before mutation; positive and negative cases | workspace | workspace | plan JSON | aws | matrix A1–A12 | PASS (LIVE, AWS Run 7); GCP partial |
| F2 | Provision + normal deploy | all workloads Ready; release + deployment event carry resolved digests and the profile version | workloads | TS workloads | `kubectl get`, release record | local, aws, gcp | matrix B1 | PASS (LIVE, GCP Attempt 28 no-profile; AWS workload running Run 8) — profile row NOT RUN |
| F3 | Idempotent re-deploy | no workload restarts; pointer unchanged | — | — | pod UID/restartCount | aws | matrix B2 | NOT RUN |
| F4 | Failed deploy + rollback | a failed deploy exits non-zero and does not advance the pointer; rollback restores the recorded digests and refuses an incompatible migration boundary | — | — | release record, `kubectl get` | aws | matrix B4–B6, `2026-10-02_rollback_fidelity_qualification.md` | NOT RUN |
| F5 | Drift detection | a mutated workload is reported and a re-deploy converges | — | — | deployment state | aws | matrix B7 | NOT RUN |
| F6 | Immutable artifacts | a tag reference is refused by the profile preflight; digests are verified in the registry | — | — | registry | aws | DEC-026 §6, SEC-011 | PASS (OFFLINE) |
| F7 | Release provenance | the durable release record is readable without Sol and identifies the artifact/contract | — | — | release store | aws | FEAT-110 (DONE), DEC-057 §9 | PASS (OFFLINE); LIVE partial |
| F8 | Observed → desired contract | a contract change is reported against the recorded deployed contract | — | — | release record | local, aws | FEAT-130 (DONE) | PASS (OFFLINE) |
| F9 | Plan reads the declaration | `sol plan` derives the declaration without parsing code | workspace | workspace | plan JSON | clean | FEAT-116, ADR 0005 | PASS (OFFLINE) |

### G. Observability and diagnostics

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| G1 | Logs by identity | `sol logs --scope domain/unit` returns exactly that unit's lines; every line carries the six dimensions | `Sol_obs` | `@sol-fab/obs` | Loki | local, aws | OB-L1/L3 | PASS (LOCAL); NOT RUN (deployed) |
| G2 | Metrics with taxonomy | `sol_svc_*`/`sol_worker_*` carry route/status labels; taxonomy labels on a real scrape | `service.ml`/`worker.ml` | `@sol-fab/obs` | Prometheus scrape | local, aws | OB-M1/M2 | PASS (LOCAL); NOT RUN (scraped series) |
| G3 | Trace propagation | one trace spans svc → Kafka → worker; log `trace_id` equals the trace id | `Sol_obs` | `@sol-fab/obs` | Tempo | local, aws | OB-T1/T2 | PASS (LOCAL); NOT RUN (deployed) |
| G4 | Trace taxonomy | a trace carries all six resource attributes and is selectable by each | — | `@sol-fab/obs` | Tempo | local, aws | OB-T3, DEC-064 | PASS (LOCAL); NOT RUN (deployed) |
| G5 | Dashboards + links | dashboards provision; `sol open <view>` links select the same labels; panel data under the scrape | — | — | Grafana | local, aws | OB-D1 | PASS (LOCAL definitions/proxy); panel data NOT RUN |
| G6 | `sol status` | workload health derived from Kubernetes; the observability block reports backend reachability | — | — | Kubernetes, backends | local, aws | OB-S1/S2, `DEC-052` | PASS (LOCAL, `UNKNOWN` path); LIVE NOT RUN |
| G7 | Diagnostic surfaces | `sol check` exit vocabulary; `sol logs` falls back to `kubectl`; an unreachable cluster is "could not check", never "not deployed" | — | — | CLI | local, aws | OB-L2/S3/S5, BUG-121/124 | PASS (LOCAL) |
| G8 | Alerts | rule set present; the lag rule matches the broker; `sol alert test` delivers to a receiver | — | — | Alertmanager | local, aws | OB-F1/F3, BUG-122 | PASS (LOCAL delivery); acknowledgement BLOCKED (operator) |
| G9 | Cross-signal identity | one request's log line, metric series and trace agree on all six dimensions | — | — | Loki + Prometheus + Tempo | local, aws | DEC-064 (campaign addition) | NOT RUN |

### H. Failure and recovery

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| H1 | Bad-message / DLQ | undecodable record → structured log, decode metric, DLQ record, offset advances | `worker.ml` | `@sol-fab/kafka` | broker, Loki | local, aws | OB-F2, FEAT-118 | PASS (LOCAL); NOT RUN (LIVE) |
| H2 | Failure injection | broker unavailable → relay holds; recovery publishes; relay restart preserves order | `FEAT-120` | `outbox.test.ts` | broker + Postgres | local | FEAT-120, FEAT-124 | PASS (LOCAL); NOT RUN (LIVE) |
| H3 | Deploy → fail → diagnose → rollback → recover | the documented loop completes without invented procedure | — | — | Kubernetes + release store | aws | OB-O1, matrix B | NOT RUN |
| H4 | Availability | drain keeps ready capacity; node loss restores within 300 s; worker readiness ≠ liveness | — | — | Kubernetes, node events | aws | matrix D1–D8 | NOT RUN |
| H5 | Broker loss | zero acknowledged-message loss; consumer auto-resume ≤ 60 s | — | — | broker | aws | matrix E5/E6 | NOT RUN |
| H6 | Postgres failure/restore | failover RPO ≈ 0; PITR restore into a clean target verified at the application level | — | — | RDS, transactions | aws | matrix E2–E4, E11 | NOT RUN |
| H7 | Telemetry loss | losing a telemetry backend degrades visibly and does not affect business data | — | — | backends | local, aws | matrix E10, OB-F1 | PASS (LOCAL visibility); alert firing NOT RUN |

### I. Lifecycle: bootstrap, update, destroy, uninstall

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| I1 | Installation | `sol cloud bootstrap` reports each durable prerequisite `Established`/`Unmet`/`UNKNOWN`; `--apply` reconciles state + identities + zone | — | — | provider APIs | aws, gcp | DOCS, AWS Run 7/8 | PASS (LIVE, AWS); GCP P0 |
| I2 | Environment to `Ready` | `CloudBootstrap → PlatformInstalling → Ready`; privilege revoked at the verified transition | — | — | phases + RBAC/IAM probes | aws, gcp | INV-AUTH-3, matrix I1–I6 | PASS (LIVE, AWS Run 7; GCP Attempts 17/19) |
| I3 | Ready-state destroy | `PreparingDestroy → Destroying → Absent`, verified independently | — | — | provider inventory | aws, gcp | INV-DESTROY-1/4 (Ready case) | PASS (LIVE, GCP Attempt 17); AWS NOT RUN |
| I4 | Destroy from partial/failed install | a target in failed `PlatformInstalling` is destructible through the public lifecycle | — | — | provider inventory | aws, gcp | INV-DESTROY-1/4, FND-0058 | PASS (LIVE, GCP Attempts 10/11) |
| I5 | Destroy idempotence | a second destroy reports `Absent`, exits 0, does no preparation | — | — | provider inventory | aws, gcp | matrix I11 | NOT RUN |
| I6 | Retention | `retention: none` leaves nothing billable; unsupported retention is refused before mutation | — | — | snapshot/inventory | aws, gcp | INV-RET-1, matrix I8 | PASS (LIVE, AWS Run 7; GCP observed) |
| I7 | Uninstall | `sol uninstall` removes the installation and keeps the operator's roles/external zone | — | — | provider APIs | aws | DEC-057 §7 | NOT RUN |
| I8 | Independent absence verification | tri-state PRESENT/ABSENT/UNKNOWN; a failed read is never absence; all classes swept | — | — | provider APIs | aws, gcp | DEC-045, INFRA-080 (DONE) | PASS (LIVE partial) |
| I9 | `byo` self-hosted substrate | one cheap provider satisfies the substrate contract end to end | — | — | external cluster | byo | INFRA-014 | BLOCKED (needs a live cheap cluster) |

### J. Release and artifact integrity

| Row | Capability | Observable behaviour | OCaml evidence | TS evidence | Shared / substrate evidence | Target(s) | Existing obligation | Status |
|---|---|---|---|---|---|---|---|---|
| J1 | Release publishes one aligned unit | tag `v*` publishes `bin/sol` + `share/sol/<version>/platform` + `sol-migration-runner:<version>`; republishing a tag is refused | — | — | release archive, GHCR | clean | FEAT-101, DEC-049, `RELEASE-006` | NOT RUN (mechanism PASS OFFLINE) |
| J2 | Installed-layout smoke | the bundle runs in a container with no checkout and no `SOL_HOME`; a planted reach-back fails it | — | — | CI job | clean | FEAT-101 | PASS (OFFLINE) |
| J3 | Live runs use the released artifact | the AWS/GCP harness drives the installed bundle, not a checkout | — | — | harness config | aws, gcp | `RELEASE-006` (divergence recorded) | NOT RUN |
| J4 | Provenance | `SUPPORT_REFS`/`--version` identify the build's revision and support pins | — | — | release archive | clean | BUG-059 | PASS (OFFLINE) |

## 4. Clean-user starting condition and canonical install

**Starting condition.** A machine with no Sol source checkout and no `SOL_HOME`,
holding only the released bundle and the tools `sol` drives: `aws`, `terraform`
(1.5+), `kubectl`, `docker`, `dig` (the doc's own table). The operator has a provider
CLI authenticated as their own identity. For cloud rows: a fresh account with no Sol
installation, and a target declared in `sol/environments.yml`.

**Canonical install.**

```bash
curl -L https://github.com/loganbnielsen/sol/releases/download/vX.Y.Z/sol-vX.Y.Z-linux-x86_64.tar.gz | tar xz
export PATH="$PWD/sol-vX.Y.Z/bin:$PATH"
sol assets        # every asset the binary drives is present
```

**Canonical workflow.**

```bash
sol new workspace acme && cd acme       # or: copy examples/pluto
sol cloud bootstrap <target>            # observe the installation (read-only)
sol cloud bootstrap <target> --apply    # reconcile state + identities + zone
# create the four roles from the printed policy contracts, declare their ARNs
sol deploy <target> --image-ref <svc>=<repo>@sha256:<digest>
sol status / sol logs / sol open        # operate
sol rollback <release>                  # recover
sol cloud destroy <target> --apply      # remove the environment (installation survives)
sol uninstall <target> --confirm        # remove the installation (separate)
```

**The release gap (recorded, Phase 2 work).** The mechanism is implemented (FEAT-101,
DEC-049) but the newest published release is `v0.1.0-alpha.6` (2026-06-11), which
predates the whole S1–S4 surface. A clean-user campaign cannot start from it. Cutting
and verifying an alpha release from the frozen revision is `RELEASE-006`. The AWS/GCP
harnesses currently run `sol` from a checkout; `RELEASE-006` also moves them onto the
released bundle, so the live runs qualify the artifact a user actually installs (J3).

## 5. Shared infrastructure and ownership boundaries

| Resource | Owner | Rule |
|---|---|---|
| Canonical checkout `/home/lbendtly/Code/sol` | the human operator | agents never mutate it; at most fetch + `--ff-only` when clean |
| One worktree per actor | that actor | `git worktree add -b <id>/<slug> ../sol-<id>-<slug> origin/main`; declare `SOL_AUTHORITY_*` on commit |
| `examples/pluto` shared files (`sol.yml`, `sol/environments.yml`, `pluto.opam`, `db/migrations/`, `events/*`) | one actor at a time | the shared scenario contract (`FEAT-131`) lands before the per-language streams fork; afterwards each stream owns only its own directories |
| `examples/pluto/app/**` (OCaml units) | the OCaml stream | disjoint from the TS stream's directories |
| `examples/pluto/app/demo_ts/**` + `events/demo_ts/**` | the TS stream | disjoint from the OCaml stream's directories |
| `internal/qualification/records/` | the run's owner | one record per run, from `run-record-template.md`; update `QUALIFICATION_STATUS.md` in the same ticket |
| `internal/qualification/aws/**` / `gcp/**` | one owner per provider | provider harnesses are edited by one actor at a time; live runs are serialized one target at a time |
| `internal/pipeline/tickets/**` | the filing actor | every change through a PR; no direct-to-main bookkeeping |
| Cloud accounts, credentials, live targets | the operator | no creation, mutation or spend without the §7 authorization |

The qualification ledger's operating rules (`internal/qualification/README.md`) apply
unchanged: cost rule (tear down before asking), `Absent` as the disposable-target
postcondition, evidence classes, provider-neutral mechanisms, and never weakening AWS
to accommodate GCP.

## 6. Parallel work allocation

Non-overlapping streams, each with its own branch/worktree and its own files. The
per-language streams depend on the shared scenario contract landing first; the cloud
streams are preparation-only until §7.

| Stream | Owner (proposed) | Scope / files | Depends on | Gate |
|---|---|---|---|---|
| **T0 Campaign lead** | this session | this artifact, the acceptance matrix, filings, evidence reconciliation, `QUALIFICATION_STATUS.md` | — | — |
| **T1 Scenario contract** | next available agent | the shared, language-neutral skeleton: `examples/pluto/sol.yml`, `sol/environments.yml`, `db/migrations/`, `events/orders*/`, HTTP/event contract | — | `FEAT-131` |
| **T2 OCaml reference app** | agent A | `examples/pluto/app/payments/**`, `examples/pluto/app/comms/**`, `examples/pluto/lib/**`, `examples/pluto/test/**` | T1 | `FEAT-132` |
| **T3 TypeScript reference app** | agent B | `examples/pluto/app/demo_ts/**`, `events/demo_ts/**` | T1 | `FEAT-133` |
| **T4 Local integrated qualification** | agent C (evidence coordinator) | run rows B–H on k3d with the released bundle; records + matrix status | T2, T3, `RELEASE-006` | `VERIF-027` |
| **T5 AWS substrate & run** | agent D | `internal/qualification/aws/**`; HARDEN-007 §B3 onward | T4, `RELEASE-006` | operator authorization |
| **T6 GCP substrate & run** | agent E | `internal/qualification/gcp/**`; HARDEN-008, `INFRA-005` | T4, `RELEASE-006` | operator authorization |
| **T7 Bounded defect capacity** | agent F | the READY queue (`BUG-126`, `BUG-128`, `FEAT-114`, `INFRA-065`, …) | — | — |

T5 and T6 are serialized against each other by cost and identity (one target at a
time), but their *preparation* is parallel. T7 keeps the campaign from blocking on
defects it discovers: a concrete Sol defect is filed, fixed if bounded and unowned,
mutation-tested and merged, then the affected acceptance rows rerun — it is not
carried as an exception in the matrix.

## 7. Operator-gated actions

These are the only actions the campaign may not start autonomously. Everything else —
planning, reference-app implementation, offline verification, local k3d qualification,
harness preparation, evidence-matrix work — proceeds without asking.

1. **Live AWS qualification** — `HARDEN-007` (Run 9, §B3 onward): a billable EKS/RDS
   target, the scoped identities, an SSO session for the qualification account, and
   the qualification transport (`sol:qualifiers`) established against a real cluster.
   Expected resources: one EKS cluster, one RDS Postgres, one ECR namespace, one
   load balancer, NAT/EIP/EBS as the module declares, and a delegated
   `qual-aws.sol-fab.dev` zone. Rows: AWS matrix §B–§H, INV-AUTH-*, INV-IDENT-1.
2. **Live GCP qualification** — `HARDEN-008` (Attempt 10): a fresh GKE Standard
   target, Cloud SQL, Artifact Registry, and the `sol-qualification` project's billing
   and quota (SSD_TOTAL_GB 1000). Rows: GCP matrix `INV-*`, `Ready` and
   Ready-state destruction. Resolves `FND-0010` only if the check passes.
3. **`VERIF-021` / `VERIF-022`** — managed secret projection and projected ServiceAccount
   tokens, run *inside* the same AWS/GCP campaign targets so the substrate is shared
   rather than a disconnected secret-only experiment.
4. **Alert acknowledgement (AWS G2)** — a real receiver and an owner who acknowledges.
5. **`PROD-001`** — the maturity-A pilot, which additionally needs a named owning team
   and a real non-critical workload; the campaign brings it to the point where those
   are the only missing inputs.
6. **Release version** — the alpha release tag/version for `RELEASE-006`. Recommended:
   `v0.1.0-alpha.7` from the frozen campaign revision, confirmed alongside (1).

**The single ask.** Once the offline/local work reaches the point where the runs are
fully specified (matrix rows, expected resources, prerequisites, cost, teardown), the
campaign asks once for authorization of (1)–(3) together, and for the §7.6 version.

## 8. Finish condition

1. Both the OCaml and TypeScript reference applications demonstrate the frozen
   supported Sol contract, with the same externally observable behaviour.
2. Every acceptance row carries an honest `PASS` / `FAIL` / `N/A` / `BLOCKED` verdict
   with evidence at the class its claim requires.
3. The required AWS and GCP live qualification has been performed where authorized,
   with independently verified teardown.
4. Concrete defects the campaign exposed are fixed, mutation-tested and merged, and
   the affected rows rerun.
5. Rollback, recovery and destroy behaviour has been exercised where required.
6. Remaining blockers are genuinely external/operator/trigger-gated rather than
   unexamined implementation work.

## How to update this artifact

- A row's verdict changes only with evidence of the required class; cite the run
  record by its identity (provider, target, revision, profile, timestamp) and update
  the matching row in the AWS/GCP/observability matrix in the same PR.
- A new capability that enters the frozen surface gets a new row, a map to an
  existing obligation (or a new ticket), and a target.
- Do not delete a `NOT RUN` / `BLOCKED` row to make the surface look smaller; record
  the reason and the gate.
