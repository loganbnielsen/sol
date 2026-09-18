# Changelog

Sol is pre-alpha (`~/Code/CLAUDE.md`): no backward-compatibility guarantee, and
breaking changes are made freely when they improve the design. This file
tracks user-visible behavior and API changes worth calling out explicitly,
not a full commit log — see `git log` and `internal/pipeline/tickets/DONE/` for that.

## Unreleased

- **New (FEAT-079):** `-fn`'s `sol.toml` gains `scheduled_concurrency`
  (`allow`/`forbid`/`replace`, default `allow`) and `backoff_limit` (default
  `3`), rendered as the deployed `CronJob`'s `concurrencyPolicy` and
  `jobTemplate.spec.backoffLimit`. Both previously had no Sol-level
  representation — `concurrencyPolicy` silently defaulted to Kubernetes'
  `Allow`, and `backoffLimit` was hardcoded to `3`. Omitting either field
  preserves that exact prior behavior.
- **New (FEAT-079):** `sol fn run <domain>/<name> [--target ...]` and `sol
  local fn run <domain>/<name>` manually invoke a deployed `-fn` by creating
  a Kubernetes `Job` from its deployed `CronJob`'s `jobTemplate` — the same
  execution definition a scheduled run would use. Not constrained by
  `scheduled_concurrency`, which only governs overlap between the CronJob
  controller's own scheduled runs.
- **Behavior change (BUG-031):** `-fn`'s generated `CronJob` now honors
  `sol.toml`'s `cpu`/`memory` fields, which were previously parsed but
  silently discarded in favor of hardcoded values. For a `-fn` app that
  does not set `cpu`/`memory`, the generated `resources.limits` changes
  from `250m`/`256Mi` to `100m`/`128Mi` — now equal to `resources.requests`,
  matching `-svc`/`-worker`'s existing convention (no request-to-limit
  multiplier) instead of preserving the old, undocumented 2.5x/2x ratio.
- **Breaking (FEAT-078):** `Worker.WORKER` is now Ack-only — `handle` returns
  `ack_outcome` (`Ack` only), not the full `outcome`. A worker whose `handle`
  needs to return `Retry`/`Dead_letter` must implement the new
  `Worker.RETRYABLE_WORKER` module type instead and run under the new
  `Worker.Make_with_retry` functor, which requires an explicit
  `~retry_strategy` — there is no implicit default. `Kafka_service.default_retry_strategy`
  is removed, and `Kafka_service.consume_partitioned`'s `~retry_strategy` is
  now a mandatory argument. This closes the failure mode where a missing
  retry strategy was discovered only the first time a message failed to
  process (a poison-message crash/redelivery loop), by making it a compile
  error instead.
- **Breaking:** `Kafka_service.retry_strategy`'s `Retry_topics` case now
  carries a full `Kafka.Consumer.retry_policy` (`base_delay_s`, `max_delay_s`,
  `max_attempts`, `jitter_ratio`) instead of a bare `{ max_attempts : int }`.
  `In_memory` and `Retry_topics` now share one retry-policy vocabulary.
- **Behavior change:** `Retry_topics`'s retry backoff used to be a hardcoded,
  unjittered `min(1.0 * 2^n, 600.0)`. It is now
  `base_delay_s * 2^(attempt-1)`, jittered by `jitter_ratio` and clamped to
  `max_delay_s` — the same computation `In_memory` uses
  (`Kafka.Consumer.backoff_s`, from the `kafka-eio` package's own `0.3.0`).
  A `retry_policy` with `jitter_ratio = 0.0` and the old constants
  (`base_delay_s = 1.0`, `max_delay_s = 600.0`) reproduces the old schedule.
- **Behavior change:** under `In_memory`, a handler's `Dead_letter` no longer
  acks-and-drops the message. `In_memory` has no DLQ to route it to, so it
  now fails closed — the message is left unacknowledged and treated as a
  terminal failure, exactly like an exhausted retry budget. `Retry_topics`'s
  `Dead_letter` handling (route to the DLQ, ack only after that publish
  succeeds) is unchanged.
- `kafka-eio` bumped to `0.3.0`: `Kafka.Consumer.retry_policy` gains
  `jitter_ratio`; `consume_partitioned`'s backoff is jittered; the pure
  `Kafka.Consumer.backoff_s` computation is exposed for direct testing. See
  `~/Code/kafka-eio/CHANGES.md`.
