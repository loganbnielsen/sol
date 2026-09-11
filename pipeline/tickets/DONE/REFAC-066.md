---
id: REFAC-066
type: refactor
severity: high
source: cross-cutting-design-review 2026-08-31
branch: REFAC-066/lifecycle-stop
---

Align lifecycle shutdown across `sun-svc`, `sun-worker`, and `sun-fn`

**Depends on:** None.

## Problem

`sun-worker` accepts an external `?stop:unit Eio.Promise.t`, but `sun-svc` and
`sun-fn` only had internal signal-driven shutdown. That made tests rely on
implicit switch cancellation and left service tests hanging until timeout.

## Goal

Give all three primitives the same external stop shape without introducing a
larger runtime abstraction yet.

## Acceptance criteria

- `Service.Make.run` accepts `?stop:unit Eio.Promise.t`.
- `Fn.Make.run` accepts `?stop:unit Eio.Promise.t`.
- `sun-svc` tests explicitly stop test servers and complete quickly.
- `sun-fn` push failures route through `Obs_eio` instead of raw stderr.
- Focused framework and CLI unit tests pass.
