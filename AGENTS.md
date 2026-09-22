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

**Phase 7 core deliverables complete.** `sol deploy <env>/<provider>/<region>` takes a required target positional (same convention as `sol plan`) plus `--image-tag`, `--registry`, `--emit-to` (GitOps), and `--dry-run` flags; the target resolves `sol.yml`/target-file defaults and the `env` manifest label (FEAT-026). YAML rendering is shared by `sol up` and `sol deploy`. Terraform modules live at `cli/platform/infra/base/`, `cli/platform/infra/aws/`, and `cli/platform/infra/gcp/`. Remaining hosted-product work is tracked in `internal/pipeline/tickets/`. See `docs/planning/WORK_SUMMARY.md` for full details.

Package: `cli/sol/` — binary at `_build/default/cli/sol/bin/main.exe`.

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

Review and merge readiness live entirely on the PR, not on a ticket directory: `soldev pipeline review <ticket-id>` leaves its verdict as a plain PR comment either way — a `SOLDEV-REVIEW: PASS`-marked comment on pass, an ordinary violations comment on fail. It's a comment rather than a formal GitHub review because this is a solo-owned repo: the `gh` identity is always the PR's own author, and GitHub refuses to let an author formally approve their own PR. A bounce just means another commit on the same open PR, this repo's established convention, never a ticket-directory round trip. `soldev pipeline merge` checks the PR for that pass-marker comment and green CI directly against GitHub before it will act, then runs `gh pr merge --squash --delete-branch --admin` — the `--admin` bypasses branch protection's separate 1-approval requirement (which, for the same self-approval reason, this repo can never satisfy natively); required status checks still gate the merge for real. A post-merge regression is handled by reverting that one squash commit, which un-does the code *and* the ticket's `DONE` move together (they were always the same commit) — the ticket lands back in `READY_FOR_ENGINEERING` automatically, with no separate "blocked" state to move it out of.

**Ticket frontmatter fields:** `id`, `type` (ux-finding | audit-finding | feature | bug), `severity`, `source`. `branch`/`worktree`/`pr` are no longer persisted on `main` — they're only meaningful while a ticket has an open PR, which `soldev pipeline ls`/`check` surface live from GitHub instead.  
Do not add a `status:` field — the directory encodes status.

**Human-judgment gates:** Tickets in `BACKLOG/` may contain `## Open Questions`, `## Decision Required`, or `## Blocked On` sections. Tickets in `READY_FOR_ENGINEERING/` are treated as actionable, so `/work` must stop before creating a worktree if any unresolved decision section or marker remains. Resolve the decision in the ticket body or keep the ticket in `BACKLOG/` until the Remediation is unambiguous.

**Ticket dependencies:** Use a body line near the top of each ticket: `**Depends on:** None.` or `**Depends on:** FEAT-003, EXP-008.` **Every ticket id on that line becomes a dependency**, whatever prose surrounds it — so a mention like `Implemented by FEAT-059` or `Related: DEC-016` creates a dependency you did not intend, and two tickets referring to each other that way deadlock. Put other mentions on their own line. `/work` must verify dependencies before creating a worktree. A `READY_FOR_ENGINEERING` ticket with dependencies not yet in `internal/pipeline/tickets/DONE/` stays blocked; if a cycle does form, `soldev pipeline check` and `pipeline ls` report it as a cycle rather than as ordinary waiting.

**Ticket titles:** The PR title and the listing summary both come from the ticket body — an explicit `title:` frontmatter field when present, otherwise the first line that is not a bold-labelled field, with Markdown heading markers stripped. So either state `title:` or open the body with a real title sentence. Two ways this goes wrong, both observed: opening with a paragraph of argument produces a PR subject that reads as a sentence, and opening with a labelled field (any `**Label:**`, not just `**Depends on:**`) makes that field the displayed summary.

**Ticket premises:** A ticket is written at discovery time and rarely re-read, while the code moves on — so before starting a non-`DONE` ticket, verify its *premise* (the claim that the work is still missing) and record that in one line in the ticket, with what was checked. For findings that reduce to an existence check, declare the probe instead and let the pipeline evaluate it:

```yaml
premise: "rg -q 'fallback_to_kubectl' cli/sol/bin/cmd_logs.ml"
```

**The probe succeeds when the premise is stale** — the finding has already been fixed. The inverted form is deliberate: the natural form would need every probe wrapped in a negation, and a mis-negated probe fails in the direction of "still actionable", which is the exact failure this exists to catch. `soldev pipeline check` runs it and reports `premise-stale` or `premise-unverified` instead of `actionable`; `pipeline ls` shows the same in its label column. A probe that cannot run at all (exit 126/127) is `unverified`, never "holds".

