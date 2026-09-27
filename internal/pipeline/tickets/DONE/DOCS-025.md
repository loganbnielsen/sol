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

## Completion notes

**Premise verified (2026-09-27, `origin/main` `10267ca6`).** The bullet was stale:
`sol_cli_deployment_render.ml` picks the readiness path from the declared
language, `sol_cli_manifest_yaml.probes` puts startup and liveness on `/healthz`
for an HTTP service, and the section's other rows already stated their paths. The
rest of the document — the `single`/`node-failure-tolerant` matrix, the three
`validate_availability` rejections, the headroom preflight, the worker's
consumer-join and poll-cadence reasoning — matched the code and is unchanged.

**What landed.** The HTTP-service bullet now names the paths per language:
startup and liveness on `/healthz:8080`; readiness on `/readyz:8080` for a
declared OCaml `-svc` (INFRA-073); `/healthz:8080` for a TypeScript or
undeclared workload until the TypeScript framework serves `/readyz` (FEAT-096),
with the reminder that an undeclared language is unknown rather than OCaml
(DEC-022 §7), and that both deployment modes resolve it identically (BUG-056).

**Also in this PR.** `AGENTS.md`'s comment policy now says what is not yet
enforced: dune files and Dockerfiles are covered by the policy (REFAC-143) but
are not in `check_no_comments.sh`'s file list, and extending it belongs with the
CI and tooling work that owns `internal/ci/**`. That gap was the one follow-up
from REFAC-143 that could not be closed here without crossing that ownership, and
leaving it unsaid would let a reader assume the guard already holds them.

**Verification.** Documentation only: every path in the section was checked
against `sol_cli_manifest_yaml.probes` (`/healthz` startup and liveness for an
HTTP service, `/readyz`/`/livez` on 9090 for a consumer worker) and against the
renderer's `readiness_path` for each language. The `internal/ci/check_*.sh`
suite passes in this worktree once the tree is built (the provider-roots guard
reads the provider list through the CLI binary, so it fails in a fresh worktree
before `dune build` — nothing to do with this change). `pipeline validate`
passes.

**Demo/example: not applicable** — no artifact, scaffold or instruction changed.
**Language parity: no impact on code**; the section now states the per-language
verdict it was missing, which is the convention DEC-022 asks for.

## Resolved: the blocker was BUG-064, and the run now proves the composition

This PR was the case that exposed the docs-only composition defect: the required
`test` check skipped the product build and the ticket-validation guard, which runs
unconditionally by design, failed with "soldev is not built". BUG-064 fixed that
by giving the unconditional guards their tooling without the conditional build.

Re-run on this branch after BUG-064 landed (`test` job, run `36353084946`):

```text
  3  Install the CI guards' tooling: success
  4  Docs-only change -- full suite deliberately not run: success
 11  Build: skipped                                   ← the product build, still conditional
 12  Tooling for the unconditional guards (BUG-064): success
 13  Install pinned kubectl (readiness-probe argument validation): success
 32  Pipeline ticket validation guard (BUG-060): success   ← previously the failure
 33  Unconditional guards can run (BUG-064): success       ← the composition, asserted in CI
```

The merge also took main's `AGENTS.md` comment-policy text and dropped this
branch's clause recording the enforcement gap: `check_no_comments.sh` now covers
dune files and Dockerfiles too, so the gap that clause described no longer exists.

