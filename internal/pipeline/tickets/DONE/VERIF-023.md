---
id: VERIF-023
type: verification
severity: medium
title: "The required `test` job is intermittently red — a Postgres suite loses its server, and a port-forward lock is not taken"
source: "CI, 2026-10-02 — PR #937 run 37075828396 attempt 1, and PR #932 run 37072734206 attempt 1"
---

The required `test` job is intermittently red — a Postgres suite loses its server, and a port-forward lock is not taken

**Depends on:** None.

## Observed

Two independent PRs had a required `test` job fail on their first attempt and pass
on re-run, with no change that could explain the difference. Both were filed while
landing the DEC-022 cross-language parity work, but neither touches OCaml
framework code:

**Instance A — a Postgres-backed suite loses its connection (PR #937, FEAT-123).**

Run `37075828396`, event `pull_request`, head
`0a9982745515de01349f688b1c88e62af68f3592`, attempt 1: failure. The failing step is
`test` → *Framework integration tests (broker and database backed)*, and four cases
fail with a connection error rather than an assertion:

```
##[error]DROP SCHEMA IF EXISTS sol_test_sol_outbox CASCADE: connection failed:
  Failed to connect to <host>:5432/sol_dev: Connection failure: connection to server
  at "localhost" (::1), port 5432 failed: server closed the connection unexpectedly
FAIL atomicity › state and intent commit together
FAIL atomicity › an undeclared kind is refused
FAIL relay › per-key order is the ordering token, not insertion order
FAIL relay › a failed publish does not advance the key
```

Attempt 2 of the **same run id and the same head SHA** — no code change in between —
is `success`. Reproduce the evidence with:

```bash
gh run view 37075828396 --repo loganbnielsen/sol --log-failed
gh run view 37075828396 --repo loganbnielsen/sol --json attempt,conclusion,headSha
```

**Instance B — a port-forward lock is not taken (PR #932, FEAT-126).**

Run `37072734206`, head `587e7465d50ad5117e4b0133ed5a3e868557320e`, attempt 1:
failure at `test` → *Unit tests (no broker/Postgres/Loki required)*:

```
##[error]lock not taken
FAIL Test_port_forward › records and liveness (REFAC-126): replace conflicting
```

This one is weaker evidence than A: the PR subsequently pushed an unrelated change
(a TypeScript demo file), so the passing run is a new run rather than a re-run of
the identical head. The failing test is untouched by that change, so a lock that is
not taken on the first attempt remains the simplest explanation — but it has not
been reproduced under a fixed head, which is exactly what the handoff below is for.

## What is ruled out

- The diff on each PR: both are TypeScript demo, ticket and CI-workflow changes;
  neither modifies `framework/`, `platform/` or the OCaml libraries the failing
  suites exercise. Instance A's failures are in `sol-outbox`'s `atomicity` and
  `relay` suites; Instance B's is in a port-forward test.
- `main`: the most recent `main` runs at the time of filing are green, and the
  flake is not attributed to any merged change.

## Hypothesis (not a conclusion)

"server closed the connection unexpectedly" points at the Postgres *server* going
away (a crashed or OOM-killed service container) rather than at the suite's SQL —
which would make the failure a function of the runner's resource pressure and the
number of DB-backed suites running in parallel, not of the code under test. That is
consistent with it appearing on a first attempt under load and not on a re-run that
schedules differently. VERIF-007 (each Postgres suite owns its own schema, merged
2026-10-02T22:50Z) is already in the base of run `37075828396`, so it does not by
itself eliminate this.

## Handoff

For the VERIF workstream: reproduce both instances under a fixed head, establish
whether the Postgres service is dying (runner logs, service-container exit code,
memory) or the client is the failing side, and either eliminate the flake or make
the failure mode self-describing so a re-run is not needed to distinguish "the
code is wrong" from "the runner was unlucky". Instance A matters most: it fails a
*required* check on a PR whose content is unrelated to the suite, which costs every
later worker a full CI cycle to re-run.

## Completion (2026-10-02)

**Instance B — reproduced and eliminated.** On `origin/main @ f7d45074`,
`dune build @ci-unit` failed `Test_port_forward › records and liveness
(REFAC-126): replace conflicting` with `lock not taken` in 1 of 3 runs (the 10s
`wait_until` bound, matching the CI shape). Root cause: `hold_lock`'s forked
child makes a *single* `F_TLOCK` attempt while the parent polls `P.is_running`,
which itself briefly takes the lock; a collision makes the child `_exit 2` and
the parent then never sees a holder. Separately, every port-forward test used a
fixed forward name, so the lock/pid/record files in the shared XDG state and the
fixed `/tmp/sol-pf-<name>.log` path are shared across concurrent runs and
worktrees. Fix: `hold_lock` synchronizes on a pipe (the child reports whether it
took the lock, failing with the reason otherwise), every test uses a run-unique
name, the fake-kubectl marker is unique and `PATH` is restored under
`Fun.protect`, and the start/stop test stops the forward in a `finally`.
Evidence: 0 port-forward failures in 5 consecutive `@ci-unit` runs (was 1/3),
and the isolated suite passes 5/5.

**A third flake found while reproducing A.** 1 of 20 `@ci-integration-pg` runs
failed `sol_jobs_pg › long handler renews its lease` with five
`outbox_e2e_effect` rows (the E2E fixture's kind) in its `sol_jobs` result
alongside its own row; `public.sol_jobs` held exactly those E2E rows. The two DB
suites isolated by a session `SET search_path` while the E2E fixture owns
`sol_jobs` in `public`, so any loss of the session setting routes a suite at the
shared table. Hardened: both suites now put `search_path` in the connection URL
(`?options=-csearch_path=<schema>`, verified to reach libpq at connection time
with the `pg-eio`/caqti stack), so every pooled connection is scoped, and each
asserts `current_schema()` after setup so a future loss is a named failure
rather than silent contamination. Evidence: 20/20 clean runs.

**Instance A — not reproducible locally; made self-describing.** Across 40+
`@ci-integration-pg` runs the local `sol-postgres` never restarted, was never
OOM-killed, and never closed a connection; the failed attempt's runner logs are
no longer retrievable because the run later succeeded. The handoff's second
option therefore applies: a `Integration failure diagnostics` CI step now dumps
`docker ps -a`, each container's status/exit code/`OOMKilled`/restart count and
last 40 log lines, and runner memory whenever the integration step fails, so the
next occurrence states whether the server died instead of costing a re-run to
learn.

- Demo/example: not applicable — test harness, CI diagnostics and test-suite
  isolation only. Language parity (DEC-022): no application-facing contract
  change.

Moves VERIF-023 to DONE.