Two rules for writing one: **`check` echoes the command before running it, and a probe is shell supplied by whoever wrote the ticket — read it before you let it run.** And keep the probe cheap and read-only; it runs on every `ls`, so a probe with side effects runs on every listing.

**Demo/example coverage:** Any ticket that changes what an app author does — a new `sol.toml` field, a framework primitive or runtime contract, a new CLI command, or changed generated manifests — must update a runnable example or demo (`examples/`, a tutorial code sample, or the scaffolded workspace) in the same ticket, and must say so in its Acceptance criteria. If a demo genuinely does not apply (internal refactor, pure documentation), state that in one line in the ticket's completion notes. "The CI smoke covers it" is not sufficient: a smoke test is a test, not a reference a user can read or run. New example Dockerfiles go in the `example-dockerfile-smoke` CI matrix, and demo-facing changes run `/demo-review`.

**TypeScript-parity tracking (DEC-022):** Sol's platform is language-neutral, and OCaml and TypeScript are both first-class application languages. Parity is **capability + behavioural parity, not implementation parity** — the contract (schema-registry conventions, Confluent wire format, W3C trace propagation, retry/DLQ semantics, metric-naming/label vocabulary, lifecycle/shutdown, config/secrets, job semantics) must hold across languages, while the implementation underneath need not be shared (`kafka-eio`/`pg-eio` stay OCaml; TypeScript keeps the Node ecosystem and Sol supplies only the semantics/glue). Every application-facing capability carries a per-language verdict — **implemented / already equivalent / intentionally deferred / not applicable**; silence is not a verdict, and deferring a language is an explicit, recorded decision with a trigger, never default debt. Two conformance levels both matter: the **TS golden path** (`sol new --language typescript` → `sol local up` → `sol deploy`, adoption/DX — FEAT-082) and the **capability matrix** (per-capability verdicts, architectural parity — the inventory in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` + FEAT-080). Concretely: any ticket that changes one of those conventions, or introduces a new framework-level concept an app author gets "for free" (a new primitive, a new library like `sol-jobs`, a new retry/backoff/observability contract), must check the cross-language gap and say so in one line in its completion notes — "no language-parity impact" with why, or a reference to the tracking ticket recording what the other language would now need. This is bookkeeping, not permission-gating — it keeps the two frameworks from silently drifting the way FEAT-076 through FEAT-079 accumulated against a spike that predated them.

**Worktree isolation (REFAC-090):** each concurrent actor owns one worktree, and agents do not perform mutating work in the canonical checkout — that checkout belongs to the human operator, and its branch can change underneath an actor midway through a commit, producing a commit that is *valid but in the wrong place*. The authoritative statement, the checks to resolve before every commit and push, and the recovery for a stale hook install live in `CONTRIBUTING.md` § *Isolation and ownership*; the preflight is `internal/ci/check_authority.sh`, wired into the pre-commit hook. That section is the one place to keep true — this file does not restate the policy.

**But name the tree on every mutating command (observed twice in one session).** The preflight catches a *commit* in the wrong place, and only when a context is declared — so it cannot catch the more common failure, which is a **staging** operation: `git add` / `rm` / `mv` / `checkout` run after a `cd` into the canonical checkout stages changes *there*, and every later check passes while the edit is in the wrong repository. Both occurrences were exactly that — a file written into the wrong worktree, and a ticket `git rm`'d from canonical — and in the second the canonical checkout sat with a staged deletion until a later sweep found it.

The discipline, since relying on remembering the current directory has now failed twice:

- **Pass the tree explicitly** — `git -C <worktree> …`, or set `cd` inside the same command and never inherit it. `cd` persists across tool calls; the working tree you *think* you are in is the least reliable fact in the session.
- **After any batch that touched git, verify the canonical checkout is clean:** `git -C <canonical> status --porcelain` must print nothing. A non-empty canonical checkout is a bug in the workflow, not somebody's local edit — treat it as one and restore it.
- **Prefer `git worktree add … origin/main`** over the local `main` ref, so a stale canonical checkout never silently bases work on an old commit and there is no reason to reset that checkout at all.

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

**Performance baseline:** `internal/tooling/perf/perf_baseline.json` is main-only and informational. `run_tests.sh` writes it only with `--update-baseline`; pre-commit never stages it into code commits; merges never revert on perf-ratio regressions (REFAC-078). `.gitattributes` keeps `merge=ours` for local merges.

## Core design principles every engineer must know

**Security on Day 1.** `Kafka_security.t` is a first-class field in every producer, consumer, and service config. `config_of_env()` reads `KAFKA_SECURITY_PROTOCOL`, `KAFKA_SSL_CA_LOCATION`, `KAFKA_SASL_*` from the environment. Dev defaults to `Plaintext`; the type forces all other environments to state their security posture explicitly. Do not add Kafka config anywhere that lacks a `security` field.

