---
id: FEAT-114
type: feature
severity: medium
title: Provide a shared bounded operation-retry helper
source: DEC-021 amendment (2026-09-29) — Kafka distributes facts; jobs perform retryable work
---

**Depends on:** None.

**Related:** `DEC-021` (the amendment; supporting work), `FEAT-113` (the deletion
that makes this the normal path), `pg-eio`, `aws-eio`, `kafka-eio` (the dependency
calls it wraps), `FEAT-112` (`sol-jobs`' retry policy, whose vocabulary this should
share).

## What this is

The amendment removes message-level retry and puts transient failures at the
operation level: retry the dependency call, not the handler. The framework has no
shared helper for that — retry logic exists only inside the retry-topic machinery and
`sol-jobs` — so today a transient `pg-eio` or `aws-eio` failure is swallowed, raised
into a fail-stop, or retried by hand-rolled code in every application.

This is **follow-up supporting work, not a migration prerequisite**: it does not gate
`FEAT-113`, because an application can already implement a correct bounded retry. Its
absence is an ergonomics gap, not a correctness hole.

## Required behaviour

- One bounded, jittered, non-blocking retry helper over an
  `(unit -> ('a, 'e) result)`-shaped operation, using the policy vocabulary
  `sol-jobs` and `sol-worker` already use — `base_delay_s`, `max_delay_s`,
  `max_attempts`, `jitter_ratio` — so there is one retry vocabulary, not three.
- It retries **operations, never messages**: it must not become a way to re-run a
  handler, or a route back to message-level retry.
- It yields to Eio between attempts; it never blocks the domain.
- Exhaustion returns the last error, and the caller decides `Fail` or a job.
- It is usable from `-svc`, `-worker` and `-fn`.

## Non-goals

- Not a message-retry mechanism, and not a scheduler.
- Not a policy engine; no per-error-class routing in the first version.
- Not a substitute for idempotency or for `sol-jobs`.

## Acceptance criteria

- The helper is public, documented, and used by at least one generated or example
  path.
- Its policy vocabulary matches `sol-jobs` and `sol-worker`.
- A test covers success after retry, exhaustion, cancellation, and jitter bounds.
- It is documented as operation-level, with the message-level alternative explicitly
  rejected.

**Demo/example coverage:** the tutorial shows an operation retried in place,
contrasting with handing independent work to `sol-jobs`.

**TypeScript parity:** record the verdict — a TS equivalent in `@sol-fab/*`, or a
tracked follow-up with a trigger (DEC-022).

## Disposition (2026-10-03) — actionable pre-alpha

Premise re-checked against current `origin/main`; the work is still real.
Evidence: `max_attempts`/`jitter_ratio`/`base_delay_s` appear only under `framework/ocaml/sol-jobs`; there is no shared bounded operation-retry helper.

Promoted to `READY_FOR_ENGINEERING/` by the pre-alpha BACKLOG adjudication
(`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`).

## Completion notes (2026-10-03)

**Premise re-checked before pickup** against `origin/main @ ea9e11d9`:
`rg -n 'max_attempts|jitter_ratio|base_delay_s' framework/ocaml` matched only
`framework/ocaml/sol-jobs/lib/sol_jobs.{ml,mli}` and its tests — no shared helper existed.

**What landed.**

- `framework/ocaml/sol-retry/` is a new public package (`sol-retry`, module `Sol_retry`),
  depending on nothing but `eio`: `policy` (the four-field vocabulary), `default_policy`,
  `validate`, `backoff_s`, `of_policy` (a validated `t`) and
  `run ~clock ?rng t (unit -> ('a,'e) result)`. `of_policy` carries the one executable
  invariant — `max_attempts = 0` is refused there, so an unusable policy cannot reach the
  loop; a negative `max_attempts` means unbounded.
- **One vocabulary, not three.** `Sol_jobs.retry_policy` is now
  `Sol_retry.policy` (`type retry_policy = Sol_retry.policy = { … }`),
  `Sol_jobs.default_retry_policy = Sol_retry.default_policy`, and `sol-jobs` computes both
  its claim budget backoff and its policy validation through `Sol_retry`. The formula and
  the field set exist in exactly one place.
