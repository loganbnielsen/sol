---
id: FEAT-078
type: feature
severity: medium
source: worker retry semantics and product-positioning review 2026-09-14
---

**Depends on:** BUG-028, BUG-029, BUG-030 (retry delivery must be correct before the
generated golden path recommends it).

**Related:** DEC-021, FEAT-076, FEAT-077, DOCS-015.

Make the generated worker experience match Sol's intended worker contract, and make
retry an explicit capability rather than an implicit fallback.

## Problem

Sol's intended worker positioning is:

> **Kafka is the default. `Retry_topics` is the recommended/default retry mechanism when
> retries are enabled.**

The generated worker experience does not currently match that contract.

`sol new worker <domain>/<name>` generates a Kafka worker with no Postgres dependency,
but the generated run site does not supply a retry strategy. The runtime therefore falls
back implicitly to `In_memory`, whose retry behavior sleeps inside the source-partition
processing fiber.

The generated worker also advertises:

```text
Returning Worker.Retry causes the message to be retried.
```

without making the resulting partition-blocking semantics explicit.

The full-workspace scaffold additionally generates `comms/notify_worker` with a required
Postgres pool and a handler that returns `Worker.Retry` for database failures. This makes
the flagship example imply a broader Kafka+Postgres architectural requirement than the
core worker abstraction actually has.

## Product contract

A basic Sol worker is a Kafka consumer:

```text
Kafka → Sol worker → Worker.handle → Ack
```

It does not require Postgres, a job scheduler, or an implicit retry mechanism.
Retry/DLQ support is an additional Kafka-native capability:

```text
Kafka worker
    └── explicit retry capability → Retry_topics → Kafka retry/DLQ topics
```

Postgres is not part of Kafka retry delivery. `sol-jobs` remains a separate future
primitive governed by DEC-021/FEAT-077.

## No implicit `In_memory` fallback

`In_memory` must not be selected merely because no retry configuration was supplied. Its
semantics are materially different from ordinary Kafka processing:

```text
handler returns Retry → sleep in source-partition fiber → later records in that partition cannot progress
```

It remains available for development, testing, or workloads that deliberately accept
those semantics, but it is always an explicit strategy. `Kafka_service.default_retry_strategy`
must be removed or renamed so no implicit fallback survives at the library layer either.

## Retry capability must be declared, not discovered at runtime

A missing retry strategy must not become a per-message runtime error:

```text
consume offset N → handler returns Retry → discover no retry strategy → process exits
→ Kafka redelivers N → process exits → ...
```

That is a poison-message crash/redelivery loop — the exact failure FEAT-076 exists to
prevent. Prefer, in order:

1. Make invalid configuration unrepresentable through the OCaml API. Concretely: an
   Ack-only worker whose `handle` returns only `Ack` (a restricted outcome type, not the
   full `Ack | Retry | Dead_letter`), and a retry-capable worker whose `run` *requires* a
   retry strategy. Then "`Retry` with no strategy" is a type error, and the simple golden
   path cannot express `Retry`/`Dead_letter` at all. This is a breaking change to the
   `WORKER` contract FEAT-076 just shipped: workers that can return `Retry`/`Dead_letter`
   must adopt the retry-capable form. Note the existing `outcome` is a nominal variant, so
   the restricted type is a separate declaration, not a polymorphic-variant subset.
2. Otherwise, validate declared worker capabilities and retry configuration at startup,
   before Kafka consumption begins. Note this requires a declared capability — an
   arbitrary `handle` cannot be statically inspected — so the capability must be part of
   the worker's declared type/signature, not inferred.
3. Never discover missing retry infrastructure only after a consumed message returns
   `Retry`/`Dead_letter`.

If compile-time enforcement requires disproportionate API complexity, startup validation
is preferable to a misleading type abstraction — but option 3 is never acceptable.

## `Dead_letter` is part of the explicit capability

Under the current default (`In_memory`), `Dead_letter` is logged and `ack()`'d — a silent
drop, and arguably worse than the `Retry` case because there is no retry to fall back on
(`framework/kafka-eio-service/lib/kafka_service.ml`, the `In_memory` branch).

An Ack-only worker must not be able to return `Dead_letter`. Where a DLQ is not
configured, `Dead_letter` must fail closed (never acknowledge-and-discard), consistent
with BUG-028's invariant.

## Retry policy

Both explicit retry implementations converge on one policy vocabulary:

```ocaml
type retry_policy =
  { base_delay_s : float
  ; max_delay_s : float
  ; max_attempts : int
  ; jitter_ratio : float
  }

type retry_strategy =
  | In_memory of retry_policy
  | Retry_topics of retry_policy
```

`max_attempts` means maximum handler invocations, including the initial invocation: with
`max_attempts = 5`, the handler runs 5 times total (initial + 4 retries). A negative value
means retry indefinitely, matching the existing `In_memory` policy; `max_attempts = 1`
means no retry. The count is unified, but the *disposition on exhaustion* currently
differs by strategy and must be documented: `Retry_topics` routes the message to the DLQ,
whereas `In_memory` records a partition error and stops the worker (no DLQ). Decide
whether that asymmetry is intended; do not leave it implicit.

**Backoff:** `delay = base_delay_s × 2^(attempt - 1)`, subject to jitter and
`max_delay_s`. This is a **user-visible behavior change** for existing `Retry_topics`
users: today `backoff_s n = min(1.0 × 2^n, 600.0)` with `n` starting at 1, so the first
retry waits 2s and the cap is hardcoded at 600s. Unifying the vocabulary changes the
first retry to `base_delay_s` and the cap to `max_delay_s`. Call this out in the
changelog, not just in the type.

