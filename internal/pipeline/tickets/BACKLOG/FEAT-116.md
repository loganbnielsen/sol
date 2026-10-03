---
id: FEAT-116
type: feature
severity: medium
source: BUG-099 (Part B, the event contract)
title: "`sol plan` cannot see contracts that applications declare in code"
---

`sol plan` cannot see contracts that applications declare in code

**Depends on:** None.

## Problem

`sol plan` must show what a deployment will change. Some of what can change is
declared *in application code* rather than in a manifest Sol reads: an event's
partition count and message key now live in the event module's `MESSAGE`
implementation (`partitions`, `key`) because BUG-099 settled that code is the
canonical semantic contract — `key` is executable domain logic, and duplicating
it into TOML would need a synchronisation guard to stay honest.

The CLI's current answer is partial. `Sol_cli_workspace_scan.discover_topics`
reads topic *names* from `events/sol.toml` / `events/<team>/sol.toml`, so the plan
lists topics but can see nothing else about them — and today that list already
disagrees with the code (BUG-107).

This is a general problem, not a Kafka one: as applications express more of their
contract in code, the plan needs a way to inspect it.

## Decision Required

How does `sol plan` inspect a contract that an application declares in code?

Open, with no option preferred yet:

- a build-time metadata artifact the application emits, which the plan reads;
- an `sol inspect …`-style command that reports the contract from a built
  application, which the plan consumes;
- generating manifest metadata from code;
- extending the workspace manifest, plus a guard that it agrees with the code.

Writing the contract into `events/<team>/sol.toml` is **not** implied by this
ticket. BUG-099 rejected exactly that shape: it duplicates executable semantics
and needs a guard to keep them consistent. Any accepted option must leave code the
single source for `partitions` and `key`.

## Acceptance criteria

- The chosen mechanism is recorded as a decision, with the alternatives and why
  they were rejected.
- `sol plan` shows a declared event's partition count and key, and names a change
  to either against what is deployed.
- The TypeScript golden path is covered: the same mechanism reports a TS
  application's event contract, or the decision records the deferral and its
  trigger (DEC-022).

## Disposition (2026-10-03) — decision required

Smallest decision: choose the mechanism by which `sol plan` inspects code-declared contracts — build-time metadata artifact, `sol inspect`-style command, generated manifest metadata, or manifest + drift guard. Consequence: each changes where the canonical `partitions`/`key` live and how the TS golden path exposes them (DEC-022); writing them into TOML is already rejected by BUG-099.

Surfaced to the operator as a category-5 decision; not deferred. Moves to
`READY_FOR_ENGINEERING/` once the decision is recorded. See
`internal/pipeline/audits/2026-10-03_backlog_adjudication.md`.
