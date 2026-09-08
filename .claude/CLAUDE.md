# Sol — Claude Context

## Development phase: pre-alpha, no backwards compatibility

Sol and every support library it pins (see `~/Code/CLAUDE.md`, one level
up) are pre-alpha: no customers, no external users, nothing depending on
current API shape. Backwards compatibility is not a constraint anywhere
in this repo — don't add compat shims, deprecated aliases, or version
gates; change public signatures freely when it makes the design correct,
and update call sites in the same pass. Full policy: `~/Code/CLAUDE.md`.

## Current development focus

**Phase 7 core deliverables complete.** `sol deploy <env>/<provider>/<region>` takes a required target positional (same convention as `sol plan`) plus `--image-tag`, `--registry`, `--emit-to` (GitOps), and `--dry-run` flags; the target resolves `sol.yml`/target-file defaults and the `env` manifest label (FEAT-026). YAML rendering is shared by `sol up` and `sol deploy`. Terraform modules live at `cli/platform/infra/base/`, `cli/platform/infra/aws/`, and `cli/platform/infra/gcp/`. Remaining hosted-product work is tracked in `pipeline/tickets/`. See `docs/planning/WORK_SUMMARY.md` for full details.

Package: `cli/sol/` — binary at `_build/default/cli/sol/bin/main.exe`.

## Ticket system

Work is tracked in `pipeline/tickets/` using a directory-per-status layout. Each ticket is a markdown file with YAML frontmatter. **The `pipeline/tickets/` directory is only ever modified in the `main` checkout — never inside a worktree branch.**

```
pipeline/tickets/
  BACKLOG/                  ← captured but not yet prioritised
  READY_FOR_ENGINEERING/    ← actionable; pick up with /start
  IN_PROGRESS/              ← worktree exists, work underway
  REVIEW/                   ← work submitted; awaiting /review-worktree
  READY_TO_MERGE/           ← review passed; human merges
  BLOCKED_BY_PERFORMANCE/   ← perf regression; needs fix or sign-off
  DONE/                     ← merged
```

**State machine:** `READY_FOR_ENGINEERING` → `IN_PROGRESS` → `REVIEW` → `READY_TO_MERGE` → `DONE`  
`IN_PROGRESS` → `REVIEW` happens via `soldev pipeline submit <ticket-id>`, which pushes the ticket's branch and opens a real GitHub PR (recorded in the ticket's `pr:` field) — `REVIEW` means "a PR is open," not just "a worktree exists."  
If `/review-worktree` finds issues: back to `READY_FOR_ENGINEERING` (with inline notes; `branch`/`worktree` fields preserved).  
`READY_TO_MERGE` → `DONE` happens via `soldev pipeline merge`, which merges the PR (`gh pr merge --squash --delete-branch`) — real GitHub branch protection and required checks gate the merge, not local logic.

**Ticket frontmatter fields:** `id`, `type` (ux-finding | audit-finding | feature | bug), `severity`, `source`, `branch`, `worktree`, `pr` (set by `soldev pipeline submit`, once a PR exists).  
Do not add a `status:` field — the directory encodes status.

**Human-judgment gates:** Tickets in `BACKLOG/` may contain `## Open Questions`, `## Decision Required`, or `## Blocked On` sections. Tickets in `READY_FOR_ENGINEERING/` are treated as actionable, so `/work` must stop before creating a worktree if any unresolved decision section or marker remains. Resolve the decision in the ticket body or keep the ticket in `BACKLOG/` until the Remediation is unambiguous.

**Ticket dependencies:** Use a body line near the top of each ticket: `**Depends on:** None.` or `**Depends on:** FEAT-003, EXP-008.` `/work` must verify dependencies before creating a worktree. A `READY_FOR_ENGINEERING` ticket with dependencies not yet in `pipeline/tickets/DONE/` stays blocked.

**Skills that interact with tickets:**
- `/work` — unified entry point; dispatches by state: creates worktrees for `READY_FOR_ENGINEERING`, resumes `IN_PROGRESS`, runs review agent on `REVIEW`. Submits `IN_PROGRESS` → `REVIEW` via `soldev pipeline submit` (push + open PR)
- `/review-worktree` — standalone review gate (called internally by `/work review`); subagents emit JSON, `soldev pipeline review` handles file moves
- `/audit` and `/ux-audit` — materialise new findings into `READY_FOR_ENGINEERING/` (idempotent)

**Performance baseline conflict:** `devtools/perf/perf_baseline.json` is set to `merge=ours` in `.gitattributes`. On merge, main's baseline wins; a post-merge perf run determines whether the ticket stays merged or moves to `BLOCKED_BY_PERFORMANCE`.

## Core design principles every engineer must know

**Security on Day 1.** `Kafka_security.t` is a first-class field in every producer, consumer, and service config. `config_of_env()` reads `KAFKA_SECURITY_PROTOCOL`, `KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_*` from the environment. Dev defaults to `Plaintext`; the type forces all other environments to state their security posture explicitly. Do not add Kafka config anywhere that lacks a `security` field.

