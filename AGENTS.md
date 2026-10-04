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

**Phase 7 core deliverables complete.** `sol deploy <env>/<provider>/<region>` takes a required target positional (same convention as `sol plan`) plus `--image-tag`, `--registry`, `--emit-to` (GitOps), and `--dry-run` flags; the target resolves `sol.yml`/target-file defaults and the `env` manifest label (FEAT-026). YAML rendering is shared by `sol up` and `sol deploy`. Terraform lives under `platform/cloud/`: the shared platform module `modules/platform/`, and per-provider `bootstrap/`, `cluster/` and `platform/` roots that mirror each other (DEC-046 rule 4). Remaining hosted-product work is tracked in `internal/pipeline/tickets/`.

Package: `cli/` — binary at `_build/default/cli/bin/main.exe`.

## Ticket system

Work is tracked in `internal/pipeline/tickets/` using a directory-per-status layout. Each ticket is a markdown file with YAML frontmatter.

```
internal/pipeline/tickets/
  BACKLOG/                  ← captured but not yet prioritised
  READY_FOR_ENGINEERING/    ← actionable; pick up with /work — covers "not started"
                               through "PR open, in review": GitHub's own open-PR/
                               review/CI state already tracks that, no local
                               directory duplicates it
  DONE/                     ← merged
```

**Implementation state machine (REFAC-077):** `READY_FOR_ENGINEERING` → `DONE`.
Triage may promote or demote between `BACKLOG` and `READY_FOR_ENGINEERING`, and
reverting a merged implementation returns `DONE` to `READY_FOR_ENGINEERING`.
There is no separate "in progress," "in review," "ready to merge," or
"blocked by performance" directory any more.

Every `internal/pipeline/tickets/` change goes through a PR. New findings are created in
`BACKLOG/` or `READY_FOR_ENGINEERING/` on the audit/filing branch; promotions,
corrections, and other bookkeeping use their own branches. An implementation
branch moves its own ticket from `READY_FOR_ENGINEERING/` to `DONE/` in the
final commit, so `gh pr merge --squash` carries the code and ticket completion
into `main` atomically. Reverting that squash commit reverses the move too.

Merge readiness lives on the PR, not a ticket directory. Routine refactors,
documentation, and filings use focused author validation and required green CI;
no review marker or approving-review count is required. Select targeted review
for infrastructure, security, lifecycle/concurrency, substantial API changes, or
an operator request, and keep the PR draft until actionable findings are resolved.
One satisfactory targeted pass is sufficient. `soldev pipeline review` still
posts optional informational verdicts; they are not universal merge gates.

**Auto-merge is the default.** Queue `soldev pipeline merge <id>` as soon as
a PR is non-draft with its prerequisites resolved; GitHub lands it the moment
required checks pass. `soldev pipeline merge --pr <n>` does the same for a PR that
names no ticket. Waiting for green and then merging by hand is the exception,
not the routine: it is the opt-in `--immediate`, allowed only when required checks
are already green. The command pins the head SHA, rejects drafts/unresolved
prerequisites, uses no admin bypass, and preserves local worktrees. Whoever queues
a merge monitors it to completion and reports whether it actually merged
(§ *Shepherding PRs to merge*). Reverting the squash returns its ticket to READY
atomically.

**Ticket frontmatter fields:** `id`, `type` (refactor | feature | bug | audit-finding | decision | ux-finding | dogfood-finding | docs-finding | code-layer-finding | verification | release | infra | performance | documentation), `severity`, `source`. `branch`/`worktree`/`pr` are no longer persisted on `main` — they're only meaningful while a ticket has an open PR, which `soldev pipeline ls`/`check` surface live from GitHub instead.  
Do not add a `status:` field — the directory encodes status.

**Human-judgment gates:** Tickets in `BACKLOG/` may contain `## Open Questions`, `## Decision Required`, or `## Blocked On` sections. Tickets in `READY_FOR_ENGINEERING/` are treated as actionable, so `/work` must stop before creating a worktree if any unresolved decision section or marker remains. Resolve the decision in the ticket body or keep the ticket in `BACKLOG/` until the Remediation is unambiguous.

