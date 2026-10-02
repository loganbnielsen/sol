---
id: FEAT-099
type: feature
severity: low
source: internal/pipeline/tickets/READY_FOR_ENGINEERING/OBS-048.md
---

TypeScript: `@sol-fab/obs` keeps a console copy of log lines when `LOKI_URL` is set, matching `Sol_obs`

**Depends on:** None.

**Language-parity tracking for:** OBS-048 part A (DEC-022 capability matrix: logging).

## Problem

OBS-048 part A made `Sol_obs` write every log line to stdout as well as to Loki, so
`kubectl logs` has them and a Loki outage does not lose them. `@sol-fab/obs`'s
`makeLokiPusher` (github.com/loganbnielsen/sol-obs, `src/loki.ts:16-44`, read
2026-09-24) writes to the console only when `LOKI_URL` is unset. With it set, the line
goes only to a fire-and-forget `fetch`, and a failed push logs the error without the
line.

## Remediation

In `makeLokiPusher`, `console.log` the structured line in both branches. Bump the
dependency in `examples/pluto/app/demo_ts`.

## Acceptance criteria

- Unit test in sol-obs: with a Loki URL set, the line is written to the console and
  pushed.

## Done (2026-10-02)

**Premise checked.** Confirmed at `sol-obs@13128e6`: `makeLokiPusher`
(`src/loki.ts:16-48`) wrote to the console only in the `!lokiUrl` branch; with a
URL set the line went only to a fire-and-forget `fetch`. Premise held.

**What landed.** `loganbnielsen/sol-obs#3` (merged `9c572ff`) extracts
`writeConsoleLine` and calls it in **both** branches, so the structured JSON line
is on stdout whether or not `LOKI_URL` is set — matching `Sol_obs` (OBS-048 part
A). Released as `@sol-fab/obs@0.1.2` (tag `v0.1.2`). The `demo_ts` pins move to
`^0.1.2` and the lockfile is regenerated; no demo code change was needed, since
the console copy is internal to the helper.

**Checks run.** `sol-obs`: `npm run build` (`tsc`) clean; `npm test` → 13 tests,
0 fail, with the Loki test now asserting the console copy as well as the push
(it failed before the change because no line reached the console). Demo:
`npm run build -w order-svc -w fulfillment-worker` clean against the published
`0.1.2`.

**Demo/example coverage.** The `demo_ts` dependency bump is the example half;
the demo uses `makeLokiPusher` unchanged.

**Language parity.** FEAT-099 is the console-copy half of the logging gap. The
labels-and-delivery half (fixed Loki stream labels from context, and a `flush`
point) is recorded with its decision in FEAT-125 and remains in BACKLOG, so this
ticket does not claim the whole logging contract is aligned.