**Dev mirrors prod exactly.** `sol dev up` runs the same Helm charts as production at single-replica scale. Port-forwards expose every service at the same address the service code expects. If there's a divergence between dev and prod addressing or configuration, that divergence is a bug.

## What this repo is

Sol is an opinionated OCaml 5 production platform for startups. Kafka layer, observability backends, all three service primitives (`-svc`, `-worker`, `-fn`), storage (PostgreSQL), and CLI scaffold commands are complete.

## Repo layout

```
sol/
  # kafka-eio-core/producer/consumer + the produce-then-consume demo moved out to the
  # standalone `kafka-eio` opam package at ~/Code/kafka-eio (own git repo, opam-pinned
  # into this switch). Edit there, then `opam pin add kafka-eio ~/Code/kafka-eio` to
  # pick up changes. Single findlib library `kafka-eio`; public API is the nested
  # `Kafka.Producer`/`Kafka.Consumer`/`Kafka.Error`/`Kafka.Security` modules
  # (flat `Kafka_producer`/etc. names are private to the kafka-eio package).
  # obs-eio (core: spans, metrics, trace context), obs-loki-eio (Loki HTTP push
  # backend), and obs-prometheus-eio (Prometheus exposition backend) moved out to
  # standalone opam packages at ~/Code/obs-eio, ~/Code/obs-loki-eio, and
  # ~/Code/obs-prometheus-eio (own git repos, opam-pinned into this switch). Edit
  # there, then `opam pin add <pkg> https://github.com/loganbnielsen/<pkg>.git` to
  # pick up changes. Findlib/library names match the package names exactly:
  # `obs-eio`, `obs-loki-eio`, `obs-prometheus-eio`. Public modules: `Obs_eio`
  # (+ `Obs_trace`), `Obs_loki`, `Obs_prometheus`. No `integrations/observability/`
  # directory remains in this repo.
  # pg-eio (Postgres pool, migrations, Table.Make functor — formerly `sol-storage`)
  # moved out to a standalone opam package at ~/Code/pg-eio, opam-pinned into this
  # switch. Edit there, then `opam pin add pg-eio ~/Code/pg-eio` to pick up changes.
  # Findlib name: `pg-eio`. Public modules unchanged: `Storage_error`, `Db`,
  # `Migration`, `Table`. No `integrations/storage/` directory remains in this repo.
  # aws-eio (SigV4 signing, credential resolution, HTTP transport — the foundation
  # layer for AWS integrations) lives at a standalone opam package, ~/Code/aws-eio,
  # opam-pinned into this switch, alongside its s3-eio/dynamodb-eio/lambda-eio
  # siblings (each its own standalone package, own repo). Extracted before any
  # in-tree consumer existed (unlike kafka-eio/obs-eio/pg-eio, which were pulled
  # out after real usage). Edit there, then `opam pin add aws-eio ~/Code/aws-eio`
  # to pick up changes. Findlib name: `aws-eio`. No `integrations/aws/` directory
  # remains in this repo yet — nothing in Sol consumes this package today.
  framework/                   ← Sol service primitives
    sol-svc/lib/                ← REST API service (routes, auth, metrics)
    sol-worker/lib/             ← Kafka consumer (schema registration, per-message metrics)
    sol-fn/lib/                 ← Scheduled function (Pushgateway push, invocation metrics)
    sol-*/sol-*.md              ← per-package spec docs
    kafka-eio-service/lib/      ← schema registry + service orchestration, depends on `kafka-eio.*`
    kafka-eio-service/test/
    kafka-eio-service/kafka-eio-service.md    ← per-package spec doc
  # No `integrations/` directory remains in this repo — kafka-eio-service moved into
  # `framework/` (it's an app-linked library like sol-svc/sol-worker/sol-fn, just
  # historically placed separately because it predates `framework/` as a concept);
  # the other former `integrations/*` subdirs (storage, observability, aws) were
  # already extracted to standalone opam packages, described below.
  examples/local-demo/                         ← full-stack showcase demo (svc → Kafka → worker)
    lib/                        ← shared event contracts for demo
    bin/demo.ml                 ← orchestrated demo binary
  cli/platform/local/
    scripts/                    ← ensure-broker.sh, ensure-loki.sh, etc.
    k8s/                        ← Kubernetes manifests
  dune-project / dune-workspace ← unified root build
  README.md / docs/planning/ROADMAP.md / docs/planning/WORK_SUMMARY.md  ← project-wide docs
```

## Build

```bash
eval $(opam env)
dune build
```

**Prerequisite:** `sudo apt-get install -y librdkafka-dev`  
**OCaml packages:** `eio`, `eio_main`, `alcotest`, `cohttp-eio`, `yojson`, `base64` (install via `opam install`)

## Tests

```bash
# Unit tests (no broker needed)
eval $(opam env) && dune test framework/

