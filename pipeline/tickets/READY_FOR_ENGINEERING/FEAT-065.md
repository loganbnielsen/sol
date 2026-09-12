---
id: FEAT-065
type: feature
severity: medium
source: split from FEAT-064, 2026-09-11 — the resolver landed; the migration did not
---

**Depends on:** FEAT-064.

**Related:** DEC-018 (rollback), DEC-016, REFAC-086 (local vs target surfaces).

Propagate strict scope selection across the commands that operate on a subset of workloads.

## The invariant

> **Sol has one workload-selection language. Commands may project that selection into their own addressing model, but may not reinterpret it.**

Three consequences, each of which came up as a question during design:

- **Selection is neutral about emptiness.** The resolver answers `Selected of named list | Empty`; whether zero matches is *meaningful* is a command policy — `status` and `check` accept an empty workspace, `up`, `deploy` and `rollback` do not. A mutation that exits 0 having changed nothing is indistinguishable from success to a script, a CI job or a push-triggered deploy.
- **A command receives `--scope` only when every accepted scope projects into that command's addressing model without changing its meaning.** If `payments/settle_worker` resolves as a deployment unit but Loki can only address `payments`, then `logs --scope payments/settle_worker` must not ship implying unit granularity: either write the projection that preserves it, or withhold the flag and say so. `scope resolution != command addressing`, and the projection belongs to the command that needs it, never to the resolver.
- **The plan carries both facts.** The requested scope (`Domain "payments"`) and the concrete resolved set are different information: intent, and reproducibility. A service added to a domain next week does not retroactively change what the boundary of *that* release was, and DEC-018's rollback needs both.

## Scope

**1. Delete `filter_path`.** It is threaded through 18 files — `cmd_deploy` (10 sites), `cmd_secret` (8), `cmd_up` (8), `sol_cli_command_request` (6), `sol_cli_manifest` (9), `sol_cli_check`, `sol_cli_factory`, `cmd_dev`, `cmd_logs`, `cmd_migrate`, `cmd_rollback`, `cmd_status`, `sol_cli_config`, plus test fixtures. `discover_services` should stop accepting a user-supplied string at all.

**2. Do not migrate mechanically — ask what each use *meant*.** For every one of those files the question is:

> Is this genuinely workload selection, or was `filter_path` being reused as a convenient path-or-name filter?

If it is the latter, give that behaviour **its own vocabulary** rather than forcing it through deployment scope. `cmd_secret` is the case to inspect first: secrets being addressable by path or name does not imply that a secret operation consumes a *deployment* scope, and replacing one with the other would smuggle the old abstraction mistake into the new design.

**3. Consumers, named rather than "all commands":**

- `up`, `deploy`, `rollback` — mutating, therefore empty is an error, and the selector binds before anything is applied.
- `status` — currently selects everything unconditionally (`filter_path:None`) and hand-rolls a domain filter; it should use the resolver instead.
- `logs` / `open` — only if the projection into telemetry addressing preserves granularity (see the invariant), otherwise withhold the flag.
- `migrate` — inspect before deciding; its current filter may be a migration-path selector rather than a workload selector.

**4. Resolve once, at the command boundary, and pass the result down.** After resolution, commands take the resolved workloads and never see a selector string again, so no two can disagree about what a name means.

**5. Record the requested scope and the resolved set** in the emitted plan (`--emit-plan-to`).

## Acceptance criteria

- No `filter_path` remains anywhere, and no command accepts a positional workload selector.
- Every command that can meaningfully operate on a subset accepts `--scope` and resolves it through the same function — asserted by a test, not by inspection.
- A bad selector fails before check, deploy or rollback logic runs, so no command can report a downstream cause for it.
- Mutating commands fail on an empty selection; read-only commands report it.
- The emitted plan carries the requested scope and the resolved workloads.
- Where a command's addressing cannot preserve the scope's granularity, the flag is withheld and the reason is recorded in this ticket — not shipped with a narrower meaning than it implies.
- Any `filter_path` use that turns out not to be workload selection is given its own vocabulary, with the reason recorded.
