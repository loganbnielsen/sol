---
id: DOCS-025
type: docs-finding
severity: low
title: workload-availability documents an HTTP service's readiness as /healthz, which a declared OCaml -svc no longer is
source: found while landing REFAC-143 (2026-09-27), reading the probe section against the renderer
---

**Depends on:** None.

## The defect

`docs/deployment/workload-availability.md`'s probe section tells a reader that an
HTTP service is probed on `/healthz` for readiness, liveness and startup:

```markdown
- **HTTP service** — `startupProbe` and readiness/liveness on `/healthz:8080`.
```

That was true before INFRA-073. The renderer puts readiness on the path the
workload's declared language serves:

```ocaml
(* cli/lib/deploy/sol_cli_deployment_render.ml *)
| Some Sol_cli_compat.Ocaml -> "/readyz"
| Some Sol_cli_compat.Typescript | None -> "/healthz"
```

so a declared OCaml `-svc` gets `readinessProbe` on `/readyz:8080` while startup
and liveness stay on `/healthz:8080`, and a TypeScript (or undeclared) service
keeps `/healthz` for readiness until the TypeScript framework serves `/readyz`
(FEAT-096). The same file's worker bullet already states its readiness/liveness
paths, and the section's point — "the raw controls are never the application
contract" — is weakened when one of its rows is wrong.

The doc is otherwise accurate: the availability matrix, the `validate_availability`
rejections, the headroom declaration and the worker's consumer-join/poll-cadence
explanation all match the code.

## Remediation

State both cases in the HTTP-service bullet: readiness on `/readyz:8080` when the
workload declares OCaml (INFRA-073), and `/healthz:8080` for a TypeScript or
undeclared workload (FEAT-096 tracks the TypeScript side), with startup and
liveness on `/healthz:8080` either way. An undeclared language is unknown, never
assumed OCaml (DEC-022 §7), and both deployment modes resolve this identically
since BUG-056.

## Acceptance criteria

- Every probe path the section names matches `sol_cli_manifest_yaml.probes` and
  the renderer's `readiness_path` for each language.
- No claim about the availability matrix, headroom or the worker changes.
- Demo/example: not applicable (documentation only; no artifact or instruction
  changes). Language parity: the section now states the per-language verdict,
  which is exactly the parity convention it was missing.