**Dev mirrors prod exactly.** `sol local infra up` runs the same Helm charts as production at single-replica scale. Port-forwards expose every service at the same address the service code expects. If there's a divergence between dev and prod addressing or configuration, that divergence is a bug.

**The primary axis takes the positional (DEC-031, over DEC-032's axes).** A command has three possible axes — `target` (where), `scope` (what), `view` (which operational concern) — and exactly one of them is *primary* for that command. The primary axis is the positional argument; every other axis is a flag. Writing a new command means deciding which axis it is addressed by, and that decision is what the positional carries:

- addressed **by scope** → scope positional, target `--target`: `sol status [SCOPE]`, `sol open <view> [SCOPE]`;
- addressed **by target** → target positional, scope `--scope`: `sol up <TARGET>`, `sol deploy <TARGET>`, `sol cloud plan|apply|destroy <TARGET>`, `sol plan`.

This is why `sol status payments/checkout-svc` and `sol up local --scope payments/checkout-svc` are both correct and are not inconsistent. Do not add a `--scope` flag to a scope-primary command or a positional scope to a target-primary one to "make them match"; the split is the rule.

Accepted scopes are **not** uniform, and widening one is a feature, not consistency: `sol status` / `sol open` take workspace, `domain`, `domain/unit`, and `resource/<type>/<name>`; the `--scope` commands resolve `domain` and `domain/unit` through `Sol_cli_workload_selection`; and **`sol logs` is deliberately unit-only** — a workspace- or domain-wide Loki query is a different feature with its own cost and pagination shape, so `sol logs --scope payments` is an error rather than a wider query. The shared thing is the selector *grammar* (`domain` and `domain/unit` mean the same everywhere), not the set of surfaces that accept each scope.

## What this repo is

Sol is an opinionated production platform for backend systems. Its platform/CLI is written in OCaml and is language-neutral in what it does; OCaml and TypeScript are both first-class application languages (DEC-022). Kafka layer, observability backends, all three service primitives (`-svc`, `-worker`, `-fn`), storage (PostgreSQL), and CLI scaffold commands are complete.

## Repo layout

```
sol/
  # ── product ───────────────────────────────────────────────────────────────
  cli/                          ← the `sol` CLI (cli/sol) + the platform it drives (cli/platform)
    sol/{bin,lib,test}/         ← command parsing, shared implementation, tests
    platform/{components,infra,local}/  ← Helm values, Terraform roots, local k3s tooling
  contract/                     ← language-neutral application contract (runtime, substrate)
  framework/ocaml/              ← first-party OCaml framework packages
    sol-svc/lib/                ← REST API service (routes, auth, metrics)
    sol-worker/lib/             ← Kafka consumer (schema registration, per-message metrics)
    sol-fn/lib/                 ← Scheduled function (Pushgateway push, invocation metrics)
    sol-jobs/lib/               ← Postgres-backed leased job library, hosted by a -worker (FEAT-077)
    sol-*/sol-*.md              ← per-package spec docs
    kafka-eio-service/lib/      ← schema registry + service orchestration, depends on `kafka-eio.*`
  examples/pluto/               ← canonical reference application (OCaml + TypeScript, local + cloud)
  docs/                         ← architecture, deployment, guides, hosted, legal, planning
  internal/                     ← maintainer machinery (not product)
    ci/                         ← CI guardrails, classifier, mutation tests
    qualification/aws/          ← live AWS smoke harness + smoke toolkit
    pipeline/                   ← tickets/, audits/, dogfood/
    tooling/                    ← soldev, sol_process, hooks/, perf/
    fixtures/                   ← test fixtures (OCaml-only worker workspace, e2e demo)
  # ── package contracts ────────────────────────────────────────────────────
  *.opam                        ← 9 hand-written package contracts (DEC-025); pin root for `internal/tooling/soldev`
  dune-project / dune-workspace ← unified root build
  README.md / docs/planning/ROADMAP.md / docs/planning/WORK_SUMMARY.md  ← project-wide docs

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
  dune exec internal/fixtures/local-demo/bin/demo.exe

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
   - Refer to the `*.md` spec file co-located with the package you are working in (e.g. `framework/ocaml/kafka-eio-service/kafka-eio-service.md`) for feature implementation guidelines. For `kafka-eio-core`/`producer`/`consumer`, the spec docs live in the external `~/Code/kafka-eio` repo. For `obs-eio`/`obs-loki-eio`/`obs-prometheus-eio`, the spec docs live in their respective external `~/Code/obs-*` repos. For `pg-eio`, the spec doc (`README.md`) lives in the external `~/Code/pg-eio` repo.

3. **At Task Completion / Session End**:
   - Update `docs/planning/WORK_SUMMARY.md` to accurately reflect what was accomplished, what is currently "In Progress", and any new implementation hurdles or blockers discovered.
   - If a major milestone is hit, update the status checklist in `docs/planning/ROADMAP.md`.

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

## Shepherding PRs to merge

Merge readiness is a **PR comment**, not a review state (`gh` is always the PR's
own author here). The mechanics that are easy to get wrong:

- **The pass marker is `SOLDEV-REVIEW: PASS <head-sha>` as the *first line*, and
  only the temporally-last such comment counts.** Any commit after it — including
  a branch update that merges `main` — invalidates it, because the embedded SHA no
  longer equals the head. Re-run `soldev pipeline review <ticket>` after updating.
- **Non-ticket PRs (`audit/*`, `dec/*`) can't use `soldev pipeline review`** (it
  finds the PR by `<ticket-id>/` branch prefix). Post the same marker by hand:
  `SOLDEV-REVIEW: PASS <head-sha>`.
- **A batch branch has the same problem, and it fails quietly.** `docs/DOCS-018-019`
  does not start with `DOCS-018/`, so `soldev pipeline review DOCS-018` reports
  *"no open PR found"* — the marker is never posted — while the PR is still
  mergable enough to go through. Observed on #432: two tickets landed with no
  `SOLDEV-REVIEW` comment at all. Batch branches are still worth it (one CI cycle
  for several independent items, and the ticket-move guard reads *every* id in the
  name, so they all must move), but **check the marker landed** before merging, or
  post it by hand; do not read "merged" as "the marker step ran".
- **Protection is `strict` + `enforce_admins`.** `--admin` bypasses the 1-approval
  requirement but **not** required checks, and a branch **behind `main`** cannot
  merge ("Required status check is expected"). So each merge makes the next branch
  behind: **one CI cycle per item, serially** — update from `main`, wait for green,
  re-marker, merge. (An integration branch with one CI run is cheaper for a batch
  of independent, non-overlapping items.)
- **Merge dependent PRs by hand, in order.** `soldev pipeline merge` (no argument)
  sweeps in branch-label order (`[audit]`, `[dec]`, …), which can invert a
  dependency — e.g. merging a decision PR before the finding it cites.
- **The branch name declares the ticket, and CI holds you to it.** The *Ticket-move
  guard* reads the id from the branch name (`fix/infra-048-namespace-create`,
  `INFRA-061/probe-tri-state`), the worktree directory (`sol-INFRA-049-omit-authority`)
  or a `(<ID>)` in a commit subject, and refuses a PR whose branch names a
  `READY_FOR_ENGINEERING` ticket without moving it to `DONE/`. Landing one part of a
  longer ticket is fine — declare it in a subject, `(INFRA-057, part A)` — but a
  branch that names no ticket is exempt. This exists because four tickets once sat in
  READY with their fix already merged (`INFRA-048`, `INFRA-050`, `INFRA-057`), each
  costing the next worker a cycle.
- **`merge-finish` runs `./cli/platform/local/scripts/run_tests.sh` locally, but a
  local failure is only *reported* — nothing is reverted** (BUG-033). That suite
  needs local kafka/e2e infra (`localhost:9092`); without it, kafka/e2e fail and the
  pipeline prints that the merge stands and `origin/main` is untouched. That is
  correct: the merge already passed GitHub's required checks, and a local suite
  reflects this machine, not the branch of record. Nothing to undo, so no
  `git reset` dance — if you want a real revert, do it deliberately on the remote
  (`git revert <sha> && git push origin main`). `rc=2` is a perf ratio and is
  informational only. The one local commit `merge-finish` still makes is the perf
  baseline, which is why it reminds you to push.
- **Run the format check before pushing.** CI's *Format check* step is
  `internal/ci/check_ocamlformat.sh --all` (ocamlformat 0.29.0, janestreet
  profile); a local `dune build` does **not** cover it, so unformatted code is a
  guaranteed CI bounce that costs a full run. Run
  `internal/ci/check_ocamlformat.sh --staged` (staged files only, so unrelated
  work-in-progress cannot block you) or `dune fmt` before pushing. The pre-commit
  hook runs the `--staged` check too, once installed
  (`cli/platform/local/scripts/install-hooks.sh`) — it is not installed by
  default.
- **`gh` gaps in this environment:** `gh pr update-branch` does not exist (update
  locally instead), and `gh pr edit` fails with a Projects-classic GraphQL
  deprecation — set the body via
  `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@file`.
