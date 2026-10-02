# Test-suite contract audit

**Date:** 2026-10-02
**Base:** `origin/main` @ `310917dd` (PR #865). All line references are to that commit.
**Scope:** every Dune test stanza — `framework/ocaml/*/test`, `cli/test/` (Windtrap inline
library plus its explicit executables and shell rules), `internal/fixtures/local-demo/test/`,
`internal/tooling/{soldev,sol_process}/test/`, `examples/pluto/test/`,
`platform/shared/templates/workspace/test/` — together with the `ts-tests` workflow job.
**Trigger:** Windtrap is established (`REFAC-160`, PR #863) and the CLI suite is migrated
(`internal/specs/cli-test-architecture.md`). Discovery is no longer the interesting question,
so this pass asks the next one: **does each test establish the right contract at the cheapest
authoritative boundary?**

This is the content axis. The 2026-10-01 verification-architecture audit
(`2026-10-01_verification_architecture_audit.md`, findings `VERIF-002`…`VERIF-013`) covered *how*
suites are run, declared and gated; it did not audit what individual suites assert. The finding
ids below continue that stream (`VERIF-014` onward) so a reader can hold both in one place.

## Method, and what was run rather than read

Claims are labelled **observed** (reproduced with the command recorded in § *Verification of this
audit*) or **risk** (a design consequence read from the code, with the lines that carry it).
Nothing was mutated in the operator's checkout; the repository was read only, and the scratch work
happened on the audit branch.

Commands run: `git worktree list`; `rg` inventories of every `(test …)`/`(tests …)`/`(inline_tests)`
stanza and every `CREATE TABLE sol_jobs` / `CREATE TABLE sol_outbox`; `rg` for every
`Migration.apply`, `Sol_jobs.Make` and `Sol_outbox` migration consumer; `rg` for `[skip]`,
`EPERM`, module-level `ref`/`Hashtbl`/`Atomic`, and `For_testing`/`_internal` in test files;
`python3 internal/ci/check_test_reachability.py`; `find` for `*.test.ts`/`*.spec.ts`; a
site-by-site `diff` of the three `sol_jobs` migrations against the canonical schema in
`framework/ocaml/sol-jobs/sol-jobs.md`.

## 1. Inventory, by authoritative boundary

| Suite | Boundary it exercises | Dependency | Membership today |
|---|---|---|---|
| `cli/test/inline/` (94 modules, ~1,400 `let%test`) | library functions in-process; a few real-`sol`-binary cases via `cli/test/*.sh` | none beyond the built binary | Windtrap registration; compile-time |
| `cli/test/*.sh` + `cli/test/dune` bash rules | the built `sol` binary over real files/env | none | explicit `runtest` rules |
| `cli/test/test_supervised.ml` | process-group lifecycle | none | explicit executable |
| `framework/ocaml/sol-svc/test/` | routing/auth/service; `test_auth_internal.ml` is a build-time copy of a private module | own local HTTP server | `(tests (names …))` |
| `framework/ocaml/sol-worker/test/` | worker state machine via `Worker.For_testing` | none (fake consume loop); one case binds a socket | `(tests (names …))` |
| `framework/ocaml/sol-fn/test/` | fn lifecycle, metrics, Pushgateway push | own local HTTP server; one case reads `AWS_LAMBDA_RUNTIME_API` | `(test …)` |
| `framework/ocaml/sol-obs/test/` | obs backends against a local HTTP server | own local HTTP server | `(test …)` |
| `framework/ocaml/sol-runtime/test/` | signal handling | none | `(tests (names …))` |
| `framework/ocaml/sol-jobs/test/test_sol_jobs.ml` | pure retry/validation/backoff | none | `(test …)` |
| `framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml` | job lease/claim/retention against Postgres | `POSTGRES_URL`, **schema hand-rolled** | `runtest-integration` |
| `framework/ocaml/sol-outbox/test/test_sol_outbox.ml` | outbox ordering/idempotency against Postgres | `POSTGRES_URL`, **schema hand-rolled** | `runtest-integration` |
| `framework/ocaml/kafka-eio-service/test/` | registry/wire config in-process; broker semantics behind the alias | `KAFKA_BROKERS` for the alias; unique topic names | `(test …)` + `runtest-integration` |
| `internal/fixtures/local-demo/test/test_e2e.ml` | full composed path: HTTP → Kafka → worker → Postgres → Loki | broker + Postgres + (optional) Loki, **schema hand-rolled** | `(tests (names …))`, `--force` in CI |
| `internal/tooling/soldev/test/` | ticket/merge machinery, plus one case that reads the live ticket tree | live `internal/pipeline/tickets/` | `(tests (names …))` + python rules |
| `internal/tooling/sol_process/test/` | process capture, stream draining, descriptor ownership | none | **named by no runner** (`VERIF-004`) |
| `examples/pluto/test/` | generated event codecs and charge logic | none | **named by no runner** (`VERIF-004`) |
| `platform/shared/templates/workspace/test/` | the scaffold's own generated tests | none | run *correctly*, by rendering the template and running it from `cli/test/inline/test_scaffold.ml` |
| `ts-tests` job | `npm ci`, `npm run build`, `npm audit` | Node 22 | workflow job; **no tests exist** |

Two boundaries are exercised exactly right and are the models to copy: the scaffold template is
verified by rendering it and running its own suite (`test_scaffold.ml:341-361`), and
`internal/ci/test_hook_install.sh` drives a real `git push` and asserts properties of the
authoritative boundary rather than of a model of it.

## 2. Findings

Ids match the tickets filed in `internal/pipeline/tickets/READY_FOR_ENGINEERING/`.

### VERIF-014 — The shipped `sol_jobs` migrations are stale, and every DB fixture hand-rolls the schema, so no test can see it · **observed** · high

Files: `framework/ocaml/sol-jobs/lib/sol_jobs.ml:174` (the claim statement ends `AND workspace = ?`);
`internal/fixtures/local-demo/migrations/0002_sol_jobs.sql`,
`examples/pluto/db/migrations/0002_sol_jobs.sql`,
`internal/fixtures/venus/db/migrations/0002_sol_jobs.sql` (all **missing** `workspace`, and all
index `sol_jobs_dedupe_idx` on `(kind, dedupe_key)` rather than `(workspace, kind, dedupe_key)`);
`internal/fixtures/local-demo/bin/demo.ml:256` (applies that directory) and `:281`
(`Sol_jobs.Make (EmailJob)`); the three hand-rolled copies at
`framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml:3-23`,
`framework/ocaml/sol-outbox/test/test_sol_outbox.ml:11-42`, and
`internal/fixtures/local-demo/test/test_e2e.ml:165-183`.

Observed directly:

```
$ for f in internal/fixtures/local-demo/migrations/0002_sol_jobs.sql \
           examples/pluto/db/migrations/0002_sol_jobs.sql \
           internal/fixtures/venus/db/migrations/0002_sol_jobs.sql; do
    printf '%s: ' "$f"; rg -q workspace "$f" && echo "HAS workspace" || echo "MISSING workspace"
  done
internal/fixtures/local-demo/migrations/0002_sol_jobs.sql: MISSING workspace
examples/pluto/db/migrations/0002_sol_jobs.sql: MISSING workspace
internal/fixtures/venus/db/migrations/0002_sol_jobs.sql: MISSING workspace
```

`workspace` is a required row identity since BUG-091/FEAT-077: `sol-jobs.md` § *Job table* gives the
canonical DDL and says the claim, retry, completion, failure, lease-renewal and retention statements
all filter by it. So a workspace that applies one of these migrations and then runs `Sol_jobs` gets
`column "workspace" does not exist` — including `demo.exe`, which applies the directory and then
constructs `Sol_jobs.Make`. The reason no test reports this is the second half of the finding: all
three DB fixtures declare `sol_jobs` themselves, with `workspace`, and the E2E suite never runs a
migration file at all. The fixture and the artifact disagree, and the test asserts against the
fixture.

This is the class the brief asks about: the fixture is not the artifact, so the artifact is
unverified. It also means the schema is written in six places (`sol-jobs.md`, three app migrations,
three test fixtures, plus `test_e2e`'s `ALTER TABLE` convergence) and can drift silently, which is
exactly what BUG-115 was.

Desired invariant: a DB suite's schema comes from the shipped migration, so a stale migration fails
the suite that claims to exercise the schema. The library has no migration of its own (by design),
so the correct source is the app's migration directory.

Fix: correct the three stale `sol_jobs` migrations to the canonical shape; make
`internal/fixtures/local-demo/test/test_e2e.ml` apply the real
`internal/fixtures/local-demo/migrations/` through `Migration.apply` instead of `fixture_ddl`; and
give the two library DB suites a single shared schema definition rather than two hand-copies.
`VERIF-007` then covers object ownership within that shared definition.

### VERIF-015 — The E2E suite computes one shared fixture before Alcotest runs, and its cases short-circuit when the fixture is degraded · **observed** · high

Files: `internal/fixtures/local-demo/test/test_e2e.ml:1115-1118` (`let r = run_golden_path ()` and
`let o = run_outbox_path ()` run before `Alcotest.run`); `:263-273` (a missing `POSTGRES_URL`
yields `db_pool = None`); `:156-163` (`truncate_tables` swallows every error); `:367,:388`
(`| Failure _ -> ()` discards a worker-fibre failure); `:1090-1091` (`http_get` failure becomes
`None`); and the case bodies at `:1144`, `:1151`, `:1160`, `:1167`, `:1175`, `:1184`, `:1290`.

The suite performs its entire expensive path once, outside the test runner, then exposes eighteen
cases over the resulting record. Every case is conditional on that one record:

```ocaml
if r.db_rows = 0 then () else Alcotest.(check int) "3 rows stored" 3 r.db_rows
match r.loki_resp with None -> () | Some resp -> …
match o.ob_loki with None -> () | Some resp -> …
```

So when Postgres is absent the whole `postgres`/`jobs`/`outbox` group passes having asserted
nothing, and the Loki cases pass when Loki is absent — the very outcome `ci.yml:278` documents
("LOKI_URL is unset, so the Loki assertions self-skip"). This is the `VERIF-006` shape one level
up: not one named case that asserts nothing, but a suite whose *fixture* decides whether eighteen
cases have anything to say, with no signal to the reader. The same structure also makes a setup
failure opaque — `run_golden_path` aborts the process rather than failing the case it belongs to —
and the swallowed `truncate_tables` error means stale rows from a previous run can satisfy an
assertion.

Desired invariant: a case either establishes its claim or fails naming the missing dependency.
The shared heavy fixture is fine; the *short-circuit around its absence* is not.

Fix: make the fixture's required dependencies explicit inputs (fail, don't degrade); turn the
"nothing to assert" branches into `Alcotest.fail` naming the dependency; do not swallow
`truncate_tables` errors; and report per-case setup failures instead of aborting the suite. This
naturally folds into `VERIF-002` (the dependency is part of the target) and `VERIF-006`.

### VERIF-016 — A unit suite prints `[skip]` and passes when the ambient environment already holds the variable it means to test · **observed** · medium

File: `framework/ocaml/sol-fn/test/test_fn.ml:213-228`.

```ocaml
let test_lambda_trigger_requires_runtime_api () =
  if Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" <> None
  then Printf.printf "[skip] AWS_LAMBDA_RUNTIME_API is set in this environment — skipping\n%!"
  else
    …
```

The case asserts that `Fn.Make (Lambda_fn)` returns `` Error (`Config …) `` when
`AWS_LAMBDA_RUNTIME_API` is unset. If a developer or runner happens to have it set, the case
disappears and the suite is still green — the failure mode is "the environment looks like Lambda",
which is precisely when the case is most likely to be misread. The suite already has a `with_env`
helper (`:167-171`), so the case can control the variable and always run. The `EPERM` skips in
`test_sol_obs.ml:17-18` and `test_worker.ml:243-246` are the same class and are covered by
`VERIF-006`; this instance is not, because it is a case *choosing* to skip on a variable it could
have unset.

Fix: wrap the case in a helper that removes `AWS_LAMBDA_RUNTIME_API` for its duration (and add an
`unset_env` sibling to `with_env`), so it runs everywhere and asserts the contract it names.

### VERIF-017 — Module-level mutable fixtures are shared by every test in a module · **observed / risk** · medium

Files: `cli/test/support/targets_fixture.ml:1`
(`let written : (string, (string * string) list) Hashtbl.t = Hashtbl.create 8`);
`framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml:266` (`let current_pool = ref None`).

Windtrap gives one runner per module, so the tests in a module share a process: module-level
mutable state is cross-test state even though separate modules are isolated. `written` is keyed by
`Sys.getcwd ()` and accumulates across every test that writes a target file, so two tests that
happen to share a working directory share the rendered `sol/environments.yml`; `current_pool` is
written by one test and read by a helper. Both work today because tests run sequentially and each
uses a fresh temp directory, but the coupling is invisible in the test body and turns an ordering
change into a failure with no relationship to the change. Windtrap ships `bracket` (per-test
setup/teardown) and `fixture` (lazy shared resource) for exactly this; the CLI suite uses neither.

Fix: make the target-file fixture per-test state (a value threaded through, or `bracket`), and
thread the pool through the helper that needs it rather than a module-level `ref`.

### VERIF-018 — The auth suite tests a build-time copy of a private module, not the service contract · **risk** · medium

File: `framework/ocaml/sol-svc/test/dune:1-6` copies `../lib/auth_internal.ml` to
`test_auth_internal.ml`; `test_auth.ml` then calls `Test_auth_internal.validate` /
`constant_time_equal` directly (e.g. `:7`, `:14`).

`auth_internal` is a `private_modules` entry of `sol_svc` (`lib/dune`), so the test cannot link it
by name; the copy keeps the source in sync because Dune re-copies it from the dependency. The cost
is a second compilation of production logic under a test-only name, and tests that bind to the
module's *function* surface rather than to the HTTP/`Service` contract the module exists to serve.
That is the implementation-detail coupling the brief asks about: a refactor that keeps `Service`'s
observable auth behaviour but changes an internal helper breaks the suite without changing the
contract, and a regression that the HTTP layer would expose can be invisible if the helper is
called with hand-built inputs. Some direct helper coverage is legitimate; the copy mechanism is the
part worth removing. The same pattern exists for `route_internal` if it is ever tested this way,
and the `For_testing` modules in `sol-jobs`, `sol-worker`, `sol-svc` and `sol-outbox` are the
sanctioned seam.

Fix: move the auth assertions to the `Service` boundary (a real request against the in-process
server, which `test_service.ml` already runs) and, where a pure helper genuinely needs direct
coverage, expose it through a `For_testing` module in the library rather than copying the file.

### VERIF-019 — The E2E suite re-asserts library semantics that are already covered at a cheaper boundary · **risk** · low

File: `internal/fixtures/local-demo/test/test_e2e.ml:1193-1275`.

The E2E class is the only place the *composition* is verified, and that is its job. But it also
asserts sol-jobs retry counts (`:1244-1255`), outbox duplicate/suppression semantics (`:1206-1214`)
and per-key ordering (`:1215-1222`), each of which has a dedicated Postgres test in
`framework/ocaml/sol-jobs/test/test_sol_jobs_pg.ml` and
`framework/ocaml/sol-outbox/test/test_sol_outbox.ml`. Those suites need only Postgres; the E2E class
needs Postgres **and** a broker **and** Loki, and runs under `--force` for 180 s. Asserting the
detail there spends the most expensive resource on evidence already available at the cheapest
authoritative boundary, and — per `VERIF-014`/`VERIF-015` — those detail assertions are exactly the
ones that silently vanish when the E2E dependencies are absent.

Fix: keep in E2E only what composition makes different (a request reaches Kafka, a worker consumes
it, a durable effect is visible, the metric/log is emitted for that transaction); move the
retry-count/order/dedupe detail to the Postgres suites that already own it. This is the same
"cheapest authoritative boundary" rule the audit is applying everywhere else.

### VERIF-020 — The TypeScript applications have no tests, and the job named for them only builds · **observed** · low (tracked)

Files: `.github/workflows/ci.yml:1368-1408` (`ts-tests` runs `npm ci`, `npm run build`, `npm audit`);
`find` for `*.test.ts`/`*.spec.ts` returns **0**.

TypeScript is a first-class application language (`DEC-022`), and the golden-path smoke proves a
real deploy. But there is no unit/property layer at all, and the job's name overstates what it
does: it typechecks and audits. This may be deliberate — `FEAT-084` ("TypeScript unit scaffolding")
is in `BACKLOG` and `FEAT-102` tracks production qualification — so the finding is not "write TS
tests now"; it is that the coverage claim should be recorded per `DEC-022` (a per-language verdict,
not silence) and the job should be named for what it does. No new ticket is filed; the tracking
already exists.

## 3. What is working well and should not be touched

- **Rendering the fixture and running its own suite** (`test_scaffold.ml:341-361`) is the correct
  boundary for the scaffold template, and is the shape `VERIF-014` asks for elsewhere.
- **The Kafka class isolates by unique per-run names** (`test_e2e.ml:213-217`,
  `test_kafka_service_integration.ml:18-23`) instead of by scheduler order — the model
  `VERIF-007` asks the Postgres class to copy.
- **The local HTTP servers** in `sol-obs` and `sol-fn` fakes are contract-faithful: the test drives
  the real client against a real socket and inspects the bytes, rather than replacing the client.
- **`test_sol_process.ml`** is a rare example of asserting resource ownership (descriptor counts,
  unreaped children) rather than only return values; `VERIF-004` is about it never running, not
  about its quality.
- **`Worker.For_testing` / `Service.For_testing` / `Sol_outbox.For_testing`** are the right shape
  for a test seam in a library: named, in the library, and narrower than the copy in `VERIF-018`.

## 4. Verification of this audit

- **Schema drift** — `for f in <the three migrations>; do rg -q workspace "$f" && …; done` printed
  `MISSING workspace` for all three; the canonical DDL is `framework/ocaml/sol-jobs/sol-jobs.md`
  § *Job table`; the library's requirement is `sol_jobs.ml:174` `AND workspace = ?`.
- **Fixture copies** — `rg -n 'CREATE TABLE IF NOT EXISTS sol_jobs|CREATE TABLE sol_jobs'` returns
  the three migrations plus `test_sol_jobs_pg.ml:5`, `test_sol_outbox.ml:26` and `test_e2e.ml:169`.
- **E2E shape** — `sed -n '1115,1118p'` shows both runners called before `Alcotest.run`; `rg` shows
  the `then ()` / `None -> ()` bodies at the listed lines.
- **Skip** — `sed -n '213,218p' framework/ocaml/sol-fn/test/test_fn.ml` shows the conditional
  `[skip]`.
- **Shared state** — `rg '^let .*Hashtbl|^let .*ref'` over the test trees returns exactly
  `targets_fixture.ml:1` and `test_sol_jobs_pg.ml:266`.
- **Private-module copy** — `sed -n '1,6p' framework/ocaml/sol-svc/test/dune` shows the `(copy …)`
  rule; `lib/dune` lists `(private_modules auth_internal route_internal)`.
- **No TypeScript tests** — `find … -name '*.test.ts' -o -name '*.spec.ts'` returned 0.
- **Suite inventory** — `rg -l --glob dune '\(test|\(tests|inline_tests'` enumerated the stanzas in
  § 1; `python3 internal/ci/check_test_reachability.py` exits 0 at this commit.