**Jitter:** there is none today, and backoff is fully deterministic. The requirement is an
invariant, not a formula:

> No policy-generated delay exceeds `max_delay_s`.

This matters because `max_delay_s` is also the steady-state bound on the head-of-line
delay one waiting retry imposes on its partition, and a jittered 72s delay from a 60s cap
silently breaks that relationship. Apply jitter before the cap, then clamp:

```text
raw      = base_delay_s * 2^(attempt - 1)
jittered = raw * (1 + U(-jitter_ratio, +jitter_ratio))
delay    = clamp jittered 0.0 max_delay_s
```

Symmetric jitter keeps the delay centered on the nominal backoff while the clamp keeps
`max_delay_s` a true maximum. Consequence: a raw backoff within `jitter_ratio` of the cap
can only jitter downward once clamped, so capped delays land below the cap and still
spread rather than synchronizing at exactly `max_delay_s`. If pile-up just under the cap
is a concern, downward-only jitter applied after the cap is an acceptable alternative —
either is fine; tests assert the invariant either way.

The RNG must be injected/seedable so tests are deterministic; this repo has been bitten
twice by jitter on the global unseeded `Random` module (`docs/planning/WORK_SUMMARY.md`,
and `Obs_trace`'s ID generator before its fix).

`max_delay_s` must be chosen deliberately: for `Retry_topics` it is the steady-state bound
on the direct intra-partition head-of-line delay imposed by a waiting head retry. Under
backlog or overload, actual delay may exceed it indefinitely.

## Policy ownership

`Worker.Retry of string` communicates disposition plus diagnostic explanation. The string
is **not** policy. The runtime must never inspect the reason string to determine delay,
retry class, attempt count, routing, priority, backend, or retryability. Do not introduce
string conventions such as `Retry "slow:database unavailable"`. If applications later
need to influence retry policy, add an explicit typed concept. No per-message or
per-handler-call retry policy in this change.

## Generated worker

The incremental worker scaffold stays DB-free and Kafka-native. Its example demonstrates
`Ack` without implying retry is free or implicit. If it demonstrates `Retry`, it must
also demonstrate explicit retry configuration. The generated worker stays understandable
using Kafka concepts: topic, partition, consumer group, key, offset/commit, and
retry/DLQ only when explicitly enabled.

## Full-workspace scaffold

**Decision (resolve the current either/or):** keep the DB-backed `comms/notify_worker`
example — its purpose is to demonstrate svc → event → worker → Postgres wiring end to
end, and making it DB-free would gut it. Instead:

- present it explicitly as an *application* example, not as infrastructure `Sol.Worker`
  requires;
- make the incremental `sol new worker` scaffold the canonical minimal DB-free worker;
- keep the worker abstraction docs free of any Postgres implication.

The absence of `POSTGRES_URL` must not prevent a DB-independent Kafka worker from running.

## Retry default

Two meanings of "default" are distinct:

> Kafka processing is the default worker behavior.

> When durable asynchronous retry is explicitly enabled, `Retry_topics` is the
> recommended/default retry implementation.

Do not introduce a retry-backend enum or a Postgres-backed retry strategy.

## Handler metadata

Do not change the `WORKER` handler signature in this ticket. The current attempt value
exists in Kafka retry metadata but is not exposed to the handler; adding a `context`
record (`{ trace; attempt; ... }`) would touch every worker, scaffold, example, test, and
doc immediately after FEAT-076. Track attempt/context exposure separately. If retry-chain
identity is later introduced, specify its wire representation and lifecycle independently
— `retry_id`/`first_seen` do not exist merely because attempt metadata does.

## Prerequisites for recommending `Retry_topics` as production-ready

Do not change generated production guidance to *recommend* `Retry_topics` until the known
reliability defects are fixed: BUG-028 (decode failure cannot ack-drop the last durable
copy), BUG-029 (publication failure cannot silently kill the relay; relay stoppage must
be observable), BUG-030 (retry topics isolated by consumer group). Until then,
`Retry_topics` is available but not blessed; a generated basic worker is Ack-only and
configures no retry.

## Non-goals

This change does not: add retry buckets; add Postgres-backed Kafka retry; implement
`sol-jobs`; add RabbitMQ or another broker; introduce a generic messaging backend; change
the `Worker.handle` signature; let `Retry of string` control policy; introduce arbitrary
per-message retry policy; or hide Kafka's ordering/delivery semantics.

## Acceptance criteria

- A newly generated basic worker has no Postgres dependency.
- A newly generated basic worker does not implicitly select `In_memory`; it is Ack-only
  unless retry is explicitly configured.
- Missing retry configuration cannot produce a poison-message crash/redelivery loop.
- `In_memory` can only be selected explicitly; `default_retry_strategy` no longer
  supplies an implicit fallback.
- `Dead_letter` cannot be acknowledged-and-discarded when no DLQ is configured.
- `Retry_topics` uses the same retry-policy vocabulary as `In_memory`.
- Backoff includes configured jitter with an injectable RNG, and no policy-generated
  delay exceeds `max_delay_s` (or falls below 0).
- `max_attempts` has one documented interpretation across both strategies, and the
  disposition on exhaustion (`Retry_topics` → DLQ vs `In_memory` → worker stops) is
  documented or unified.
- The `Ack`-only vs retry-capable split's compatibility impact on FEAT-076 workers is
  documented.
- The backoff-schedule change for existing `Retry_topics` users is in the changelog.
- Generated comments/docs do not imply stronger retry/order/timing guarantees than the
  runtime provides.
- Full-workspace scaffolding does not make Postgres appear mandatory for the worker
  abstraction.
- No Postgres retry backend, RabbitMQ backend, or generic backend enum is introduced.
