# Verification architecture audit

**Date:** 2026-10-01
**Base:** `origin/main` @ `fd138b3a` (PR #861). All line references are to that commit.
**Scope:** `.github/workflows/**`, `internal/ci/**`, `internal/tooling/{hooks,scripts,perf}/**`,
Dune test topology, framework/CLI/integration/E2E/lifecycle/qualification suites,
`platform/local/scripts/**` fixture provisioning, caches, change classification.
**Trigger:** BUG-115 and the Git-hook incident, treated as evidence of a class rather than
two incidents.

## Method, and what was run rather than read

Claims below are labelled **observed** (reproduced here, command and output recorded in
§ *Verification of this audit*) or **risk** (a design consequence read from the code, with the
lines that carry it). Nothing was mutated in the operator's checkout, in shared refs, or in the
shared `sol_dev` database; every experiment ran in `/tmp` or in a scratch worktree.

Commands run: `bash internal/ci/run_fast_checks.sh`; `bash internal/tooling/scripts/run_tests.sh unit`;
`bash internal/ci/test_framework_ci_coverage.sh`; `bash internal/tooling/scripts/perf.sh status`;
three scratch Dune projects proving the caching mechanism and Dune's `(tests (names …))` limit;
one scratch reproduction of the `run_fast_checks` reporting loop; two inventory diffs computed
from the YAML/Dune/script sources; `git ls-files`-based reachability enumeration of every test
stanza; `gh pr view 860` / `gh pr diff 860`.

---

## 1. Current-state map

### 1.1 Evidence flows today

```
                        ┌───────────────────────────── defined in ─────────────────────────────┐
                        │                                                                      │
 .github/workflows/     ci.yml (1713 lines, 9 jobs, 130 named steps, ~70 guard invocations)    │
   ci.yml  ────────────► test  [REQUIRED, single job]                                           │
                         │  ├─ classify → kind: docs-only | source                                │
                         │  ├─ docs-only branch: cached soldev binary → pipeline validate,        │
                         │  │   ticket transitions, ticket move; 25 further steps skipped         │
                         │  └─ source branch: prepare-guard-tools → build → 66 guards+mutation    │
                         │      tests → unit tests (12 dirs, no --force) → lifecycle alias →      │
                         │      integration step (broker+PG, 3 explicit dune targets) →           │
                         │      E2E fixture (--force) → format check → installed-release smoke    │
                         ├─ golden-path-smoke        (k3d, `sol new` + `sol up` + HTTP/Kafka/PG) │
                         ├─ golden-path-smoke-ts     (k3d, examples/pluto + Trace/Kafka/PG)     │
                         ├─ example-dockerfile-smoke (5-entry matrix)                          │
                         ├─ demo-ts-dockerfile-smoke (2-entry matrix)                          │
                         └─ ts-tests                 (npm ci/build/audit)                      │
   release.yml ────────► tag: build binary + migration runner + bundle + installed-release smoke │
   workspace-independence.yml ──► weekly/on-demand fresh-switch copy proof                        │
   fn-svc-isolation-spike.yml ──► manual spike                                                    │
                        └──────────────────────────────────────────────────────────────────────┘

 internal/ci/          51 check_* guards (5028 lines)  +  55 test_* mutation/self-tests (7315 lines)
                       13,049 lines total, 106 files. 58% of it verifies the other 42%.
   run_fast_checks.sh  66-entry bash array of guard commands + a private 12-entry unit-test list
 internal/tooling/
   hooks/{pre-commit,pre-push,post-commit}   installed via core.hooksPath
   scripts/run_tests.sh   3 suites (unit, kafka, e2e), own timeouts, own perf ratios
   scripts/perf.sh        5 suites (unit, kafka, observability, storage, e2e), own ratios
   perf/perf_baseline.json  764 history entries, main-only, merge=ours

 Dune                  (tests (names …)) / (test (name …)) stanzas, one runtest-integration alias
                       (kafka-eio-service), cli/test's ~30 inline bash rules, runtest-lifecycle alias
```

### 1.2 Duplicated inventories (the same membership declared in more than one place)

| Inventory | Places it is written | Guard that keeps them agreeing |
|---|---|---|
| unit-suite directory list | `ci.yml:227`, `run_fast_checks.sh:7-12`, `run_tests.sh:92-96` | `check_framework_ci_coverage.py` — **reads `ci.yml` only**; it cannot see `run_tests.sh` |
| guard list | `ci.yml` (~70 steps), `run_fast_checks.sh:14-81` (66 entries) | none (a deleted guard fails loudly; a new one is simply absent from pre-push) |
| infra suite aliases | `ci.yml:258` + `ci.yml:259` (and, on PR #860, one step per target) | `check_framework_ci_coverage.py` alias half |
| k3d/helm/kubectl pins | `ci.yml:878-895`, `ci.yml:1481-1493`, `internal/pipeline/dogfood/DOGFOOD.md` | none — `ci.yml:794-798` says so explicitly: "No automated drift check between the two files exists yet; update both by hand on any bump." |
| example Dockerfile matrix | `ci.yml:1289-1299` (5 entries), `ci.yml:1338-1339` (2 entries) | none; `git ls-files '*Dockerfile*'` finds 7, and a new one is silently never built |
| perf ratios / suite sets | `run_tests.sh:22-26` (3 suites), `perf.sh:9-15` (5 suites, different set) | none — the two disagree today (`observability`, `storage` exist only in `perf.sh`) |
| Rust-free "which env runs what" | `ci.yml` step `if:` conditions, `classify-changes.sh` allowlist, each guard's own skip branch | `check_unconditional_guard_tooling.py` + `test_docs_only_path.py` |

### 1.3 Skip paths found

| Where | Condition | Outcome |
|---|---|---|
| `test_sol_jobs_pg.ml:96`, `test_sol_outbox.ml:51` (on `main`) | `POSTGRES_URL` unset | prints `[skip]` and **passes** (PR #860 removes this) |
| `test_e2e.ml:1289-1294` | `LOKI_URL` unset | the Loki case `match o.ob_loki with None -> ()` — a named contract case that asserts nothing |
| `test_sol_obs.ml:14-18`, `test_worker.ml:240-246` | `bind()` raises `EPERM` | prints `[skip] sandboxed environment forbids binding a local socket` and **passes** |
| `check_gcloud_interface.sh:13-15` | `gcloud` absent | prints `SKIPPED`, `exit 0`, **before** its eight gcloud-independent checks |
| `classify-changes.sh:52,60-61` | every path in the docs allowlist | build + all test suites + all product guards are not run (`ci.yml:88-104` makes this visible) |

---

## 2. The verification model Sol actually needs

Derived from what the repository builds and runs, not from the requested category list. For each
class: the contract, the authoritative boundary, dependencies, whether skipping is ever valid,
where membership belongs, and who orchestrates. "Exit status" is the observation everywhere a
test executable is involved; no class infers behaviour from a test's printed text.

| Class | Contract established | Authoritative boundary | Dependencies | Skipping valid? | Membership declared in | Orchestrated by | Runs at |
|---|---|---|---|---|---|---|---|
| **C0 Build** | every artifact compiles in the pinned switch | `dune build` exit | opam switch | no | Dune | Dune | commit, push, PR, main, release |
| **C1 Unit** | pure behaviour of a library | in-process assertions | none | no — an EPERM at `bind()` is a *host* defect, not a reason to pass | the package's own `test/dune`, aggregated by one class alias | Dune | push, PR, main |
| **C2 Static invariant** | source/config shape: ownership, layering, forbidden APIs, formatting, doc-vs-signature | a guard's exit status, reading the tree structurally | `python3` + git; `shfmt`/`hcl2` only for the guards that parse shell/Terraform | no; a missing parser is an error | the guard's own directory/class | repository tooling, one entry point per class | push, PR, main |
| **C3 Postgres integration** | schema, transaction, lease and retention semantics against a real Postgres | exit status of a suite that cannot pass without Postgres | Postgres, **address pinned in the build definition** | never | the package's `test/dune` → the Postgres class alias | Dune | PR, main |
| **C4 Kafka integration** | registry/ordering/retry/DLQ semantics against a real broker | same | broker + registry + admin API | never | Kafka class alias | Dune | PR, main |
| **C5 Observability integration** | logs reach Loki, metrics render, trace context survives | a query against the real backend | Loki (+ Prometheus/Tempo) | never, in a class that claims it | observability class alias | Dune | main, release, and PR once the backend is provisioned |
| **C6 Local platform lifecycle** | `sol local infra up` / `sol up` against a real cluster, and their offline equivalents | CLI invocation + observed cluster/state | k3d, kubectl, helm, docker; offline: fakes | never | one offline alias + one online runnable script | repository tooling (offline) / GitHub Actions (online) | push (offline), main (k3d) |
| **C7 Application golden path (E2E)** | a scaffolded or example workspace deploys and completes a real transaction | `sol new` → build → `sol up` → HTTP → Kafka → DB, on a real cluster | the whole local platform | never | one runnable script per language | GitHub Actions provisions; the script asserts | main, release, PR (non-required) |
| **C8 Cloud lifecycle simulation** | Terraform apply/destroy ordering and authority without a cloud | offline harness with the real Terraform CLI and contract-faithful fakes | Terraform, pinned | never | lifecycle class alias + the harness's own test | repository tooling | push, PR, main |
| **C9 Live cloud qualification** | provider claims | real cloud + recorded evidence | real credentials | only with explicit authorization, and a skipped run is never evidence | the qualification ledger | qualification infrastructure | manual only |
| **C10 Release / clean machine** | the published artifact works where the checkout is not | install the archive in a container with no repo | release build | no | `release.yml` step list | GitHub Actions | tag |
| **C11 Performance** | runtime trend per suite | recorded durations compared **on one host class** | none | informational by definition | `perf_baseline.json`, keyed by host class | `perf.sh` | main, informational — never gates correctness |

Two properties of this model are load-bearing and are what the findings below press on:

1. **Every class's membership is declared where the thing lives** (the package's Dune file for a
   test, the guard's own file for a static invariant), and aggregation is by class name. A central
   list of paths that must be edited by hand is the *only* thing that `check_framework_ci_coverage.py`
   protects, and it is what loses `internal/tooling/sol_process/test` today.
2. **A dependency is part of the definition, not of the ambient environment.** Where the dependency
   is a connection address, the build definition supplies it — not the caller's shell.

---

## 3. Findings

Ids match the tickets filed in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`.

### VERIF-002 — A Dune test target's meaning depends on ambient environment, and its result is cached across environments · **observed** · high

Files: `framework/ocaml/sol-jobs/test/dune:1-2`, `framework/ocaml/sol-outbox/test/dune:1-3`,
`test_sol_jobs_pg.ml:93-99`, `test_sol_outbox.ml:48-53`, `ci.yml:220-227` and `ci.yml:246-259`.

Current behaviour on `main`: the unit step runs `dune test` over 12 directories *without* `--force`,
where `sol-jobs`/`sol-outbox` print `[skip] POSTGRES_URL not set` and exit 0; the integration step
then runs `dune test framework/ocaml/sol-jobs/ framework/ocaml/sol-outbox/`, which Dune serves from
the unit step's cache. The step whose entire purpose is the Postgres cases does not run them.

Reproduced generically (scratch project, Dune 3.24.2, no database involved):

```
== run 1: REQUIRED_DEP_URL unset (the 'skip' run)      exit=0
== run 2: REQUIRED_DEP_URL set, same _build, no --force exit=0
== evidence.log:  skipped-no-database
== run 3: set + --force                                exit=0
== evidence.log:  skipped-no-database
                  ran-with-database(postgresql://real)
```

So `dune test`'s exit status is not evidence of execution, and the alias form
(`dune build @dir/runtest-integration`) is cached identically — confirmed separately.

Why it is fragile: Dune keys an action on its declared dependencies. Ambient environment is not
one, and Dune has no environment-dependency construct (`(deps env:VAR)` is not a rule — it errors
with "No rule found for test/env:REQUIRED_DEP_URL"). Any target whose behaviour, meaning or
*dependency address* comes from the caller's environment therefore has incoherent cache semantics
by construction.

**Consequence for PR #860:** its fix is right in kind — the two suites become targets the unit step
cannot build, and `with_pool` fails instead of printing a skip — but it rests on *target
disjointness*, not on the dependency being part of the definition. The remaining hole is observed:
after the alias has been built once, invoking it again with `POSTGRES_URL` unset is a cache hit and
the fail-closed code never runs, so "fails closed when it runs" ≠ "cannot report success when it
does not run". It is also not parallel-safe: `dune build @a` and `dune build @b` are separate cache
entries only because CI runs them one at a time.

Desired invariant: an integration target's dependency is part of the target. Its address comes from
the build definition (a literal in the package's own `dune`, with provisioning as an explicit
dependency of the rule), not from the caller; and the same address is not destructively owned by
two targets.

Fix: for each infrastructure class, one alias whose rules pin the address they use, so a second
invocation under different ambient variables is the *same action*, not a different one served from
cache. Keep the fail-closed entry points. (This also removes the need for `--force`, which is the
blunt instrument currently used to make the E2E fixture re-run: `ci.yml:280`.)

### VERIF-003 — The canonical test runner fails a green tree, and correctness is coupled to performance · **observed** · high

Files: `internal/tooling/scripts/run_tests.sh:16-26` (`TIMEOUTS`, `FAIL_RATIOS`),
`:43`, `:104-113` (`is_regression`), `:160` (`timeout -s KILL`), `:218`, `:285-295` (exit codes),
`internal/tooling/perf/perf_baseline.json`.

Reproduced on this machine, with the tree at `main` and no changes:

```
$ bash internal/tooling/scripts/run_tests.sh unit
  unit               pass            7.859s    2.310s        1.5×
✗ Performance regression detected (exceeded per-suite threshold).
EXIT=2
```

Every test passed; the runner exited nonzero. Three separate problems are visible in that output:

1. **A correctness invocation returns a performance verdict.** `run_tests.sh` is the documented
   canonical runner (`/e2e` skill, AGENTS.md § Tests) and any caller treating nonzero as failure
   sees *the test suite fail on a green tree*. `merge-finish` runs it after every merge and reports
   the result, so post-merge reporting is permanently red — which trains readers to ignore it.
2. **The baseline is machine-dependent and its history is not comparable.** 2.310 s for the same
   suite that takes 7.859 s here; `install-hooks.sh` sets `merge.ours.driver true`, so every local
   append to the history is silently discarded when `main` moves. The comparison is between
   different hosts, not between revisions of the code.
3. **A hang detector is doing duty as an expectation.** `TIMEOUTS[unit]=60` bounds the whole suite
   (not a case); a suite that legitimately grows past it reports `timeout` — a correctness failure
   caused by a performance-ish bound.

Desired invariant: correctness and performance are different concerns with different owners.
Correctness exits 0 or nonzero. Performance is a *report* over durations compared within one host
class, informational, never an exit code; its timeout is a hang bound, generous, and named as one.

Fix: split the runner's exit contract (correctness only), move every ratio/threshold into
`perf.sh`, key baselines by host class (or drop the comparison across hosts), stop writing shared
history from a developer's machine, and give the hook a report with no failure semantics.

### VERIF-004 — Suite membership is declared three times, and the guard only sees one of them · **observed** · high

Files: `ci.yml:227`; `run_fast_checks.sh:7-12`; `run_tests.sh:92-96`;
`internal/ci/check_framework_ci_coverage.py` (`UNIT_STEP` reads `ci.yml` only);
`internal/tooling/sol_process/test/dune`; `examples/pluto/test/dune`.

Computed from the sources:

```
directory                                             ci.yml  fast  run_tests
cli/test                                                 yes   yes        yes
framework/ocaml/kafka-eio-service                        yes   yes          -
framework/ocaml/sol-env                                  yes   yes        yes
framework/ocaml/sol-fn                                   yes   yes        yes
framework/ocaml/sol-jobs                                 yes   yes          -     <- BUG-115's subject
framework/ocaml/sol-obs                                  yes   yes        yes
framework/ocaml/sol-outbox                               yes   yes          -     <- BUG-115's subject
framework/ocaml/sol-runtime                              yes   yes          -
framework/ocaml/sol-svc                                  yes   yes        yes
framework/ocaml/sol-worker                               yes   yes        yes
internal/tooling/soldev/test                             yes   yes          -
internal/tooling/style_audit                             yes   yes          -
```

`run_tests.sh` omits six of twelve directories — including both suites whose caching bug BUG-115
is about, and `internal/tooling/soldev/test`, which tests the ticket machinery itself. Nothing
detects the drift, because the guard that exists to check this reads only `ci.yml`.

Independently, enumeration is what loses suites outright, not just members:

- `internal/tooling/sol_process/test/test_sol_process.ml` is a `(test …)` stanza in the **root**
  workspace and is named by no runner: it is compiled by every `dune build`, executed by nothing.
- `examples/pluto/test/{test_charges,test_schemas}.ml` live in a project with its own
  `dune-project`, so no root invocation reaches them and no workflow runs `dune test` there; the
  Dockerfile jobs only `docker build`. The canonical reference application's OCaml tests never run.
- (`platform/shared/templates/workspace/test/` is the scaffold template; it *is* exercised, at the
  right boundary, by `cli/test/test_scaffold.ml:348-359`, which renders a workspace and runs
  `dune runtest test` in it. That is the model to follow, not a gap.)
- `check_test_reachability.py` cannot see any of this: its default scan root is `cli/test`, and its
  invariant is "a module in *this* directory is reachable", not "a suite is run by something".

Desired invariant: one authoritative declaration per suite, at the suite, and an unambiguous
default so a new suite is *run* unless someone decides otherwise.

Fix: give each class one Dune alias (`@ci-unit`, `@ci-integration-*`, `@ci-lifecycle`, `@ci-e2e`)
with membership declared in the owning package's `test/dune`; invoke the aliases from `ci.yml`,
`run_fast_checks.sh` and `run_tests.sh`; then delete `check_framework_ci_coverage.py` and its
mutation suite, because the failure it detects can no longer arise. Adopt the orphan suites (or
record an explicit exclusion for each). Note Dune's own limit, verified: `(tests)` requires
`names`, and `:standard` is rejected ("Module \":standard\" doesn't exist") — which is exactly what
REFAC-160's inline-test migration removes, so the two refactors converge.

### VERIF-005 — The workflow enumerates ~70 guards, so 2,346 lines exist to check the enumeration · **risk, with one observed defect** · high

Files: `ci.yml` (`test` job, 130 named steps); `internal/ci/check_unconditional_guard_tooling.py`
(166 lines); `internal/ci/test_docs_only_path.py` (57); `internal/ci/test_unconditional_guard_tooling.sh`;
`internal/ci/check_workflow_paths.py` (88); `run_fast_checks.sh:14-81`.

Measured: `internal/ci/` is 13,049 lines over 106 files — 51 `check_*` guards (5,028 lines) and 55
`test_*` mutation/self-test scripts (7,315 lines), i.e. 58% verifying the other 42%. Of that, about
2,346 lines across 20 files have the CI wiring, ticket machinery, hook install or suite coverage as
their subject rather than the product.

`check_unconditional_guard_tooling.py` is the sharpest instance. It re-implements a dependency graph
over shell scripts (`SCRIPT_NAME`/`reaches`/`artifacts`, plus a hand-rolled `INSTALLS` regex) in
order to answer "does every step's tooling get provided by an earlier unconditional step on both
paths", and `test_docs_only_path.py` then asserts properties of that model. It is a guard whose
subject is the arrangement of `.github/workflows/ci.yml`. That is the shape the brief asks about:
it is not establishing a product invariant, it is establishing that a 1,713-line YAML file is
internally consistent.

Observed defect inside that machinery: its `PROVIDED_BY_A_STEP` allow-list is `{kubectl, shfmt,
ocamlformat}` and it ignores any tool it does not recognise, so a new step that requires an
unlisted binary passes the guard and fails at runtime. It also treats a *destructive* concern
identically to a tooling one: nothing there distinguishes "this guard could not observe its input"
from "this guard observed a clean tree".

Desired invariant: adding a static invariant, or a suite, is one file plus one declaration next to
it. The workflow does not hold a list that a guard must then defend.

Fix: declare class membership on the artifact (a directory or a one-line header read by the runner,
the same way `internal/pipeline/tickets/` encodes status by directory) and have one repository
tooling entry point per class invoke them. `ci.yml` then calls `verify static` / `verify mutation` /
the Dune aliases, and the docs-only branch skips exactly one step rather than 25 conditions. Delete
`check_unconditional_guard_tooling.py`, `test_docs_only_path.py` and
`test_unconditional_guard_tooling.sh` once the equivalent properties are structural. Keep
`check_workflow_paths.py` — "an invoked script is executable and does not assume `rg`" and "a
`paths:` filter names something that exists" are genuine GitHub-Actions semantics (class D), not
compensation.

Also observed in the same folder: `internal/ci/test_resource_identity_check.py` is wired into
nothing, while its guard `check_resource_identity.py` runs in both CI and pre-push (VERIF-011).

### VERIF-006 — Suites and guards that pass having established nothing · **observed** · high

Four instances, all of them "success through omission" rather than a test that failed:

1. **A named assertion that asserts nothing.** `internal/fixtures/local-demo/test/test_e2e.ml:1289-1294`
   declares the case *"outbox logs reached Loki"* and body `match o.ob_loki with None -> ()`. The CI
   step that runs it is explicit about the outcome (`ci.yml:270`: "LOKI_URL is unset, so the Loki
   assertions self-skip"), so on the required PR gate observability integration is not covered at
   all, while `run_tests.sh:105-115` sets `LOKI_URL` and does cover it. The local runner and the
   gate disagree about what the class means, and the gate's name implies more than it establishes.
2. **An environmental skip inside a unit suite.** `test_sol_obs.ml:14-18` and
   `test_worker.ml:240-246` catch `Unix.Unix_error (EPERM, "bind", _)` and print
   `[skip] sandboxed environment forbids binding a local socket`, then pass. On a runner where
   `bind()` is permitted they run; anywhere else the case disappears and the suite is still green.
   A sandbox that forbids a socket is a host defect to report, not a behaviour of the library.
3. **A guard whose missing tool skips its own tool-independent checks.**
   `check_gcloud_interface.sh:13-15` prints `SKIPPED` and exits 0 *before* eight checks that never
   touch `gcloud` (provider-tier assignment, impersonation scoping, forbidden broad roles). The
   `ci.yml:418` comment says it "skips -- loudly -- on runners without gcloud, rather than passing",
   but it does pass, with exit 0. GitHub's `ubuntu-22.04` image does ship `gcloud`, so PR CI gets
   the full guard; pre-push on a machine without it (this is what `run_fast_checks.sh:18` invokes)
   gets nothing, and a runner-image change would silently remove the whole guard from CI as well.
4. **A nested test run with the variable that decides its behaviour turned off.**
   `cli/test/test_scaffold.ml:352-359` runs the rendered workspace's `dune runtest test` with
   `~env:[ "CI", "false" ]`, which is the BUG-052 fix — correct as far as it goes, and it means the
   generated workspace's schema gate is exercised only in its *skip* branch, under a variable that
   differs from both CI and staging.

Desired invariant: an omitted optional dependency produces a *distinct, visible, non-passing*
outcome, or the class is not claimed. A guard that cannot observe its input says so and fails; a
guard whose subject does not need the tool keeps running without it.

Fix: split the gcloud guard (static part always; interface part fails in CI where `gcloud` is
guaranteed and takes a named `--allow-missing-tool` locally); give unit suites a fail-closed host
requirement instead of an EPERM skip; make the Loki case a hard requirement of the E2E class once
Loki is provisioned for the job that claims it (or remove the case from the class and say so).

### VERIF-007 — Serialization stands in for isolation: one Postgres fixture, destructively owned by two suites · **observed (per BUG-115) / risk for the rest** · medium

Files: `platform/local/scripts/ensure-postgres.sh:4-24` (fixed container `sol-postgres`, fixed port
5432, fixed database `sol_dev`); `test_sol_jobs_pg.ml` and `test_sol_outbox.ml` (each
`DROP TABLE IF EXISTS sol_jobs; CREATE TABLE sol_jobs …`); PR #860's comment "One alias per
invocation, because both suites destructively own the one `sol_jobs` table".

BUG-115 observed the interleaving directly (`relation "sol_jobs" does not exist` raised from the
other suite's `DROP TABLE`). The remedy in #860 is to run one alias per CI invocation, which makes
the collision a CI sequencing rule rather than an impossibility — and that rule lives in
`.github/workflows/ci.yml`, i.e. product/test semantics in the workflow (principle 8).

The repository already has the better mechanism in the sibling class: Kafka suites isolate by
unique per-run naming (`test_e2e.ml:213-217` derives the topic from `Unix.getpid ()`;
`test_kafka_service_integration.ml:18-23` from a random `run_id`). Postgres suites do not.

Desired invariant: two suites that share a database must not share a destructive object. Isolation
is a property of the resource name, not of the scheduler.

Fix: give each Postgres suite its own schema (or database) derived per suite and per run, with the
DDL creating it; that removes the need for one-alias-per-invocation and lets the whole class run in
one invocation. Provisioning stays shared — that is fine — but ownership does not.

### VERIF-008 — Scratch-repository helpers depend on the caller to sanitize Git's exported environment · **observed (the hook incident) / risk that it recurs** · medium

Files: `internal/tooling/hooks/pre-push:6` (`unset $(git rev-parse --local-env-vars)`),
`internal/tooling/hooks/pre-commit:45` (unsets for the build only); `internal/ci/run_fast_checks.sh`
(no sanitization, and it invokes ~10 scratch-repo helpers: `test_json_decode_boundary.sh:12`,
`test_workflow_paths.sh:12`, `test_library_output.sh:12`, `test_manifests_are_values.sh:12`,
`test_result_syntax.sh:12`, `test_no_account_artifacts.sh:11`, `test_authority_check.sh:18`,
`test_hook_install.sh:25`, and the `git -C "$tmp/repo"` uses throughout).

`git` exports repository-local variables to hooks (`GIT_DIR`, `GIT_INDEX_FILE`, …). A scratch
repository created underneath that environment resolves those variables instead of its own path,
so `git -C "$scratch" rm --cached …` operates on the *real* repository — which is what the incident
did. The regression coverage that exists is excellent and is the model to copy:
`internal/ci/test_hook_install.sh:70-85` drives a real `git push` through the tracked hook and then
asserts, in the runner, that (a) no repository-local variable leaked and (b) nested `git` calls
resolve the pushing worktree and branch. Both assertions are about the authoritative boundary.

The remaining gap is where the sanitization lives: in one hook. A new hook, a `git rebase --exec`,
or a developer running `bash internal/ci/run_fast_checks.sh` inside a Git-invoked process
reintroduces the hazard with no signal.

Desired invariant: a script that creates or mutates a scratch repository proves it is operating on
that repository before a destructive Git operation, and the runner sanitizes its own environment
rather than trusting its caller.

Fix: sanitize at the top of `run_fast_checks.sh` (and in the shared scratch-repo helper, if one is
introduced); assert `git -C "$scratch" rev-parse --git-dir` resolves inside `$scratch` before
`add`/`rm`/`commit`/`checkout`; keep the real-`git push` regression as the guard for the boundary.

### VERIF-009 — The pre-push gate can report PASS for a check that produced no result · **observed** · medium

File: `internal/ci/run_fast_checks.sh:122-131`.

```bash
for index in "${!checks[@]}"; do
  read -r code seconds <"$results/$index.status"
  if [ "$code" -eq 0 ]; then printf 'PASS …'; else failed+=("$index"); fi
done
```

If `run_check` dies before writing `$results/$index.status`, `read` fails, `code` keeps the previous
iteration's value, and a check that never ran is reported as `PASS`. Reproduced in isolation:

```
PASS    3s  0
PASS    3s  1        <- status file absent; carried over code=0
failed count: 0  (expected 1)
```

The final exit status is `[ ${#failed[@]} -eq 0 ]`, so this is a false success for the whole
pre-push gate, not a display bug. The fix is a default (`code=1`) or an explicit
`[ -f status ] ||` branch; the general form is that a missing result must never equal success.

### VERIF-010 — Duplicated external-tool and Dockerfile inventories, one of them self-declared unguarded · **risk** · medium

Files: `ci.yml:878-895`, `ci.yml:1481-1493` (two copies of the k3d v5.6.0 / helm v3.21.0 / kubectl
v1.29.0 downloads), `ci.yml:794-798` (the comment stating there is no drift check against
`internal/pipeline/dogfood/DOGFOOD.md`), `ci.yml:1289-1299`, `ci.yml:1338-1339`, AGENTS.md
("New example Dockerfiles go in the `example-dockerfile-smoke` CI matrix").

`git ls-files '*Dockerfile*'` under `examples/` and `internal/fixtures/` finds 7; the two matrices
cover 5 + 2. Today that is complete, by hand. A new example app's Dockerfile is silently unbuilt;
a version bump must be made in three places and the repository documents that nothing checks it.
This is the finding the brief's principle 1 predicts: a checker to keep two lists in sync is the
wrong answer when the second list can be derived.

Fix: one definition of the toolchain (a shell file the jobs source, or the jobs install a pinned
toolchain image/action) and a derived Dockerfile matrix (`git ls-files`-based discovery with a
fail-closed empty/duplicate check) instead of two hand-written lists. Version pins then live in one
place and `DOGFOOD.md` either reads it or is checked against it.

### VERIF-011 — Two mutation self-tests exist but never run, and two guards run only mutated · **observed** · medium

- `internal/ci/test_resource_identity_check.py` is referenced by no workflow, no
  `run_fast_checks.sh` entry and no Dune rule, while `check_resource_identity.py` runs in both
  (`ci.yml:665-667`, `run_fast_checks.sh:72`). The guard's mutation evidence is dead code.
- `check_cluster_access_identity.py` and `check_gcp_provisioner_role.py` are invoked only from
  their own mutation scripts (`test_cluster_access_identity.sh:5`, `test_gcp_provisioner_role.sh:5`),
  on a temporary copy. Those scripts do exercise the real file as a control, so drift is caught
  indirectly; what is missing is the guard's own verdict on the real tree with its own diagnostic.

Verified by scanning every workflow `run:` command, `run_fast_checks.sh` and the Dune files for each
`check_*` name; the four above are the whole result (`check_authority.sh`, `check_readiness_invocations.sh`,
`check_public_cloud_lifecycle.sh`, `check_publisher_deployer_boundary.sh`, `test_cloud_lifecycle_offline.sh`
are invoked only from a test or from a Dune rule, and in each case that is deliberate and was checked).

Desired invariant: a guard's mutation self-test is part of the guard's class, so it cannot be
forgotten when the guard is added — which VERIF-005's convention makes structural. Until then, wire
the four.

### VERIF-012 — Verification inputs in the docs-only allowlist, and comments that outlive the defect they describe · **observed (comments) / risk (allowlist)** · low

- `classify-changes.sh:52,61` — a change to `internal/tooling/perf/perf_baseline.json` is classified
  `docs-only`, so it skips the build and every suite. Today the baseline gates nothing (per
  VERIF-003 it is informational), so the exposure is bounded; the moment performance becomes a gate,
  the allowlist must not contain a gate input. Decide explicitly and record it.
- `ci.yml:282-285` states that running `dune fmt --preview` first makes the CLI tests' `SOL_HOME`
  ancestor walk resolve to `_build/default` instead of the source checkout. The code already
  prevents that: `cli/lib/base/sol_cli_platform_assets.ml:62-68` excludes any directory containing a
  `_build` path component (`inside_build_context`) before `is_checkout` is consulted by
  `find_ancestor` (`:145`). The comment is stale, and stale comments of this kind are what make
  agents preserve loading-bearing-looking ordering that is no longer load-bearing.
- The perf baseline's own `note` field points at `./cli/platform/local/scripts/run_tests.sh`, a path
  that no longer exists.

Fix: delete/correct the comments, decide the baseline classification, and note that
`run_fast_checks.sh` runs build → unit → guards in one `_build`, so any future dependency of a test
on sibling artifacts must be declared rather than implied by step order.

### VERIF-013 — The premise-probe mechanism turns "could not look" into a verdict · **observed** · high

Files: `internal/tooling/soldev/lib/soldev_ticket.ml:325-340` (`premise_verdict`),
`internal/tooling/soldev/lib/soldev_merge.ml:944-956` and `:1072-1091` (the labels),
`internal/pipeline/tickets/BACKLOG/OBS-045.md:7`, `internal/pipeline/tickets/DONE/OBS-046.md:7`.

```ocaml
let premise_verdict ~exit_code =
  if exit_code = 0 then Premise_stale
  else if exit_code = 127 then Premise_unverified "the probe command was not found (exit 127)"
  else if exit_code = 126 then Premise_unverified "the probe command is not executable (exit 126)"
  else Premise_holds
;;
```

Every exit code that is not 0, 126 or 127 — including a probe that could not run at all — reports
`Premise_holds`, which the queue renders as `actionable`. Observed on the current tree:

```
$ rg -q Byo cli/sol/lib/sol_cli_open.ml     # BACKLOG/OBS-045's probe target
$ echo $?
2                                            # "could not look": the path is gone
$ ! rg -q Byo cli/sol/lib/sol_cli_open.ml    # DONE/OBS-046's probe, same gone path
$ echo $?
0                                            # => Premise_stale: "nothing there" from a failed read
$ soldev pipeline ls
  OBS-045  feature  medium  depends on: none  needs-human  Open traces for a Sol scope …
```

`rg` uses 2 for "I could not read what you asked for" and 1 for "no match". The mechanism
special-cases only 126/127, so a **moved path, a shell syntax error or a permission failure is
reported to the operator as a definitive verdict in one of two directions**: `Premise_holds`
(probe cannot run, so the ticket silently stays actionable forever and nobody learns the probe is
broken — `OBS-045` is in exactly this state, masked only by its `needs-human` section), or, for the
negated form the convention requires for a "the defect is gone" fix, `Premise_stale` — "the work is
already done" derived from a read that never happened. `DONE/OBS-046.md` carries that form today
against a path that no longer exists.

This is the same class the rest of this audit is about, inside the tooling that decides whether a
ticket is actionable: an inaccurate observation is reported as a confident one.

Desired invariant: a probe returns exactly one of three values, and "the probe did not run to a
conclusion" is never one of the two verdicts. The contract is stated where probes are documented:
0 = premise stale, 1 = premise holds, anything else = unverified, with the exit code and output
shown.

Fix: treat every exit outside {0, 1} as `Premise_unverified`, carrying the code and the probe's
stderr; and report the paths a probe names that no longer exist, since a moved file is the common
cause. Probes on the tree should also be re-verified when the layout moves (REFAC-104 was such a
move), which is what the `paths:`-existence half of `check_workflow_paths.py` already does for
workflows and could do for probes.

---

## 4. Guard classification

Categories: **A** legitimate structural invariant (keep; mutation coverage valuable) ·
**B** behavioural property approximated structurally (replace with a behavioural test at the
authoritative boundary) · **C** compensating for duplicated/weak architecture (redesign so the state
cannot arise; then delete) · **D** genuine CI-platform/build-system invariant (keep) ·
**U** uncertain — needs the experiment named.

| Guard / family | Class | Verdict | Rationale |
|---|---|---|---|
| `check_no_comments.sh` + `no_comments.py`, `check_result_syntax`, `check_library_output`, `check_no_exception_control_flow`, `check_json_decode_boundary`, `check_single_runner`, `check_platform_assets_owner`, `check_signal_handler_duplication`, `check_publisher_deployer_boundary` | A | **keep** | Source invariants. Parsers (shfmt/tokenize/AST) where syntax is hard; grep where the property is simple. `no_comments.py` fails closed when `shfmt` is absent. This is exactly where source inspection is the right test. |
| Terraform/product contract guards: `check_production_infra`, `check_resource_identity`, `check_project_shared_resources`, `check_destroy_completeness`, `check_workload_release_order`, `check_managed_database_egress`, `check_deploy_substrate_order`, `check_provider_tls_path`, `check_node_shape_fits_platform`, `check_gcp_standard_substrate`, `check_platform_storage_requirement`, `check_platform_tls_requirement`, `check_cert_manager_readiness`, `check_kubernetes_object_ownership`, `check_durable_dns_zone`, `check_terraform_output_fixture`, `check_provider_roots`, `check_provider_dispatch`, `check_operator_diagnostics`, `check_qualification_transport`, `check_runtime_secret_identity`, `check_platform_component_drift`, `check_framework_doc_signatures`, `check_cli_reference`, `check_support_refs`, `check_manifests_are_values`, `check_examples_self_contained` | A | **keep** | Each pins a contract that a live run or a unit test cannot see (ownership, authority, ordering, identity, published-artifact contracts). Class A with mutation coverage is the right home. `check_gcloud_interface.sh` is the exception — see below. |
| `check_test_reachability.py` + mutation suite | A | **keep**, re-scope after REFAC-160 | The invariant is real and verified: a module in a `test/` directory that no stanza names is compiled by nothing. Dune cannot express "all modules here" — verified: `(tests)` without `names` is an error and `:standard` is rejected. After the inline-test migration the legacy registry disappears and the scan root should widen from `cli/test` and be re-documented; do not delete it. |
| `check_ocamlformat.sh` + mutation suite | D | **keep** | Formatting drift is invisible to `dune build`; CI needs an explicit check, and `--staged`/`--all` share one definition with the hook. |
| `check_workflow_paths.py` + mutation suite | D | **keep** | "An invoked script is executable / does not assume `rg`" and "a `paths:` filter names a tracked file" are GitHub-Actions semantics. Not derivable, cheap, fail-closed. |
| `check_ticket_move.sh`, `check_ticket_transitions.sh`, `check_ticket_overwrites.py`, `test_pipeline_validate.sh` + their mutation suites | A | **keep** | Git/GitHub boundary invariants (branch name ⇒ ticket move; one record per id; a wrapped `Depends on` line rejected). They protect the workflow that produces the work, and each has real mutation coverage, including cases taken from real failures (BUG-060/061/110/114). |
| `check_authority.sh` + `test_authority_check.sh`, `test_hook_install.sh` | A | **keep** | The only guard that pins worktree ownership semantics, and `test_hook_install.sh` is the repository's best example of exercising the real entry point (a real `git push` with a leak assertion). Extend this pattern (VERIF-008) rather than adding anything new. |
| `check_framework_ci_coverage.py` + mutation suite | C | **delete after VERIF-004** | Its whole subject is "the list in `ci.yml` matches the Dune stanzas". Verified to work (mutation suite passes), which is the point: a perfectly tested compensation for a duplicated declaration. The class aliases make it unnecessary. |
| `check_unconditional_guard_tooling.py`, `test_docs_only_path.py`, `test_unconditional_guard_tooling.sh` | C | **delete after VERIF-005** | Their subject is the arrangement of `ci.yml`. They re-implement a dependency graph over shell scripts and ignore unrecognised tools (`PROVIDED_BY_A_STEP`). Fail-closed today (an empty `kind` runs everything; no `restore-keys`), so the exposure is maintenance cost and the false confidence of a partial model, not an observed false success. |
| `check_gcloud_interface.sh` | A + B mixed | **split (VERIF-006)** | The static half (impersonation scoping, forbidden roles, provider-tier assignment) is class A and must always run; the argv-vs-`gcloud --help` half is class B and needs the real pinned tool. Today the class-B branch returns before the class-A checks. |
| `classify-changes.sh` + `test_classify_changes.sh` | D | **keep** | The classifier decides whether the expensive suite runs, so its boundaries belong in the gate; it fails closed on unknown paths (`.github/**` ⇒ source; anything unrecognised ⇒ source). Review the allowlist per VERIF-012. |
| Dune `runtest-integration` alias + `dune test` on the same directories | C | **keep the alias, delete the double meaning (VERIF-002)** | The alias is the right mechanism; the defect is that the unit step and the integration step share targets whose meaning comes from the environment. |
| `test_resource_identity_check.py`, `check_cluster_access_identity.py`, `check_gcp_provisioner_role.py` wiring | U | **wire, then re-evaluate (VERIF-011)** | Not a guard-design question: they are unreachable or run only as mutants. |
| `soldev` premise probes (`soldev_ticket.ml:332-340`) | B | **redesign (VERIF-013)** | A good mechanism — a declarative probe evaluated by the queue — with a broken trust boundary: every exit code outside {0, 126, 127} is reported as `Premise_holds`, and a negated probe reports `Premise_stale` from a read that never happened. Observed live on two tickets whose named path moved. |
| `perf.sh` + `perf_baseline.json` + post-commit hook | B (wrong layer) | **redesign (VERIF-003)** | Real durations compared across machines, published through a hook on every commit, with an exit code in the runner. Performance is evidence, not a gate. |

---

## 5. Target architecture

```
Dune (owns: what exists, and what its dependencies are)
  @ci-unit            every pure suite (inline tests + explicit (test) stanzas)
  @ci-integration-pg  Postgres class — its own schema, its address in its own dune
  @ci-integration-kafka  broker class (unique topic naming, already isolated)
  @ci-integration-obs    Loki/Prometheus/Tempo class
  @ci-lifecycle          the offline cloud-lifecycle harness (kubectl/terraform fakes)
  @ci-e2e                the local-demo fixture (broker + Postgres + Loki, all required)
  each package declares its own membership; there is no central path list

internal/ci/<class>/   (owns: static invariants — membership by directory, one file each)
  static/    product/source/config invariants; mutation self-test beside each (class A/D)
  lifecycle/ harness + its own test
repository tooling (owns: one entry point per class)
  tooling/scripts/verify.sh static|lifecycle      (globs the class, refuses an empty class)
  tooling/scripts/run_tests.sh                    (thin wrapper over the class aliases + a
                                                   provisioning step; correctness exit only)
  tooling/scripts/perf.sh                         (report only; never an exit code)

local commit      → format --staged, build, ticket transitions            (cheap, deterministic)
local push        → build, @ci-unit, internal/ci/static, mutation self-tests (env-sanitized)
PR CI             → build, @ci-unit, static+mutation, provision, @ci-integration-*,
                    @ci-lifecycle, E2E fixture; guards invoked by class, not by name
main CI           → the same plus the k3d golden paths, the workspace-independence proof,
                    and the installed-release smoke
release (tag)     → release build + installed-release smoke in a repo-free container
live qualification→ provider claims, authorization-gated, evidence-recorded
```

**Ownership boundaries.**

- **Dune** owns build + test topology and, critically, the *addresses* integration suites use, so a
  target's cache key is its definition.
- **Test executables** own their success semantics: absent dependency ⇒ fail; unusable host ⇒
  report a defect, never a skip; nothing is asserted by a case that returns early.
- **Shell** orchestrates processes, provisioning and guards (the repository's existing rule).
- **Python guards** parse Terraform/YAML/Dune/shell structurally; they are class A/D only.
- **Repository tooling** owns the class entry points and the class membership globs, and refuses an
  empty class.
- **GitHub Actions** owns runners, dependency provisioning, identities, artifacts, job sequencing
  and required-check policy — and no product or test semantics.
- **Hooks** own a cheap deterministic subset, invoked through the real Git boundary, with the
  environment sanitized by the thing being run.
- **Qualification** owns claims that need real providers.

Two rules follow from the findings and are worth stating as rules rather than conclusions:
**a target's meaning never depends on the caller's environment**, and
**the same list is never written twice; the second writer derives it or it is deleted**.

---

## 6. Migration plan

Sequenced so verification strength never decreases: introduce the authoritative replacement, prove
it catches the failure it is for, switch consumers, then delete the legacy mechanism.

| Step | Depends on | What lands | Evidence that it works |
|---|---|---|---|
| **1. VERIF-003** separate correctness from performance | — | runner exits on correctness only; ratios and thresholds move to `perf.sh`; hook reports; host-class keying | `run_tests.sh unit` exits 0 on a green tree; a deliberately slowed suite still passes correctness and appears in the report |
| **2. VERIF-002** dependency is part of the definition | — | one alias per infra class; the address pinned in the package's `dune`; provisioning as an explicit dependency; fail-closed entry points kept; the E2E fixture stops needing `--force` | the scratch-project demonstration inverts: invoking the class target under a different ambient variable runs **or fails**, never silently succeeds |
| **3. VERIF-007** isolate the Postgres suites | 2 | per-suite schema/database, DDL creates it | two suites in one invocation pass repeatedly; the "one alias per invocation" CI rule is deleted because it is no longer needed |
| **4. VERIF-004** one topology in Dune; delete the coverage guard | — | `@ci-unit`/`@ci-e2e`/`@ci-lifecycle` + per-package membership; `ci.yml`, `run_fast_checks.sh`, `run_tests.sh` invoke aliases; the two orphan suites adopted or explicitly excluded; `check_framework_ci_coverage.py` + its mutation suite deleted | `test_framework_ci_coverage.sh`'s own scenarios are re-expressed as: removing a package's membership line makes the class alias stop running it (the failure now surfaces as a missing suite, not a stale list) |
| **5. VERIF-005** guards by class, one entry point | 4 | `internal/ci/<class>/` membership; `verify.sh`; `ci.yml`'s ~70 guard steps become class invocations; the three wiring guards deleted | the mutation self-tests still run; deleting a guard file is reported as a missing class member; the docs-only path still runs ticket validation |
| **6. VERIF-009, VERIF-011** close the fast-check and wiring false-success paths | 5 | missing result ⇒ failure; the four unwired guards/mutation tests wired | the reproduction in § 3 produces `FAIL`; `check_resource_identity`'s mutation case is exercised by CI |
| **7. VERIF-006** no passing-vacuous cases | 2,4 | gcloud guard split; EPERM skips replaced by a reported host requirement; the Loki case made a real requirement of the class that claims it (or removed and recorded) | running the unit class with `bind()` denied fails and names the host requirement; the E2E class without Loki fails |
| **7b. VERIF-013** the probe contract has three outcomes, not two | — | any exit outside {0,1} is `premise-unverified` with the code and output; probes naming a path that no longer exists are reported | `OBS-045`'s probe (a moved path, exit 2) reports unverified rather than actionable; a `!`-form probe on a missing file stops reporting `premise-stale` |
| **8. VERIF-010** derive the duplicated inventories | — | one toolchain definition; Dockerfile matrices derived with a fail-closed empty check | adding a Dockerfile with no matrix change either gets built or fails the derivation guard |
| **9. VERIF-008** sanitize at the runner and assert scratch identity | — | `run_fast_checks.sh` sanitizes; scratch helpers assert their target | `test_hook_install.sh`'s leak assertion extended to the runner; helpers invoked under a leaked `GIT_DIR` refuse |
| **10. VERIF-012** comments, allowlist, docs | — | stale comments corrected; the baseline's classification decided and recorded | — |

Concurrency: steps 1, 2, 4, 7b, 8, 9 and 10 are independently startable; 3 follows 2; 5 follows 4;
6 follows 5; 7 follows 2 and 4. Nothing here requires a single umbrella branch, and no step deletes
a mechanism before its replacement's evidence exists — the only deletions (steps 4 and 5) are gated
on the replacement passing the legacy guard's own mutation scenarios. The smallest useful first
landing is step 1 or step 7b, both of which are single-file fixes to tooling that currently reports
a wrong verdict.

---

## 7. BUG-115 and PR #860

**Land PR #860.** Its shape is the right one and it does not weaken BUG-115's regression coverage:

- the stale `sol_jobs` DDL is corrected and the composition assertion now *is* the check that
  `sol-outbox` and `sol-jobs` agree on the table;
- the two database suites become their own targets, so the unit step cannot build them and the
  ambient variable no longer decides what a target means;
- `with_pool` **fails** instead of printing `[skip]`, so a run without a database is a failed run;
- the sweep-boundary regression and `validate_workspace` unit coverage are genuine additions.

**Do not land `check_integration_suites_ran.sh`, or any Alcotest-output parsing, and do not
reintroduce a `SOL_REQUIRE_DATABASE`-style ambient flag.** The branch's final revision already made
this call and the audit agrees: `alcotest` fits its summary lines to the terminal width, so a
case-name match is a correctness criterion that depends on a presentation detail — and the failure
it would have caught (a suite that cannot pass) is already excluded structurally by the target
split. Explicit execution evidence, if ever genuinely required, belongs in a machine-readable
protocol owned by the harness, not in the console.

Three parts of #860 are, by this audit's standard, temporary — they should be recorded as such in
the ticket's completion notes (or a one-line note in the PR) so the follow-ups are visible:

1. **`dune build @…/runtest-integration` is still a cached action whose meaning comes from
   `POSTGRES_URL`.** Observed: after the alias has been built once, re-invoking it with
   `POSTGRES_URL` unset is a cache hit, so the fail-closed path never executes and the run is green.
   Disjoint targets are what save it today; VERIF-002 makes the dependency part of the definition.
2. **"One alias per invocation" is serialization standing in for isolation** — both suites still
   `DROP TABLE IF EXISTS` the same table in the same database. VERIF-007 gives each suite its own
   schema, after which one invocation is safe.
3. **The two suite paths are now named explicitly in `ci.yml`** (one step per target), which is a
   second inventory of the same kind VERIF-004 removes. Until then it is correct and should stay.

BUG-115's own acceptance criteria are met by #860, so moving it to `DONE/` in that PR is right;
the class it belongs to is tracked separately by VERIF-002, VERIF-004 and VERIF-007.

---

## 8. Verification of this audit

Every claim above that frames a decision, with the command that produced it.

**Dune's cache is environment-blind** — scratch project in `/tmp/vc-audit-dune`, Dune 3.24.2,
`(test (name probe))` writing one line per execution to `evidence.log`:

```
$ rm -rf _build evidence.log
$ env -u REQUIRED_DEP_URL dune test            # run 1: dependency absent
exit=0
$ env REQUIRED_DEP_URL=postgresql://real dune test   # run 2: dependency present
exit=0
$ cat evidence.log
skipped-no-database                                  # run 2 did not execute
$ env REQUIRED_DEP_URL=postgresql://real dune test --force
exit=0
$ cat evidence.log
skipped-no-database
ran-with-database(postgresql://real)                 # only --force executed it
```

The alias form behaves identically (`(rule (alias runtest-integration) (action (run ./probe.exe)))`):
one execution under the unset environment, then two apparent successes with no execution. Dune also
has no environment-dependency construct: `(deps env:REQUIRED_DEP_URL)` fails with
`No rule found for test/env:REQUIRED_DEP_URL`, and `(deps (env VAR))` is a syntax error.

**Dune cannot name all modules as tests** — same scratch project, two modules:
`(tests)` with no `names` ⇒ `Error: Field "names" is missing`; `(tests (names :standard))` ⇒
`Error: Module ":standard" doesn't exist`; `(tests (names alpha))` ⇒ `alpha ran` only, `beta`
neither compiled as a test nor run. This is the premise `check_test_reachability.py` rests on, and
it holds.

**The canonical runner fails a green tree** — `bash internal/tooling/scripts/run_tests.sh unit` on
unmodified `main`: `unit  pass  7.859s  2.310s  1.5×` then
`✗ Performance regression detected (exceeded per-suite threshold).` `EXIT=2`.

**Suite-inventory drift** — script over `ci.yml` (read as YAML), `run_fast_checks.sh` and
`run_tests.sh`: `in ci.yml but not run_tests.sh: [kafka-eio-service, sol-jobs, sol-outbox,
sol-runtime, internal/tooling/soldev/test, internal/tooling/style_audit]`; nothing is in
`run_tests.sh` that is not in `ci.yml`; `run_fast_checks.sh` matches `ci.yml` today.

**Guard wiring** — scan of every workflow `run:` command, `run_fast_checks.sh` and the Dune files
for each `check_*` basename: `test_resource_identity_check.py` unreferenced;
`check_cluster_access_identity.py`/`check_gcp_provisioner_role.py` referenced only by their own
mutation scripts; `check_authority.sh`, `check_readiness_invocations.sh`,
`check_public_cloud_lifecycle.sh`, `check_publisher_deployer_boundary.sh`,
`test_cloud_lifecycle_offline.sh` referenced only from a test or Dune rule (deliberate, checked).

**Orphan suites** — `git ls-files '*dune'` plus a reference scan of every workflow and both local
runners: `internal/tooling/sol_process/test` and `examples/pluto/test` referenced by nothing;
`platform/shared/templates/workspace/test` referenced by nothing *directly* but rendered and run by
`cli/test/test_scaffold.ml:348-359`, which is the correct boundary.

**The fast-check false success** — the reporting loop reproduced in `/tmp/vc-status` with a deleted
status file: `PASS 3s 1`, `failed count: 0`.

**The pre-push gate's real behaviour** — `bash internal/ci/run_fast_checks.sh` on unmodified `main`:
`fast checks: 0/66 failed in 14s`, `FAST_EXIT=0`, and `git status --porcelain` on the canonical
checkout printed nothing afterwards (no scratch-repository escape). `gcloud` *is* present on this
machine, so the gcloud guard ran; the skip branch was read, not triggered, and the claim about
GitHub's `ubuntu-22.04` image shipping `gcloud` was verified against the runner image's documented
software list rather than assumed.

**The premise-probe trust boundary** — read `soldev_ticket.ml:332-340`, then exercised the two
tickets whose probe names a path that moved with REFAC-104:

```
$ rg -q Byo cli/sol/lib/sol_cli_open.ml;  echo $?      # BACKLOG/OBS-045
2
$ ! rg -q Byo cli/sol/lib/sol_cli_open.ml; echo $?     # DONE/OBS-046
0                     # Premise_stale from a read that never happened
$ soldev pipeline ls | grep OBS-045
  OBS-045  feature  medium  depends on: none  needs-human  Open traces for a Sol scope …
```

`soldev pipeline ls` was also run against this audit's worktree, where every VERIF ticket read
`actionable` or `blocked` as their dependencies require; the one probe that reported `premise-stale`
was **this audit's own**, an inverted probe that contradicted its finding — it was corrected, and
that is how the exit-code rule above was found.

**PR #860** — `gh pr view 860` and `gh pr diff 860`: the final revision removes the log-parsing
guard and the mutation fixtures, and the commit list ends at
`8855d61d8 BUG-115: the database suites are their own targets, not a log to parse`. The earlier
comment on the PR describing a reinstated output-matching guard is superseded by that revision;
this recommendation follows the diff, not the comment.

**Self-correction.** One search in this audit first used `rg -rn 'ancestor' cli/` — `-r` is
`--replace`, and the mangled output (`n_namespaces`, `n_error`, `ned`) is the documented failure
mode in AGENTS.md. It was re-run as `rg -n` before anything was concluded from it, and the
`SOL_HOME` claim in VERIF-012 was then checked against the code, which disproved the comment.

---

## Appendix: what is working well and should not be touched

- **The change classifier's fail-closed shape.** `classify` is `continue-on-error`, `test` is
  `always()`, an empty `kind` runs everything, and the docs-only branch announces itself in the step
  summary rather than looking like a job where steps silently did not run. Uncertainty costs
  compute, never coverage.
- **The cached docs-only validator.** Keyed on exact source hashes of `soldev`/`sol_process`,
  restored without fallback keys, saved only by trusted `main` pushes, and fail-closed on a miss.
- **`test_hook_install.sh`.** The repository's best example of exercising an authoritative
  boundary: a real `git push`, then an assertion that the runner saw no repository-local variables
  and resolved the pushing worktree. VERIF-008 asks for this pattern, not for a new mechanism.
- **Mutation-test discipline.** ~55 mutation suites, most of them built from the real failure that
  motivated the guard (BUG-060/061/110/114, FND-006x, INFRA-048/057). The rule that a mutant which
  only fails to compile is not evidence is the right rule.
- **`check_test_reachability.py`'s premise** — verified above — and the Windtrap plan in
  `internal/specs/cli-test-architecture.md`, which removes the shared name registry entirely.
- **The `.gitattributes merge=ours` convention for the perf baseline** as an *interim* measure: it
  correctly stops a developer's local history from reaching `main`. VERIF-003 addresses the larger
  problem (comparing across machines at all).
