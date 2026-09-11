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

Work is tracked in `pipeline/tickets/` using a directory-per-status layout. Each ticket is a markdown file with YAML frontmatter.

```
pipeline/tickets/
  BACKLOG/                  ← captured but not yet prioritised
  READY_FOR_ENGINEERING/    ← actionable; pick up with /work — covers "not started"
                               through "PR open, in review": GitHub's own open-PR/
                               review/CI state already tracks that, no local
                               directory duplicates it
  DONE/                     ← merged
```

**State machine (REFAC-077):** `READY_FOR_ENGINEERING` → `DONE`, full stop. There is no separate "in progress," "in review," "ready to merge," or "blocked by performance" directory any more.

`pipeline/tickets/` is normally only ever modified in the `main` checkout — never inside a worktree branch — **with one deliberate exception**: the `READY_FOR_ENGINEERING → DONE` move itself is committed *on the ticket's own PR branch*, as the worker's own final implementation commit. That's what makes `gh pr merge --squash` carry the ticket's completion into `main` inside the very same commit as the code, instead of needing a separate commit on `main` for it. A `BACKLOG → READY_FOR_ENGINEERING` move (e.g. an audit materialising a new finding) still only ever happens in the main checkout, same as before.

Review and merge readiness live entirely on the PR, not on a ticket directory: `soldev pipeline review <ticket-id>` leaves its verdict as a plain PR comment either way — a `SOLDEV-REVIEW: PASS`-marked comment on pass, an ordinary violations comment on fail. It's a comment rather than a formal GitHub review because this is a solo-owned repo: the `gh` identity is always the PR's own author, and GitHub refuses to let an author formally approve their own PR. A bounce just means another commit on the same open PR, this repo's established convention, never a ticket-directory round trip. `soldev pipeline merge` checks the PR for that pass-marker comment and green CI directly against GitHub before it will act, then runs `gh pr merge --squash --delete-branch --admin` — the `--admin` bypasses branch protection's separate 1-approval requirement (which, for the same self-approval reason, this repo can never satisfy natively); required status checks still gate the merge for real. A post-merge regression is handled by reverting that one squash commit, which un-does the code *and* the ticket's `DONE` move together (they were always the same commit) — the ticket lands back in `READY_FOR_ENGINEERING` automatically, with no separate "blocked" state to move it out of.

**Ticket frontmatter fields:** `id`, `type` (ux-finding | audit-finding | feature | bug), `severity`, `source`. `branch`/`worktree`/`pr` are no longer persisted on `main` — they're only meaningful while a ticket has an open PR, which `soldev pipeline ls`/`check` surface live from GitHub instead.  
Do not add a `status:` field — the directory encodes status.

**Human-judgment gates:** Tickets in `BACKLOG/` may contain `## Open Questions`, `## Decision Required`, or `## Blocked On` sections. Tickets in `READY_FOR_ENGINEERING/` are treated as actionable, so `/work` must stop before creating a worktree if any unresolved decision section or marker remains. Resolve the decision in the ticket body or keep the ticket in `BACKLOG/` until the Remediation is unambiguous.

**Ticket dependencies:** Use a body line near the top of each ticket: `**Depends on:** None.` or `**Depends on:** FEAT-003, EXP-008.` **Every ticket id on that line becomes a dependency**, whatever prose surrounds it — so a mention like `Implemented by FEAT-059` or `Related: DEC-016` creates a dependency you did not intend, and two tickets referring to each other that way deadlock. Put other mentions on their own line. `/work` must verify dependencies before creating a worktree. A `READY_FOR_ENGINEERING` ticket with dependencies not yet in `pipeline/tickets/DONE/` stays blocked; if a cycle does form, `soldev pipeline check` and `pipeline ls` report it as a cycle rather than as ordinary waiting.

