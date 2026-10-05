# Sol — Agent Context

This is the repo's tool-neutral agent context file. It was `CLAUDE.md`; it is
now `AGENTS.md` so any agent CLI can read it.

**Where agent things live (single copy, tool-neutral):**

- **Skills:** `.agents/skills/<name>/SKILL.md` — migrated out of `.claude/skills/`.
  Use the skill `agent-setup` to add or migrate more. Frontmatter needs both
  `name` (== folder) and `description`.
- **Context:** this file, at the repo root.
- **DeepCode settings:** `.deepcode/settings.json` (project) or
  `~/.deepcode/settings.json` (user) — not committed.

## Development phase: pre-alpha, no backwards compatibility

Sol and every support library it pins (see `~/Code/CLAUDE.md`, one level
up) are pre-alpha: no customers, no external users, nothing depending on
current API shape. Backwards compatibility is not a constraint anywhere
in this repo — don't add compat shims, deprecated aliases, or version
gates; change public signatures freely when it makes the design correct,
and update call sites in the same pass. Full policy: `~/Code/CLAUDE.md`.

## Current development focus

**Phase 7 core deliverables complete.** `sol deploy <env>/<provider>/<region>` takes a required target positional (same convention as `sol plan`) plus `--image-tag`, `--registry`, `--emit-to` (GitOps), and `--dry-run` flags; the target resolves `sol.yml`/target-file defaults and the `env` manifest label (FEAT-026). YAML rendering is shared by `sol up` and `sol deploy`. Terraform lives under `platform/cloud/`: the shared platform module `modules/platform/`, and per-provider `bootstrap/`, `cluster/` and `platform/` roots that mirror each other (DEC-046 rule 4). Remaining hosted-product work is tracked in GitHub Issues.

Package: `cli/` — binary at `_build/default/cli/bin/main.exe`.

## Work tracking

GitHub Issues and pull requests are the work-state authority. Create an issue when work is useful to track; use an ordinary branch or worktree, open a PR, rely on CI, request review proportional to risk, and squash-merge. Branch and worktree names carry no Sol-specific semantics. Do not recreate repository-local ticket states, premise probes, dependency enforcement, or merge bookkeeping.

## Core design principles every engineer must know


**Security on Day 1.** `Kafka_security.t` is a first-class field in every producer, consumer, and service config. `config_of_env()` reads `KAFKA_SECURITY_PROTOCOL`, `KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_*` from the environment, and **`KAFKA_SECURITY_PROTOCOL` is required** (SEC-007): an absent value is an error, never a default. Sol-rendered manifests set it; a local process sets `KAFKA_SECURITY_PROTOCOL=plaintext`. The declared posture today is in-cluster plaintext with no SASL, in every profile; TLS/SASL for production is FEAT-093. Do not add Kafka config anywhere that lacks a `security` field.

**Dev mirrors prod exactly.** `sol local infra up` runs the same Helm charts as production at single-replica scale. Port-forwards expose every service at the same address the service code expects. If there's a divergence between dev and prod addressing or configuration, that divergence is a bug.

