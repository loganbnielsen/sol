---
id: FEAT-125
type: feature
severity: medium
title: "@sol-fab/obs's Loki facade does not match Sol_obs on stream labels or delivery"
source: internal/pipeline/audits/2026-10-02_cross_language_contract_audit.md
---

**Depends on:** None.

**Related (not dependencies):** FEAT-099 (the console-copy half of the same
`makeLokiPusher` divergence), OBS-048 (the OCaml async-export and flush contract
this mirrors), DEC-022, FEAT-080 (the capability matrix).

## Problem

`Sol_obs`'s Loki facade and `@sol-fab/obs`'s `makeLokiPusher` differ
behaviourally in two ways beyond the console copy FEAT-099 covers. Both are
observed at `sol-obs@13128e6` (`origin/main`, `src/loki.ts:16-48`) against
`framework/ocaml/sol-obs/sol-obs.md:77-85`.

1. **Stream labels.** `Sol_obs.of_env ?context` promotes every context key
   (team/domain/env) to a Loki **stream label**, so a log stream is scoped by
   the workspace's identity labels. `makeLokiPusher` hard-codes
   `stream: { service }`, so an OCaml workload and a TypeScript workload in the
   same workspace produce differently-labelled streams: a label-scoped Grafana
   dashboard or alert matches only one language's lines, exactly the failure mode
   FEAT-080's reconciliation was written to prevent for metrics.
2. **Delivery.** OCaml (OBS-048 part B) exports asynchronously on the switch and
   calls `flush` when `run` returns, so a slow or unreachable Loki never blocks a
   log call and lines queued at shutdown are sent at a defined point. TypeScript
   issues one fire-and-forget `fetch` per line with no flush, so lines still in
   flight when the process exits are lost. The same gap FEAT-099 names on the
   console side applies on the delivery side: with `LOKI_URL` set, a line can be
   neither on stdout (FEAT-099) nor in Loki (this ticket).

## Remediation

In `loganbnielsen/sol-obs`:

- Let `makeLokiPusher` (or a `ofEnv`-shaped composition over it) accept
  low-cardinality context labels and carry them as Loki stream labels, matching
  `Sol_obs.of_env ?context`. Keep the label set fixed at construction, as Loki
  requires and as the OCaml side already does.
- Add a test asserting the pushed stream carries the context labels, not only
  `service`.
- Decide with FEAT-099 whether console copying and the delivery/flush contract
  land in one change: they are the same function and the same failure mode.

## Acceptance criteria

- Two workloads (one OCaml, one TypeScript) given the same context produce log
  streams carrying the same label set, not `service` alone.
- A log line emitted just before a TypeScript service's `runService`/
  `runWorker` drain resolves is delivered (or the flush point that bounds this
  is named and tested), rather than dropped with the process.
- The `@sol-fab/obs` README states the label and delivery contract it
  implements.

**Demo/example coverage:** `examples/pluto/app/demo_ts` uses `makeLokiPusher`;
bump the `@sol-fab/obs` pin and show the labelled stream once the package is
released.

**Language parity:** this ticket *is* the parity fix for the logging convention.