# Full integration tests (requires Redpanda + Loki running)
bash cli/platform/local/scripts/ensure-broker.sh
bash cli/platform/local/scripts/ensure-loki.sh
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 dune test --force
```

## Run the demo

```bash
# Start infrastructure
bash cli/platform/local/scripts/ensure-broker.sh
bash cli/platform/local/scripts/ensure-loki.sh
bash cli/platform/local/scripts/ensure-grafana.sh
bash cli/platform/local/scripts/ensure-prometheus.sh

# Run the full-stack demo (svc → Kafka → worker, with Loki logs + Prometheus metrics)
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 \
  dune exec examples/local-demo/bin/demo.exe

# Then browse to http://localhost:3000 (Grafana)
```

## Key design decisions

- **`Kafka_security` is the transport security module** — lives in `kafka-eio-core/lib/kafka_security.ml`. Every `config` type in producer, consumer, and service carries a `security : Kafka_security.t` field. `Kafka_security.apply conf t` calls `Kafka_raw.conf_set` for `security.protocol`, `ssl.ca.location`, `sasl.*`. Never construct a Kafka config without it.
- **All libraries use `(wrapped false)`** — modules are globally accessible as `Kafka_error`, `Kafka_raw`, etc. (not namespaced under library name).
- **`produce`/`produce_await` take a trailing `()`** — required by OCaml's optional-argument erasure rules since `?key` is the last arg with no positional arg after it.
- **Delivery receipts via pipe** — the C delivery callback writes a `(corr_id, err_code)` struct to a Unix pipe (thread-safe, no OCaml runtime needed from C). A background Eio fiber reads from the pipe and resolves pending promises.
- **Fix blocking C calls at the FFI boundary, not above it** — when a C binding holds the OCaml domain lock during a blocking call, the fix belongs in `kafka_stubs.c`: extract all OCaml values into C locals, call `caml_release_runtime_system()`, run the blocking C function, then `caml_acquire_runtime_system()` before any OCaml allocation. This is the pattern used by `ocaml_rd_kafka_flush`, `ocaml_rd_kafka_consumer_close`, and `ocaml_rd_kafka_consumer_poll`. Do not add workaround layers at the OCaml level (`Eio_unix.run_in_systhread`, `Eio.Time.sleep` polling loops, clock parameters) when the correct fix is a two-line change in the C stub.
- **Consumer poll runs directly in a fiber** — `poll_fiber` calls `Kafka_raw.consumer_poll t.handle 100` directly (no systhread). The C stub releases the OCaml domain lock for the duration of the 100ms block, so the GC can run and Eio delivers `Cancelled` cleanly once the call returns.
- **`Kafka_consumer_handle.t`** — a thin shared type in kafka-eio-core that lets the producer accept a consumer handle in `with_transaction` without creating a circular dependency.

## Error handling

All operations return `(_, Kafka_error.t) result`. Never raise on API calls.  
`Kafka_error.of_int` maps librdkafka integer error codes to typed variants.  
`Kafka_error.to_string` calls `rd_kafka_err2str` via FFI for human-readable messages.

## OCaml version

OCaml 5.4.1, Eio 1.3, dune 3.23.1.  
Eio types to know: `Eio.Promise.u` (resolver), `_ Eio.Time.clock`, `Eio_unix.Stdenv.base`.

## Local Kafka broker

Redpanda (native Linux, no Docker). Start: `rpk redpanda start --overprovisioned --smp 1 --memory 512M`  
Topics: `sol-demo`, `sol-producer-test`, `sol-consumer-test`  
Default broker address: `localhost:9092`

## Documentation Protocol

You must maintain and consult the project's source-of-truth markdown files:

1. **At Startup / Task Initialization**:
   - Explicitly read `docs/planning/ROADMAP.md` and `docs/planning/WORK_SUMMARY.md` using your file-reading tool before writing any code.
   - Align your execution path with the active milestone in `docs/planning/ROADMAP.md` and the current active tasks in `docs/planning/WORK_SUMMARY.md`.

2. **When Writing Code**:
   - Refer to `README.md` for foundational architecture rules.
   - Refer to the `*.md` spec file co-located with the package you are working in (e.g. `framework/kafka-eio-service/kafka-eio-service.md`) for feature implementation guidelines. For `kafka-eio-core`/`producer`/`consumer`, the spec docs live in the external `~/Code/kafka-eio` repo. For `obs-eio`/`obs-loki-eio`/`obs-prometheus-eio`, the spec docs live in their respective external `~/Code/obs-*` repos. For `pg-eio`, the spec doc (`README.md`) lives in the external `~/Code/pg-eio` repo.

3. **At Task Completion / Session End**:
   - Update `docs/planning/WORK_SUMMARY.md` to accurately reflect what was accomplished, what is currently "In Progress", and any new implementation hurdles or blockers discovered.
   - If a major milestone is hit, update the status checklist in `docs/planning/ROADMAP.md`.
