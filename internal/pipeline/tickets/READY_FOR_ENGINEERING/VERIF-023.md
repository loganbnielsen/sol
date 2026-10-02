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
