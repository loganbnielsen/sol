---
id: REFAC-067
type: refactor
severity: high
source: cross-cutting-design-review 2026-08-31
branch: REFAC-067/internal-api-seams
---

Hide route matching internals from `sun-svc` public surface

**Depends on:** REFAC-066.

## Problem

`sun-svc` exposes `Route.match_path` and `Route.method_of_http` even though
only `Service.Make` should call them. Tests also call those helpers directly,
which turns implementation details into user-facing API.

## Goal

Keep `Route` as the public route-construction API and move matching/adaptation
logic behind a private implementation module.

## Acceptance criteria

- `Route.match_path` and `Route.method_of_http` are removed from `route.mli`.
- `Service.Make` still uses the same production matching logic.
- `route_internal` is a private module.
- Service/routing tests pass through public route construction and service
  behavior.
- No wrapped-facade rewrite for the `*-eio` packages.
