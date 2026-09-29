---
id: REFAC-157
type: refactor
severity: medium
source: "style-audit theme applied to the pinned support libraries, 2026-09-29 (REFAC-138/REFAC-155 follow-up)"
title: One hooks value across the kafka boundary, and bump the kafka-eio pin
---

One hooks value across the kafka boundary, and bump the kafka-eio pin

**Depends on:** None.

## Problem

REFAC-155 grouped sol's consumer callbacks behind `Kafka_service.consumer_hooks`,
and kafka-eio#27 (merged as `960a427`) has now done the same to the library
itself: `Kafka.Consumer.hooks` with `default_hooks`, taken by `create`,
`consume` and `consume_partitioned`. Sol still pins the *previous* kafka-eio
(`support-refs.txt` → `b9edb4e0`) and still declares its own copy of the same
five lifecycle callbacks:

- `framework/ocaml/kafka-eio-service/lib/kafka_service_intf.ml:69` —
  `consumer_hooks` re-declares `on_ready`, `on_assigned`, `on_revoked`,
  `on_poll`, `on_retry` plus sol's own `on_relay_publish`, and
  `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:308` re-exports it.
- The two records are not the same shape: kafka-eio has added
  `on_poll_error` and `on_warning`, and sol's record cannot carry them, so a
  hook the library grows has to be re-plumbed by hand before sol can observe it.
  That is the drift REFAC-155 removed *within* sol, still present *across* the
  boundary.
- `framework/ocaml/kafka-eio-service/lib/kafka_service.ml:352,414` destructure
  the record back into five labelled arguments to call `Kafka.Consumer.create`.

## Remediation

1. In sol: `type consumer_hooks = { kafka : Kafka.Consumer.hooks ;
   on_relay_publish : ... }` and `no_hooks = { kafka =
   Kafka.Consumer.default_hooks ; on_relay_publish = ... }`, so the library's
   callbacks have exactly one declaration and sol's additions are visibly sol's.
2. Pass `~hooks:hooks.kafka` to `Kafka.Consumer.create`/`consume`/
   `consume_partitioned` instead of destructuring; the relay path
   (`kafka_service_retry_topics.ml:337`) takes `on_relay_publish` and
   `hooks.kafka.on_retry`.
3. Update the two hook records in `framework/ocaml/sol-worker/lib/worker.ml`
   (`:238`, `:346`), the `## Public API` block in
   `framework/ocaml/kafka-eio-service/kafka-eio-service.md` — which
   `internal/ci/check_framework_doc_signatures.py` compares against the `.mli`,
   so a prose-only edit fails CI — and any test constructing hooks.
4. `internal/tooling/scripts/bump-support-refs.sh kafka-eio`, then rebuild and
   run `dune test framework/` (plus the broker-backed suite, since kafka-eio is
   the package under the change).

## Acceptance criteria

- `Kafka_service.consumer_hooks` contains no field that kafka-eio already
  declares, and adding a hook in kafka-eio needs no sol-side declaration.
- `support-refs.txt` and the workspace `.opam` pins point at `960a427`; sol's CI
  is green on the bump.
- The spec's `## Public API` block matches the new `.mli`
  (`check_framework_doc_signatures.py` passes).
- A test proves a hook reaches the consumer loop through the new shape — e.g.
  the worker's `on_assigned`/`on_revoked` health transitions, which the existing
  `sol-worker` suite already exercises, keep working through
  `hooks.kafka`.
- Demo/example: not applicable (internal framework plumbing; no app-author
  surface changes). Language parity: no impact — the TS runtime does not consume
  these OCaml callbacks.

## Completion (2026-09-29)

- **Premise verified** at origin/main: kafka-eio#27 (`960a427`) had landed `Kafka.Consumer.hooks` + `default_hooks` on the library side while sol still pinned `b9edb4e0` and re-declared the same five lifecycle callbacks in `Kafka_service.consumer_hooks` (which could not carry the library's new `on_poll_error`/`on_warning`).
- **Change.** `consumer_hooks` is now `{ kafka : Kafka.Consumer.hooks ; on_relay_publish : … }`, with `no_hooks = { kafka = Kafka.Consumer.default_hooks ; on_relay_publish = … }`, so the library's callbacks have exactly one declaration and sol's additions are visibly sol's. `Kafka_service.consume`/`consume_partitioned` pass `~hooks:hooks.kafka` to `Kafka.Consumer.create`/`consume`/`consume_partitioned` instead of destructuring five callbacks and re-applying them; the two retry-path call sites in `kafka_service_retry_topics.ml` (the relay consumer and the retry consumer's no-op retry sink) were re-expressed the same way. `sol-worker`'s two hook records nest their callbacks under `kafka = { Kafka.Consumer.default_hooks with … }`, keeping `on_relay_publish` where it belongs. `support-refs.txt` and the three workspace `.opam` pins moved to `960a427` (`bump-support-refs.sh kafka-eio`; `check_support_refs.sh` passes).
- **Spec.** `kafka-eio-service.md`'s `## Public API` block carries the new `consumer_hooks` shape — required by `internal/ci/check_framework_doc_signatures.py`, which compares it against the `.mli`, so a prose-only edit would fail CI (as it did on BUG-067).
- **Tests.** `dune test framework/` is green, including the broker-backed `kafka-eio-service` integration suite (17 tests) against the local Redpanda: those tests wait on `on_ready`/`on_assigned` through `Kafka_service.consumer_hooks`, so a hook that failed to reach `Kafka.Consumer`'s poll fiber would time out rather than pass. `sol-worker`'s 14 tests cover the readiness/liveness transitions that run through the same path.
- **Demo/example:** not applicable — internal framework plumbing; `Kafka_service.consumer_hooks` is not an app-author surface, and no example constructs hooks. **Language parity:** no impact; the TypeScript runtime does not consume these OCaml callbacks.