**The primary axis takes the positional (DEC-031, over DEC-032's axes).** A command has three possible axes — `target` (where), `scope` (what), `view` (which operational concern) — and exactly one of them is *primary* for that command. The primary axis is the positional argument; every other axis is a flag. Writing a new command means deciding which axis it is addressed by, and that decision is what the positional carries:

- addressed **by scope** → scope positional, target `--target`: `sol status [SCOPE]`, `sol open <view> [SCOPE]`;
- addressed **by target** → target positional, scope `--scope`: `sol up <TARGET>`, `sol deploy <TARGET>`, `sol cloud plan|apply|destroy <TARGET>`, `sol plan`.

This is why `sol status payments/checkout-svc` and `sol up local --scope payments/checkout-svc` are both correct and are not inconsistent. Do not add a `--scope` flag to a scope-primary command or a positional scope to a target-primary one to "make them match"; the split is the rule.

Accepted scopes are **not** uniform, and widening one is a feature, not consistency: `sol status` / `sol open` take workspace, `domain`, `domain/unit`, and `resource/<type>/<name>`; the `--scope` commands resolve `domain` and `domain/unit` through `Sol_cli_workload_selection`; and **`sol logs` is deliberately unit-only** — a workspace- or domain-wide Loki query is a different feature with its own cost and pagination shape, so `sol logs --scope payments` is an error rather than a wider query. The shared thing is the selector *grammar* (`domain` and `domain/unit` mean the same everywhere), not the set of surfaces that accept each scope.

## What this repo is

Sol is an opinionated production platform for backend systems. Its platform/CLI is written in OCaml and is language-neutral in what it does; OCaml and TypeScript are both first-class application languages (DEC-022). Kafka layer, observability backends, all three service primitives (`-svc`, `-worker`, `-fn`), storage (PostgreSQL), and CLI scaffold commands are complete.

## Organization rules (DEC-046)

When a new file has no obvious home, apply these rules rather than copying the tree. The decision behind them is `DEC-046`; the work is `REFAC-099`…`REFAC-105`.

1. **The top level is split by audience.** `docs/` is for people *using* Sol; `internal/` is for people *building* Sol.
2. **Code and assets are separate.** `cli/` holds the binary and what it needs (OCaml and its test scripts). `platform/` holds what the CLI drives (Helm values, Terraform, templates, scripts) and no OCaml.
3. **Platform assets are split shared / local / cloud.** Platform config varies by *profile*; project config varies by *environment and target*.
4. **Cloud providers mirror each other by role.** The directory is the marker: a registered provider with no `platform/cloud/<provider>/` is on paper, and one with a directory has every role.
5. **Each kind of artifact has one home.** Implementer specs stay next to their code.
6. **Code folders follow the dependency graph.** Per-domain dune libraries where the graph is clean.

## Repo layout

The tree below is today's. It moves toward the target layout as REFAC-099…105 and DOCS-023/024 land, and each of those tickets updates this tree.

```
sol/
  # ── product ───────────────────────────────────────────────────────────────
  cli/                          ← the `sol` CLI — the binary and what it needs (DEC-046 rule 2)
    bin/ test/                  ← command parsing, tests
    lib/{base,kube,workspace,cloud,deploy,local}/  ← one dune library per domain (REFAC-104);
                                  a DAG, base ← kube ← workspace ← cloud ← deploy; `sol_cli` is the umbrella
  platform/                     ← what the CLI drives — no OCaml
    components/                 ← Helm values shared by local and cloud
    cloud/                      ← Terraform: modules/platform (shared definition),
                                  <provider>/{bootstrap,cluster,platform} roots, delivery/
    local/                      ← local k3s tooling
  framework/ocaml/              ← first-party OCaml framework packages
    sol-svc/lib/                ← REST API service (routes, auth, metrics)
    sol-worker/lib/             ← Kafka consumer (schema registration, per-message metrics)
    sol-fn/lib/                 ← Scheduled function (Pushgateway push, invocation metrics)
    sol-jobs/lib/               ← Postgres-backed leased job library, hosted by a -worker (FEAT-077)
    sol-*/sol-*.md              ← per-package spec docs
    kafka-eio-service/lib/      ← schema registry + service orchestration, depends on `kafka-eio.*`
  examples/pluto/               ← canonical reference application (OCaml + TypeScript, local + cloud)
  docs/                         ← for people using Sol: guides, reference/ (the application contract),
                                  deployment, architecture, hosted, legal; ROADMAP.md
  internal/                     ← maintainer machinery (not product)
    ci/                         ← CI guardrails, classifier, mutation tests
    qualification/              ← live qualification: aws/, gcp/ (harnesses, matrices), records/ (dated runs), transport/
    pipeline/                   ← tickets/, audits/, dogfood/
    planning/                   ← maintainer trackers
    specs/                      ← cross-language framework conventions (DEC-022)
    tooling/                    ← soldev, sol_process, hooks/, perf/, scripts/ (test runner, perf, hook install)
    fixtures/                   ← test fixtures (OCaml-only worker workspace, e2e demo)
  # ── package contracts ────────────────────────────────────────────────────
  dune-project / dune-workspace ← unified root build
  README.md / docs/ROADMAP.md   ← project-wide docs

  # Extracted support packages (own repos, opam-pinned into this switch):
  #   kafka-eio (~/Code/kafka-eio); obs-eio/obs-loki-eio/obs-prometheus-eio
  #   (~/Code/obs-*); pg-eio (~/Code/pg-eio); aws-eio/s3-eio/dynamodb-eio/
  #   lambda-eio (~/Code/aws-eio). Findlib names match the package names.
  #   No `integrations/` directory remains in this repo.
```

## Build

```bash
eval $(opam env)
dune build
```

**Prerequisite:** `sudo apt-get install -y librdkafka-dev`  
**OCaml packages:** `eio`, `eio_main`, `cohttp-eio`, `yojson`, `base64` (install via `opam install`); tests use `windtrap`/`ppx_windtrap`  
**Formatter:** `ocamlformat.0.29.0` is required to run `dune fmt` locally (`opam install ocamlformat.0.29.0`). CI checks formatting drift with `dune fmt --preview`, which fails on changes without modifying files.

## Tests

```bash
# Unit tests (no broker needed)
eval $(opam env) && dune test framework/

# Full integration tests (requires Redpanda + Loki running)
bash platform/local/scripts/ensure-broker.sh
bash platform/local/scripts/ensure-loki.sh
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 LOKI_URL=http://localhost:3100 dune test --force
```

If CLI tests report `Multiple rules generated` for `vendor/framework/...` paths
or missing files under `_build/default/platform/...`, remove `_build` and
rerun — BUG-017 prevents the `_build/default` SOL_HOME mis-resolution that
originally caused those failures, but a stale/partial build tree can still
leave confusing artifacts. A clean rebuild is the documented recovery.

## Run the demo

```bash
# Start infrastructure
bash platform/local/scripts/ensure-broker.sh
bash platform/local/scripts/ensure-loki.sh
bash platform/local/scripts/ensure-grafana.sh
bash platform/local/scripts/ensure-prometheus.sh

# Run the full-stack demo (svc → Kafka → worker, with Loki logs + Prometheus metrics)
KAFKA_SECURITY_PROTOCOL=plaintext KAFKA_BROKERS=localhost:9092 SCHEMA_REGISTRY_URL=http://localhost:8081 REDPANDA_ADMIN_URL=http://localhost:9644 LOKI_URL=http://localhost:3100 \
  dune exec internal/fixtures/local-demo/bin/demo.exe

# Then browse to http://localhost:3000 (Grafana)
```

## Key design decisions

- **`Kafka_security` is the transport security module** — lives in `kafka-eio-core/lib/kafka_security.ml`. Every `config` type in producer, consumer, and service carries a `security : Kafka_security.t` field. `Kafka_security.apply conf t` calls `Kafka_raw.conf_set` for `security.protocol`, `ssl.ca.location`, `sasl.*`. Never construct a Kafka config without it.
- **All libraries use `(wrapped false)`** — modules are globally accessible as `Kafka_error`, `Kafka_raw`, etc. (not namespaced under library name).
- **`produce_receipt`/`produce_await` take a trailing `()`** — required by OCaml's optional-argument erasure rules since `?key` is the last arg with no positional arg after it. `produce_receipt` returns the delivery-receipt promise; `produce_await` blocks for it and returns the result. There is deliberately no fire-and-forget producer entry point: discarding a receipt discards the delivery outcome.
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

2. **When Writing Code**:
   - Refer to `README.md` for foundational architecture rules.
   - Refer to the `*.md` spec file co-located with the package you are working in (e.g. `framework/ocaml/kafka-eio-service/kafka-eio-service.md`) for feature implementation guidelines. For `kafka-eio-core`/`producer`/`consumer`, the spec docs live in the external `~/Code/kafka-eio` repo. For `obs-eio`/`obs-loki-eio`/`obs-prometheus-eio`, the spec docs live in their respective external `~/Code/obs-*` repos. For `pg-eio`, the spec doc (`README.md`) lives in the external `~/Code/pg-eio` repo.

3. **At Task Completion / Session End**:
   - Record completion and implementation hurdles in the relevant ticket and PR.
   - If a major milestone is hit, update the status checklist in `docs/ROADMAP.md`.

## Comments: none in covered formats

Covered source and config formats carry **no comments**: `.ml`/`.mli`, shell
(including the extensionless git hooks),
Terraform, TypeScript and Python (REFAC-142), and dune files and Dockerfiles
(REFAC-143). `internal/ci/check_no_comments.sh` enforces every one of them, reading
shell through `shfmt`'s parser and Python through `tokenize`. A directive a tool
genuinely needs is the one exception: `#!`, `# shellcheck`, `// @ts-…`,
`/// <reference`, `# noqa`, `# type:`, and a Dockerfile's leading `# syntax=`.

Write the code so it explains itself, and put what is left where a reader finds
it:

- an **executable invariant** belongs in a type, a shared definition, a guard or a
  test, never in a comment beside it;
- **durable rationale** — why this exists, what it replaced, what it protects —
  belongs in `docs/`, `internal/`, or the ticket or decision record that owns it;
- **user-facing explanation** belongs in the documentation that ships with the
  generated artifact (a scaffolded `README.md`, the tutorial), so a workspace
  never loses context because its Dockerfile stopped explaining itself.

Deliberately not covered, and not to be swept opportunistically: workflow, Helm
and scaffold/example YAML, the `.tftpl` templates (no semantic-equivalence check
for rendered River config), and `internal/qualification/**` (live-run records).

**CI tooling: shell orchestrates, programs parse.** A guard that inspects
Terraform, YAML or JSON reads it structurally — Terraform through
`internal/ci/lib/tfconfig.py` (python-hcl2), YAML through PyYAML, both pinned in
`internal/ci/requirements.txt` and installed for CI and for a developer by
`internal/tooling/scripts/prepare-guard-tools.sh` — never by grepping its text, whose verdict then
depends on formatting. Such a guard is a `.py` file, not Python embedded in a shell
heredoc. Shell stays for what shell is for: running processes, git plumbing,
installation and live qualification. A guard's mutation test must fail the guard
for the reason under test, so a mutation that breaks something else cannot pass
as caught.

## Verifying claims before you report them

This repo's whole recent arc is about *not* treating absence of evidence as
evidence of absence (FND-0021, DEC-040). Hold your own claims to the same rule —
several wrong conclusions in this repo came from an agent's search, not the code.

- **An "X is unused / absent / never happens" claim must name the exact command
  you ran, and include a positive control** (a case you know should match). A
  search that silently excludes the file that *declares* X proves nothing: the
  first `omit` finding here was wrong exactly that way. When in doubt, run the
  real binary on a throwaway copy and show the output rather than reasoning from
  line numbers.
- **`ripgrep` is recursive by default. `-r` is `--replace`, not recursive.** Using
  `rg -rn '<pat>' dir` silently rewrites matches to `n` and produces garbage you
  may not notice. Use `rg -n`, and if you see mangled output, suspect `-r`.
- **Quote times in UTC.** `gh` emits UTC (`...Z`); a container's local `date` may
  differ by hours. Do not compute a duration by mixing the two (this made a
  12-minute CI job look like 21 minutes).
- **Reproduce, don't summarize.** If a claim will frame a decision, put the
  verbatim command and its observed output in the finding/ticket, so the reader
  can re-run it instead of trusting the summary.

## Calibration: rapid development with reasonable assurance

Sol is pre-alpha, and the goal is to get the architecture built and qualified quickly. Rigor goes where it buys information, not everywhere at once. The standard depends on the kind of work (operator, 2026-09-27):

| Work | Standard |
|---|---|
| Ordinary development | Fast iteration: compile, format, the targeted tests for the change, then the full required CI on the PR's own head. Keep moving through ordinary engineering friction; do not stop to ask. |
| Architectural decision | Stop for the operator. |
| Live qualification | Strict evidence, no in-run remediation (the qualification ledger's rules). |
| Destructive action, or security ambiguity | Stop. |
| Landing a PR | Queue native squash auto-merge by default; monitor it to completion and report the outcome. An immediate, in-session merge is the exception. |

The assurance stack for code is: compile, format and targeted tests locally; full required CI on the PR head; post-merge CI on `main` as the backstop for rare cross-PR interactions. A PR need not be retested solely because `main` advanced (see the protection bullet below).

## Autonomy: decide, don't defer

**Exercise engineering judgment aggressively; exercise product and architecture
authority conservatively.** The objective is working through the backlog — not keeping
every intermediate state green, and not fitting each unit of work inside one session. The
failure this section exists to stop is an agent that ends a session with a
reconnaissance-only PR because implementation "would not fit", or that asks the operator
to adjudicate ordinary ownership and triage. Autonomy that defers whenever judgment is
required is not autonomy.

**Finish a session by running out of executable work, or by hitting a real fork — never by
tidying up.**

- **Do not postpone implementation because it is large, spans sessions, or cannot end
  green.** An active worktree may hold incomplete or non-compiling work: keep canonical
  `main` green, not the worktree. Leave a precise checkpoint and continue from it next
  time.
- **Reconnaissance is a means to implementation, not a deliverable.** Record findings in
  the ticket and start building. Do not open "pickup record" or "recon only" PRs unless a
  ticket explicitly asks for one.
- **Resolve ordinary questions yourself:** which worktree owns a ticket (infer it from the
  active trees and avoid the conflict); taking ownership of unowned executable work in
  your stream; reconciling a ticket that objectively fails the READY criteria; closing a
  ticket that in-flight work has mooted; inspecting a dirty orphan worktree, preserving
  what is useful and adopting it; reading upstream source when behaviour is uncertain; and
  removing a clean, obsolete worktree that would lose no commits.
- **Do not stop merely because** the next change is large; the work spans sessions; there
  is no green intermediate state; a ticket or PR just completed; a worktree is dirty; a
  more reconnaissance would answer an engineering question; or the decision in front of
  you is reversible.

**Stop for the operator only for a major unresolved design decision** — after the
reconnaissance, materially different choices remain and picking one would change what Sol
means: its architecture, public contract, correctness guarantees, persistence or security
model, or product direction. The test:

> **Can more engineering, code reading, testing, history inspection, or repository
> convention answer this?** → answer it yourself.
>
> **Does somebody have to choose what Sol should mean, because the evidence genuinely
> permits materially different designs?** → ask the operator.

Session and context limits are not design questions. When one approaches, leave the
worktree and the ticket in a precise resumable state after doing as much implementation as
possible — never withhold implementation in order to end on a clean or landed boundary.

**Repair understood workflow friction in place; do not escalate it.** A failure whose mechanism is fully understood — a local checkout colliding with a worktree, a tool whose exit code does not reflect the remote outcome, an instruction that sequences a gate after the action it gates — is fixed in the instructions or the tooling directly, in the same session, without asking. Operator boundaries are for what the table above names: architectural decisions, live qualification, destructive actions and security ambiguity. "Say the word and I'll file it" is the wrong shape for a known local tooling defect; fix it and say what changed.

## Shepherding PRs to merge

Once a PR is ready, use GitHub's native auto-merge when appropriate and monitor required CI to completion. Do not bypass required checks. If CI or review finds a real defect, fix it on the same branch; if the PR becomes obsolete, close it. GitHub is the authority for PR, review, check, and merge state.