**Ticket titles:** The PR title and the listing summary both come from the ticket body — an explicit `title:` frontmatter field when present, otherwise the first line that is not a bold-labelled field, with Markdown heading markers stripped. So either state `title:` or open the body with a real title sentence. Two ways this goes wrong, both observed: opening with a paragraph of argument produces a PR subject that reads as a sentence, and opening with a labelled field (any `**Label:**`, not just `**Depends on:**`) makes that field the displayed summary.

**Demo/example coverage:** Any ticket that changes what an app author does — a new `sol.toml` field, a framework primitive or runtime contract, a new CLI command, or changed generated manifests — must update a runnable example or demo (`examples/`, a tutorial code sample, or the scaffolded workspace) in the same ticket, and must say so in its Acceptance criteria. If a demo genuinely does not apply (internal refactor, pure documentation), state that in one line in the ticket's completion notes. "The CI smoke covers it" is not sufficient: a smoke test is a test, not a reference a user can read or run. New example Dockerfiles go in the `example-dockerfile-smoke` CI matrix, and demo-facing changes run `/demo-review`.

**Skills that interact with tickets:**
- `/work` — unified entry point; creates worktrees for `READY_FOR_ENGINEERING` tickets with no open PR yet, resumes ones that already have one, runs the review agent on ones ready for it. The worker's own last commit moves the ticket to `DONE/` on the branch before `soldev pipeline submit` pushes it and opens the PR.
- `/review-worktree` — standalone review gate (called internally by `/work`); subagents emit JSON, `soldev pipeline review` leaves the verdict on the PR
- `/audit` and `/ux-audit` — materialise new findings into `READY_FOR_ENGINEERING/` (idempotent)

**soldev roles (REFAC-079):** GitHub PRs/CI are the source of truth; `soldev` is an orchestration layer over GitHub, not a second authority.
- `pipeline ls` / `pipeline check` — orchestration: queue view, preflight gates, PR and dirty-worktree annotations.
- `pipeline submit` — orchestration: pushes the ticket branch and opens/reuses the PR.
- `pipeline review` — orchestration: posts the structured `SOLDEV-REVIEW` verdict comment that `merge` trusts.
- `pipeline merge` — orchestration: verifies review marker + CI directly on GitHub, then runs `gh pr merge --squash --delete-branch --admin`.
- `pipeline merge-finish` — informational/maintenance, invoked by `merge`: records perf baseline/history after a merge. It does **not** gate or revert merges; merging outside soldev simply skips this informational step.
- `pipeline check-reverts` — safety diagnostic over git history.
- Pre-commit hook — convenience local gate; GitHub CI is the authoritative PR gate. `SOL_SKIP_HOOKS=1` intentionally allows a one-off local bypass.
- Post-commit hook — informational perf status + orphaned-worktree warnings.
- Direct-to-`main` ticket-file commits (`BACKLOG` promotions, audit filings) — bookkeeping exception; kept outside PRs because they are metadata moves, not code.

**Performance baseline:** `devtools/perf/perf_baseline.json` is main-only and informational. `run_tests.sh` writes it only with `--update-baseline`; pre-commit never stages it into code commits; merges never revert on perf-ratio regressions (REFAC-078). `.gitattributes` keeps `merge=ours` for local merges.

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
**Formatter:** `ocamlformat.0.29.0` is required to run `dune fmt` locally (`opam install ocamlformat.0.29.0`). CI checks formatting drift with `dune fmt --preview`, which fails on changes without modifying files.

## Tests

```bash
# Unit tests (no broker needed)
eval $(opam env) && dune test framework/

# Full integration tests (requires Redpanda + Loki running)
bash cli/platform/local/scripts/ensure-broker.sh
bash cli/platform/local/scripts/ensure-loki.sh
KAFKA_BROKERS=localhost:9092 LOKI_URL=http://localhost:3100 dune test --force
```

If CLI tests report `Multiple rules generated` for `vendor/framework/...` paths
or missing files under `_build/default/cli/platform/...`, remove `_build` and
rerun — BUG-017 prevents the `_build/default` SOL_HOME mis-resolution that
originally caused those failures, but a stale/partial build tree can still
leave confusing artifacts. A clean rebuild is the documented recovery.

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
