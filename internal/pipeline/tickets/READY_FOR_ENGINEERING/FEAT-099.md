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