**Tickets are for work that can finish.** A standing goal that never closes — "qualify the production profile on a provider", as HARDEN-002 and HARDEN-004 were — does not belong in `READY_FOR_ENGINEERING/`, where `/work` treats it as actionable and later work gets credited to it instead of to the ticket it implements. Standing qualification goals live in the qualification ledger (`internal/qualification/README.md`, the matrices, `internal/pipeline/audits/QUALIFICATION_STATUS.md`); each live run is its own ticket, gated in `BACKLOG/` on explicit authorization. When work implements a ticket, name *that* ticket on the branch or in the commit subject, so the Ticket-move guard moves it.

**Ticket dependencies:** Use a body line near the top of each ticket: `**Depends on:** None.` or `**Depends on:** FEAT-003, EXP-008.` **Every ticket id on that line becomes a dependency**, whatever prose surrounds it — so a mention like `Implemented by FEAT-059` or `Related: DEC-016` creates a dependency you did not intend, and two tickets referring to each other that way deadlock. Put other mentions on their own line. The field is exactly one line: a wrapped continuation is never parsed, so `soldev pipeline validate` rejects it (BUG-114) — put commentary in its own paragraph. `/work` must verify dependencies before creating a worktree. A `READY_FOR_ENGINEERING` ticket with dependencies not yet in `internal/pipeline/tickets/DONE/` stays blocked; if a cycle does form, `soldev pipeline check` and `pipeline ls` report it as a cycle rather than as ordinary waiting.

**Ticket titles:** The PR title and the listing summary both come from the ticket body — an explicit `title:` frontmatter field when present, otherwise the first line that is not a bold-labelled field, with Markdown heading markers stripped. So either state `title:` or open the body with a real title sentence. Two ways this goes wrong, both observed: opening with a paragraph of argument produces a PR subject that reads as a sentence, and opening with a labelled field (any `**Label:**`, not just `**Depends on:**`) makes that field the displayed summary.

**Ticket premises:** A ticket is written at discovery time and rarely re-read, while the code moves on — so before starting a non-`DONE` ticket, verify its *premise* (the claim that the work is still missing) and record that in one line in the ticket, with what was checked. For findings that reduce to an existence check, declare the probe instead and let the pipeline evaluate it:

```yaml
premise: "rg -q 'fallback_to_kubectl' cli/bin/cmd_logs.ml"
```

**The probe succeeds when the premise is stale** — the finding has already been fixed. The inverted form is deliberate: the natural form would need every probe wrapped in a negation, and a mis-negated probe fails in the direction of "still actionable", which is the exact failure this exists to catch. A probe has exactly three outcomes: **exit 0 ⇒ premise stale, exit 1 ⇒ premise holds, any other exit ⇒ unverified** — a probe that did not reach a conclusion is never reported as one of the two verdicts, and its exit code and output are shown. A probe that names a repository path which does not exist is unverified as well: a moved file is the common cause, and the negated form (`! rg -q x gone/file`) would otherwise report "stale" from a read that never happened. `soldev pipeline check` runs it and reports `premise-stale` or `premise-unverified` instead of `actionable`; `pipeline ls` shows the same in its label column.