- **Tests** (`framework/ocaml/sol-retry/test/test_sol_retry.ml`, 12 cases): first-attempt
  success with no wait, retry-until-success, exhaustion returning the *last* error after
  exactly `max_attempts` attempts, two backoffs of exactly `base_delay_s` between attempts,
  cancellation via `Eio.Fiber.first` (the loop observes `Eio.Cancel.Cancelled` and stops),
  unbounded attempts stopping at the first success, jitter bounds and the `max_delay_s` cap
  over seeded draws, determinism per seed, and the `validate`/`of_policy` refusals. The
  clock is `Eio_mock.Clock`, so the timing assertions are exact rather than wall-clock.
- **Docs:** [`sol-retry.md`](../../framework/ocaml/sol-retry/sol-retry.md) (contract, the one
  vocabulary, API, usage, and what it is *not*); `TUTORIAL.md` § *The worker* shows the
  retry in place and contrasts it with `sol-jobs`; `application-authoring.md` § `-worker`
  now states operation-level retry instead of the stale "the consumer's error handling
  decides whether an event is retried"; a new row in
  `internal/specs/framework-conventions.md` § *The conventions*.
- **Wiring:** `dune-project` package stanza, hand-written `sol-retry.opam`,
  `platform/local/scripts/prepare-framework-deps.sh` (pin + install), `examples/pluto/pluto.opam`
  (`depends` and the `#main` development-channel `pin-depends` entry, which the example
  Dockerfile smoke rewrites to the head under test).

**Demo/example coverage:** `examples/pluto/app/comms/notify_worker` retries its whole
Postgres transaction in place with `Sol_retry.run`, returning `Worker.Fail` only once the
budget is spent; its `Make(Config)` carries the clock (`env#clock` from `bin/main.ml`) because
`handle` runs inside the consumer's fiber and the helper has no ambient clock. The same shape
is in `TUTORIAL.md`, and the pluto Dockerfile is built by `example-dockerfile-smoke`.

**Acceptance mapping**

| Criterion | Evidence |
|---|---|
| Public, documented, used by an example path | `sol-retry.opam` + `dune-project`; `sol-retry.md`; `examples/pluto`'s notify worker (built by `dune build` and the example Dockerfile smoke) |
| Policy vocabulary matches `sol-jobs` / sol-worker | `Sol_jobs.retry_policy = Sol_retry.policy`, `Sol_jobs.default_retry_policy = Sol_retry.default_policy`, `Sol_jobs.For_testing.backoff_s = Sol_retry.backoff_s`; `dune test framework/ocaml/sol-jobs/` green |
| Tests: success after retry, exhaustion, cancellation, jitter bounds | the 12-case suite above |
| Documented as operation-level, message-level alternative rejected | `sol-retry.md` § *What it is not*; the conventions row; `TUTORIAL.md` § *The worker* |

**Checks**

- `dune build` (whole workspace), `dune fmt` + `internal/ci/check_ocamlformat.sh --all`: green.
- `dune test framework/ocaml/sol-retry/` → 12 tests, all pass;
  `dune test framework/ocaml/sol-jobs/` → 12 tests, all pass (the vocabulary delegation is
  behaviour-preserving).
- `internal/ci/check_no_comments.sh` (856 files), `check_support_refs.sh`,
  `check_examples_self_contained.sh`: green.
- `internal/ci/run_fast_checks.sh`, and `verify always` / `verify static` through it.

**Signature change to note:** `Sol_jobs.For_testing.backoff_s` now takes `~attempt` (it is
`Sol_retry.backoff_s` directly); its five call sites in `test_sol_jobs.ml` were updated in the
same pass. Pre-alpha, and test-only API.

**Not verified here:** no live cluster or broker was exercised, so the pluto retry is
compile-checked and reviewed rather than driven against a failing Postgres; the helper's own
behaviour (including cancellation and exhaustion) is covered deterministically by the suite.

**Language parity (DEC-022):** TypeScript verdict recorded as **deliberately deferred** — no
`@sol-fab/*` operation-retry helper exists yet — tracked by `FEAT-135` with its trigger, and
stated inline on the new conventions row.

