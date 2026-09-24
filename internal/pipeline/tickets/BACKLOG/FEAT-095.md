---
id: FEAT-095
type: feature
severity: medium
source: internal/pipeline/tickets/DONE/OBS-047.md
---

TypeScript workers export the `dead_letter` and `relay_failed` statuses the starter alerts read

**Depends on:** None.

Related (not a dependency): OBS-047, which added the alerts.

## Problem

OBS-047's `SolWorkerRelayPublishFailed` and `SolWorkerDeadLetterInflow` read
`sol_worker_messages_total{status="relay_failed"|"dead_letter"}`, which the OCaml
sol-worker emits. The TypeScript worker's status vocabulary is
`{ok, error, retry, ack_failed}` (`examples/pluto/app/demo_ts/fulfillment_worker/src/metrics.ts`,
names from `@sol-fab/obs`). So both alerts are silent for a TypeScript worker, and a
cross-language Grafana panel disagrees between the two runtimes. That is a DEC-022
capability gap: same contract, different signals.

## Decision Required

Does `@sol-fab/worker` / `@sol-fab/kafka` model `Dead_letter` and relay publication the
way sol-worker does (FEAT-078, BUG-029)? If yes, it should emit the same two statuses.
If not, the TypeScript verdict for these two alerts is "not applicable", recorded with
the reason. The work lives in the external `@sol-fab/*` repositories.

## Acceptance criteria

- A TypeScript worker emits `status="dead_letter"` and `status="relay_failed"` with the
  same meaning as sol-worker's (or the verdict is recorded as not applicable, with why).
- The TS demo's `metrics.ts` status comment is updated to match.