The frontmatter is YAML, read with a YAML parser (REFAC-137), and every ticket's frontmatter must parse: quote a value containing `: `, ` #`, or a leading `` ` ``, and write a probe with backslashes in single quotes (`'...'`, a `'` inside doubled as `''`), where YAML takes the text literally.

Two rules for writing one: **`check` echoes the command before running it, and a probe is shell supplied by whoever wrote the ticket — read it before you let it run.** And keep the probe cheap and read-only; it runs on every `ls`, so a probe with side effects runs on every listing.

**Demo/example coverage:** Any ticket that changes what an app author does — a new `sol.toml` field, a framework primitive or runtime contract, a new CLI command, or changed generated manifests — must update a runnable example or demo (`examples/`, a tutorial code sample, or the scaffolded workspace) in the same ticket, and must say so in its Acceptance criteria. If a demo genuinely does not apply (internal refactor, pure documentation), state that in one line in the ticket's completion notes. "The CI smoke covers it" is not sufficient: a smoke test is a test, not a reference a user can read or run. New example Dockerfiles under `examples/` or `internal/fixtures/` are built automatically — `internal/tooling/scripts/dockerfile_matrix.py` derives the `example-dockerfile-smoke` and `demo-ts-dockerfile-smoke` matrices from `git ls-files`. Select `/demo-review` for substantial app-author API/lifecycle changes or when requested, not routine example refactors.

**TypeScript-parity tracking (DEC-022):** Sol's platform is language-neutral, and OCaml and TypeScript are both first-class application languages. Parity is **capability + behavioural parity, not implementation parity** — the contract (schema-registry conventions, Confluent wire format, W3C trace propagation, retry/DLQ semantics, metric-naming/label vocabulary, lifecycle/shutdown, config/secrets, job semantics) must hold across languages, while the implementation underneath need not be shared (`kafka-eio`/`pg-eio` stay OCaml; TypeScript keeps the Node ecosystem and Sol supplies only the semantics/glue). Every application-facing capability carries a per-language verdict — **implemented / already equivalent / intentionally deferred / not applicable**; silence is not a verdict, and deferring a language is an explicit, recorded decision with a trigger, never default debt. Two conformance levels both matter: the **TS golden path** (`sol new --language typescript` → `sol local up` → `sol deploy`, adoption/DX — FEAT-082) and the **capability matrix** (per-capability verdicts, architectural parity — the inventory in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` + FEAT-080). Concretely: any ticket that changes one of those conventions, or introduces a new framework-level concept an app author gets "for free" (a new primitive, a new library like `sol-jobs`, a new retry/backoff/observability contract), must check the cross-language gap and say so in one line in its completion notes — "no language-parity impact" with why, or a reference to the tracking ticket recording what the other language would now need. This is bookkeeping, not permission-gating — it keeps the two frameworks from silently drifting the way FEAT-076 through FEAT-079 accumulated against a spike that predated them.

**Worktree isolation (REFAC-090):** each concurrent actor owns one worktree, and agents do not perform mutating work in the canonical checkout — that checkout belongs to the human operator, and its branch can change underneath an actor midway through a commit, producing a commit that is *valid but in the wrong place*. The authoritative statement, the checks to resolve before every commit and push, and the recovery for a stale hook install live in `CONTRIBUTING.md` § *Isolation and ownership*; the preflight is `internal/ci/check_authority.sh`, wired into the pre-commit hook. That section is the one place to keep true — this file does not restate the policy.

**Refreshing canonical `main` is allowed:** if it is clean, fetch `origin`, fast-forward `main` with `git merge --ff-only origin/main`, and verify `HEAD == origin/main`. Do not edit, stage, or commit there; use an owned worktree for all repository changes. If synchronization fails, diagnose it before relying on that checkout for an audit.

**But name the tree on every mutating command (observed twice in one session).** The preflight catches a *commit* in the wrong place, and only when a context is declared — so it cannot catch the more common failure, which is a **staging** operation: `git add` / `rm` / `mv` / `checkout` run after a `cd` into the canonical checkout stages changes *there*, and every later check passes while the edit is in the wrong repository. Both occurrences were exactly that — a file written into the wrong worktree, and a ticket `git rm`'d from canonical — and in the second the canonical checkout sat with a staged deletion until a later sweep found it.

The discipline, since relying on remembering the current directory has now failed twice:

- **Pass the tree explicitly** — `git -C <worktree> …`, or set `cd` inside the same command and never inherit it. `cd` persists across tool calls; the working tree you *think* you are in is the least reliable fact in the session.
- **After any batch that touched git, verify the canonical checkout is clean:** `git -C <canonical> status --porcelain` must print nothing. A non-empty canonical checkout is a bug in the workflow, not somebody's local edit — treat it as one and restore it.
- **Prefer `git worktree add … origin/main`** over the local `main` ref, so a stale canonical checkout never silently bases work on an old commit and there is no reason to reset that checkout at all.

**Skills that interact with tickets:**
- `/work` — unified entry point; creates worktrees for `READY_FOR_ENGINEERING` tickets with no open PR yet, resumes ones that already have one, runs the review agent on ones ready for it. The worker's own last commit moves the ticket to `DONE/` on the branch before `soldev pipeline submit` pushes it and opens the PR.
- `/review-worktree` — optional targeted review; structured results become informational PR comments.
- `/audit` and `/ux-audit` — materialise new findings into `READY_FOR_ENGINEERING/` (idempotent)

