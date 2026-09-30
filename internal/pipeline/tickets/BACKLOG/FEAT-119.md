---
id: FEAT-119
type: feature
severity: medium
title: Project and reconcile the Sol event contract from @sol-fab/kafka
source: "BUG-105 (schema registration is a deployment step); DEC-022 TypeScript-parity tracking"
---

**Depends on:** None.

**Related:** BUG-105 (the OCaml mechanism this mirrors), FEAT-118 (the retry/DLQ alignment), FEAT-080 (the capability matrix), DEC-022.

## Problem

BUG-105 moved schema registration out of the runtime and into the deployment lifecycle for OCaml applications. A workspace generates `contract/contract.exe`, which projects each event module's contract metadata as a language-neutral JSON object (`--json`) and validates and registers it against the target registry (`--check` / `--apply`). `sol up` runs the reconciliation locally; `sol deploy` runs it inside the destination on the deployment's own image; producer and consumer runtimes are read-only against the registry.

The published TypeScript packages still register schemas at runtime. `@sol-fab/kafka` writes to the schema registry when a producer or consumer starts, so a TypeScript application both retains the defect BUG-105 removed for OCaml and cannot participate in Sol's contract reconciliation — it has no projection for `sol plan` to inspect or `sol deploy` to reconcile.

Per DEC-022, parity is capability and behavioural, not implementation: a TypeScript application must expose the same contract — a projection of the same shape, produced from the same single source of truth (the message's schema declaration), consumed by the same deployment stages — while keeping the Node ecosystem underneath.

## Remediation

The `@sol-fab` packages live in their own repositories, outside this one. Bring them to the BUG-105 contract:

- Remove runtime registry mutation from `@sol-fab/kafka`: producer and consumer startup must read the registry only, and fail with a clear error when the contract is not registered.
- Expose the application's compiled event-contract metadata as the same language-neutral projection object BUG-105 defines (`{"version":1,"events":[{"module","topic","partitions","schema"}]}`), emitted by a generated entry point rather than hand-maintained.
- Accept a reconciliation mode equivalent to `--apply` (validate compatibility, then register) and a read-only check equivalent to `--check`, so Sol's deployment stages can drive it without change.
- Update `examples/pluto/app/demo_ts` to the projection, and refresh the per-capability verdicts in `internal/pipeline/dogfood/2026-09-07_typescript_demo_spike.md` (FEAT-080).

## Acceptance criteria

- `@sol-fab/kafka` never writes to the schema registry from a producer or consumer at runtime; an unregistered contract fails at startup.
- A TypeScript workspace can emit BUG-105's projection object, and `--check` / `--apply` behave as the OCaml projection does (idempotent apply, `FULL` compatibility set before registering).
- The projection is produced from a single declared source of truth, with no schema duplicated into `sol.toml` or another manifest.
- `examples/pluto/app/demo_ts` demonstrates the contract and its projection.
- FEAT-080's capability matrix records the aligned verdict.

**Demo/example coverage:** this ticket *is* the TypeScript example update.

## Blocked On

The next `@sol-fab/*` release after BUG-105 lands. Until then Sol's own OCaml framework is the single implementation of the contract, and a TypeScript-only workspace is skipped by the reconciliation stage (it declares no OCaml workload to run it in); the capability matrix records the delta with this ticket as its trigger.
