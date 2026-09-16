---
id: FEAT-087
type: feature
severity: medium
source: FEAT-086 completion notes — CI coverage gap discussion, 2026-09-16
---

**Depends on:** FEAT-086 (done — `examples/pluto/app/demo_ts` consumes the published `@sol-fab/svc`/`@sol-fab/worker`, real golden path verified manually).

Add a real TypeScript golden-path-smoke CI job in the `sol` repo — a deploy-and-verify job for `demo_ts`, structurally parallel to the existing OCaml `golden-path-smoke`, so TypeScript (a first-class Sol application language, DEC-022) has *automated* end-to-end coverage instead of only build/typecheck.

## The gap, precisely

Checked the actual jobs in `.github/workflows/ci.yml` (not assumed):

- `golden-path-smoke` (OCaml): real `sol new` scaffold, real k3d deploy, live health/curl checks. ~14–17 min, not a required check, fail-closed on classifier failure.
- `ts-tests` ("TypeScript demo"): `npm ci` + `npm run build` — typecheck only, no deploy.
- `demo-ts-dockerfile-smoke`: `docker build`, no push, no cluster, no traffic.

**Nothing in CI today deploys a TS unit to a cluster or sends it a request.** Every runtime verification of `demo_ts` to date (FEAT-082's walk, FEAT-086's re-verification) was a manual local run. This ticket automates that.

## Remediation — scope, deliberately narrow

A single new job, e.g. `golden-path-smoke-ts`, added to `sol`'s `.github/workflows/ci.yml`, gated by the same classifier condition (`needs.classify.outputs.kind != 'docs-only'`) as the other non-required smoke jobs — **not a required status check**, matching `golden-path-smoke`'s own precedent, until it's proven stable.

**In scope** — the representative platform contract, not FEAT-082's exhaustive lifecycle experiments:

```text
sol up --scope=demo_ts (real k3d deploy, both units)
  → both pods Running/Ready, 0 restarts
  → GET /healthz → 200
  → one representative transaction: POST /orders → Kafka → worker → Postgres row
  → clean teardown (sol local infra down or equivalent, so the job doesn't leak state)
```

Optionally, if cheap and stable to add: one ordinary graceful-termination assertion (delete a pod, confirm a clean replacement with 0 restarts) — a coarse liveness check, not a reproduction of FEAT-082's forced-shutdown/redelivery/retry-exhaustion experiments. Those stay owned by FEAT-082's manual record and any future *focused* lifecycle tests, not by this golden path. A golden path proves the platform contract end to end; it does not need to be the full experimental suite.

**Out of scope for this ticket:**
- Language-aware CI classification (skip OCaml checks on a TS-only PR, etc.) — a separate, harder problem gated on both golden paths existing first. Do not conflate the two.
- Any change to `sol-typescript`'s own CI.
- Reproducing every FEAT-082 lifecycle experiment (retry/DLQ exhaustion, SIGTERM-mid-flight ordering) as automated CI — those are findings on record, not this job's job.

## Cross-repo version boundary (the part to get right)

`sol` and `sol-typescript` are independent repos (DEC-023/024/025 workspace-independence principle: a workspace must not depend on the checkout/repository that created it). This job must not violate that by checking out or building from `sol-typescript`'s source.

**Design:** `sol`'s CI never touches the `sol-typescript` repository. `examples/pluto/app/demo_ts` already lives inside `sol` and already declares `@sol-fab/svc`/`@sol-fab/worker` as ordinary npm dependencies, pinned in its own committed `package-lock.json` (FEAT-086). The new job does exactly what an external developer would: `npm ci` inside `demo_ts`, resolving `@sol-fab/*` from the public npm registry at whatever version the lockfile pins — nothing more.

```text
sol-typescript CI (unchanged by this ticket)
  → unit tests only (already exists)
  → proves @sol-fab/svc, @sol-fab/worker are correct in isolation
  → no dependency on sol's platform/CLI/infra

sol CI (this ticket)
  → deploys demo_ts, which pins a specific @sol-fab/* version in its own lockfile
  → resolves that version from the npm registry, same as any real user
  → proves the *platform* (sol CLI, k3d manifests, workspace machinery)
    correctly deploys and runs whatever @sol-fab/* version is currently pinned
```

**Bumping the pinned version is an ordinary PR in `sol`** (update `demo_ts`'s `package.json`/`package-lock.json`, exactly like FEAT-086 did going from nothing to `^0.1.0`) — explicit and reviewable, never an automatic cross-repo pull. This mirrors the existing OCaml precedent exactly: `golden-path-smoke` doesn't build the `*-eio` packages from their sibling source checkouts either — it consumes whatever version `sol.opam`/`dune-project` currently pins via opam, and bumping that pin is its own visible commit.

`sol-typescript` does **not** get a golden-path job of its own in this ticket. Precedent: `sol-kafka`/`sol-obs` don't have platform-deploy golden paths either — their CI proves their own correctness (including real-Redpanda-backed tests where relevant), and `sol`'s golden path is where "does this actually work as a deployed Sol workspace" gets proven. Keeping that asymmetry deliberate avoids `sol-typescript`'s CI needing any Sol platform/CLI dependency at all.

## Non-goals

- Not the language-aware classifier (`docs-only`/`ocaml`/`typescript`/`platform`) — a real, valuable follow-up, explicitly deferred until both golden paths exist and are stable. Track separately.
- Not a `sol-typescript`-side golden path.
- Not reproducing FEAT-082's full experimental lifecycle suite as automation.

## Acceptance criteria

- A new CI job deploys `demo_ts` to a real k3d cluster and asserts pod health, `/healthz`, and one real transaction through Postgres.
- The job resolves `@sol-fab/*` from npm via `demo_ts`'s own lockfile — no checkout, build, or reference to `loganbnielsen/sol-typescript`.
- Not a required status check initially (matches `golden-path-smoke`'s own bring-up precedent).
- A real CI run (not just local reproduction) demonstrates the job passing.

## Demo/example coverage

N/A — this ticket adds CI coverage for an existing example (`demo_ts`); it does not change the example itself.

## TypeScript-parity note (DEC-022)

This directly closes a parity gap: OCaml has automated golden-path coverage, TypeScript didn't. No new capability is introduced to the framework itself.