**soldev roles (REFAC-079):** GitHub PRs/CI are the source of truth; `soldev` is an orchestration layer over GitHub, not a second authority.
- `pipeline ls` / `pipeline check` — orchestration: queue view, preflight gates, PR and dirty-worktree annotations.
- `pipeline validate` — validation: reads every ticket in the tree (BACKLOG, READY_FOR_ENGINEERING and DONE) with the same parser the other commands use, and exits 1 naming any it cannot read, any id that differs from its filename, or any id duplicated across states. CI runs it unconditionally, so malformed ticket identity fails its PR instead of disappearing from the queue view (BUG-060, BUG-061).
- `pipeline submit` — orchestration: pushes the ticket branch and opens/reuses the PR. A ticket left in `READY_FOR_ENGINEERING/` is accepted only when the branch declares itself one part of it (`(<ID>, part A)` in a commit subject), and that decision is the same `internal/ci/context/check_ticket_move.sh` the PR check runs — so a partial branch submits and then passes that check instead of one path refusing what the other allows.
- `pipeline review` — orchestration: posts optional structured review findings as PR comments.
- `pipeline merge` — orchestration: verifies prerequisites and non-draft status. It queues native squash auto-merge by default, which lands the PR when required checks pass; `--immediate` is the opt-in synchronous merge, and only when required CI is already green. Targets a ticket id, a pull request via `--pr <n|#n|url>`, or with neither sweeps every open ready PR; a PR target is also refused when its base branch has no required checks configured. Head-pinned; no admin bypass or worktree cleanup.
- `pipeline check-reverts` — safety diagnostic over git history.
- Pre-commit (format + build) and pre-push (`internal/ci/run_fast_checks.sh`: unit tests + fast CI checks) hooks — convenience local gates; GitHub CI is the authoritative PR gate. `SOL_SKIP_HOOKS=1` intentionally allows a one-off local bypass.
- Post-commit hook — informational perf status + orphaned-worktree warnings.
- Ticket filings and promotions go through PRs too; there is no direct-to-main bookkeeping exception.

**Performance baseline:** `internal/tooling/perf/perf_baseline.json` is main-only and informational. `perf.sh record --update-baseline` is the only writer, recording the host class beside each entry so comparisons happen only within one host class; `run_tests.sh` is correctness-only and never touches it, and `perf.sh record` without the flag reports a comparison without writing. Pre-commit never stages it into code commits, and merges never revert on perf-ratio regressions (REFAC-078). `.gitattributes` keeps `merge=ours` for local merges.

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

When a new file has no obvious home, apply these rules rather than copying the tree. The full reasoning and the target layout are in `internal/pipeline/audits/2026-09-25_organization_proposal.md`.

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
  *.opam                        ← 9 hand-written package contracts (DEC-025); pin root for `internal/tooling/soldev`
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
   - Read `docs/ROADMAP.md` and the relevant tickets in `internal/pipeline/tickets/` before writing code.
   - Align your execution path with the active milestone and ticket state.

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
  ticket has no named owner; another repository must change; ticket state needs triage;
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

Routine PRs need required green CI, not a review marker. **Queue native squash
auto-merge by default** — `soldev pipeline merge <id>`, or
`soldev pipeline merge --pr <n>` for a PR that names no ticket — as soon as a PR is
non-draft and its prerequisites are resolved. Do not hold a PR until it is green and
then merge it by hand; an immediate merge is the exception (`--immediate`, and only
with required checks already green), for when the operator wants it landed
synchronously.

- **Monitor every queued auto-merge to completion, and report whether it merged.** A
  queue request is not a completed merge. Read the PR's actual state —
  `gh pr view <n> --json state,mergedAt,mergeCommit,statusCheckRollup`, or
  `soldev pipeline check` — rather than sleeping on an assumed duration: the change
  classifier sends docs-only and ticket-only PRs down a fast path where `test` can
  finish in seconds, so "wait about fifteen minutes" is wrong and has already let a
  green PR sit unmerged. On failure, report the failing check and its cause; after a
  fix, auto-merge is still armed and completes on its own. If the failure is not
  being addressed, say so explicitly rather than leaving it silently queued.
