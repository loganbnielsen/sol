---
id: FEAT-095
type: feature
severity: medium
source: internal/pipeline/tickets/DONE/OBS-047.md
---

(WITHDRAWN) TypeScript workers export the `dead_letter` and `relay_failed` statuses the starter alerts read

**Depends on:** None.

Related (not a dependency): OBS-047, which added the alerts.

## Withdrawn (2026-10-02)

The premise no longer holds. FEAT-113 removed `Dead_letter` and the retry relay
from the OCaml worker: `framework/ocaml/sol-worker/lib/worker.ml` emits exactly
`ok`/`fail`/`ack_failed`, and OBS-047's `SolWorkerRelayPublishFailed`/
`SolWorkerDeadLetterInflow` alerts no longer exist (`rg -n
'dead_letter|relay_failed' platform/ docs/ cli/` matches nothing). There is no
OCaml status for a TypeScript worker to match, so this ticket's remediation is
moot. The TypeScript side's real obligation is the `Ack | Fail` alignment in
FEAT-118, and the `@sol-fab/obs` vocabulary comment this ticket wanted updated is
named in FEAT-118's scope. Withdrawn by the cross-language contract audit
(`2026-10-02_cross_language_contract_audit.md` § 6).

## Problem (historical — premised on a contract OCaml no longer has)

OBS-047's `SolWorkerRelayPublishFailed` and `SolWorkerDeadLetterInflow` read
`sol_worker_messages_total{status="relay_failed"|"dead_letter"}`, which the OCaml
sol-worker emits. The TypeScript worker's status vocabulary is
`{ok, error, retry, ack_failed}` (`examples/pluto/app/demo_ts/fulfillment_worker/src/metrics.ts`,
names from `@sol-fab/obs`). So both alerts are silent for a TypeScript worker, and a
cross-language Grafana panel disagrees between the two runtimes. That is a DEC-022
capability gap: same contract, different signals.

## Original decision question (moot — see Withdrawn)

Does `@sol-fab/worker` / `@sol-fab/kafka` model `Dead_letter` and relay publication the
way sol-worker does (FEAT-078, BUG-029)? If yes, it should emit the same two statuses.
If not, the TypeScript verdict for these two alerts is "not applicable", recorded with
the reason. The work lives in the external `@sol-fab/*` repositories.

## Acceptance criteria

- A TypeScript worker emits `status="dead_letter"` and `status="relay_failed"` with the
  same meaning as sol-worker's (or the verdict is recorded as not applicable, with why).
- The TS demo's `metrics.ts` status comment is updated to match.

## Disposition (2026-10-03) — closed, withdrawn

Withdrawn 2026-10-02: FEAT-113 removed `Dead_letter` and the retry relay from the
OCaml worker, so the status vocabulary this ticket wanted TypeScript to match no
longer exists. The TypeScript obligation is FEAT-118's `Ack | Fail` alignment.
Closed by the pre-alpha BACKLOG adjudication.