- **A re-run does not pick up a repaired base.** GitHub re-runs the check against the
  merge commit it already computed, so a `test` failure whose cause was on `main` — a
  duplicate ticket id in the tree, a guard another PR had just fixed — repeats
  identically after the fix has merged. `gh run rerun --failed` was observed to do
  exactly that 22 minutes after the repairing PR landed. Compare the run's base with
  `origin/main`; if `main` moved, update the branch (rebase onto `origin/main` and
  push) and re-arm auto-merge for the new head SHA instead of re-running.
- Queue dependent PRs in order: `soldev` reads prerequisites from its current ticket
  tree, so queue a dependent PR only after its dependency has actually merged.

- Keep intentionally reviewed PRs draft until the selected review is satisfactory.
  Review comments are optional evidence, never proof that a gate ran.
- Protection requires `test` on the PR head with admin enforcement, zero mandatory
  approvals, and no up-to-date-branch requirement. Do not merge with `--admin`.
  Do not update/retest a green PR solely because main advanced; reconcile actual
  conflicts or overlapping contracts. Post-merge CI remains the interaction backstop.
- Do not repeat the full local suite after an unrelated branch update. Build,
  format, and relevant tests suffice locally; required CI covers the PR head.
- Use `--match-head-commit <sha>` for direct GitHub commands, and omit
  `--delete-branch`: its local checkout cleanup can fail after the remote merge
  succeeds. Always verify `gh pr view <n> --json state,mergedAt,mergeCommit`;
  an accepted auto-merge request is not necessarily a completed merge.
- Preserve local worktrees. Cleanup is separate, only for demonstrably owned,
  clean trees; never remove a tree with `--force` as a merge prerequisite.
- Merge dependent tickets in order. soldev checks prerequisites from its current
  ticket tree, so refresh the owned tree after dependency merges before retrying.
- **The branch name declares the ticket, and CI holds you to it.** The *Ticket-move
  guard* reads the id from the branch name (`fix/infra-048-namespace-create`,
  `INFRA-061/probe-tri-state`), the worktree directory (`sol-INFRA-049-omit-authority`)
  or a `(<ID>)` in a commit subject, and refuses a PR whose branch names a
  `READY_FOR_ENGINEERING` ticket without moving it to `DONE/`. Landing one part of a
  longer ticket is fine — declare it in a subject, `(INFRA-057, part A)` — but a
  branch that names no ticket is exempt. This exists because four tickets once sat in
  READY with their fix already merged (`INFRA-048`, `INFRA-050`, `INFRA-057`), each
  costing the next worker a cycle.
- **Run the format check before pushing.** CI's *Format check* step is
  `internal/ci/check_ocamlformat.sh --all` (ocamlformat 0.29.0, janestreet
  profile); a local `dune build` does **not** cover it, so unformatted code is a
  guaranteed CI bounce that costs a full run. Run
  `internal/ci/check_ocamlformat.sh --staged` (staged files only, so unrelated
  work-in-progress cannot block you) or `dune fmt` before pushing. The pre-commit
  hook runs the `--staged` check too, and the pre-push hook runs
  `internal/ci/run_fast_checks.sh` (every fast `internal/ci/` guard, in parallel),
  once installed (`internal/tooling/scripts/install-hooks.sh`, which sets
  `core.hooksPath`) — it is not installed by default.
- **Run a guard's mutation suite, not just the guard, when your change touches a
  file that guard inspects.** The guards and their `test_*_check.py` mutation
  suites are part of CI's `test` job, but the suites are not wired into `dune
  test`, so a green local suite says nothing about them. A mutation whose anchor
  another change made ambiguous *aborts the suite* rather than mutating: one
  change naming `Release_unestablished` a second time in
  `sol_cli_cloud_destroy.ml` cost a full CI cycle on an anchor that had been
  unique when it was written. Find them with `rg -l '<changed file>'
  internal/ci/*.py internal/ci/*.sh` and run both the guard and any
  `test_<guard>.py` beside it.
- **`gh` gaps in this environment:** `gh pr update-branch` does not exist (update
  locally instead), and `gh pr edit` fails with a Projects-classic GraphQL
  deprecation — set the body via
  `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@file`.
