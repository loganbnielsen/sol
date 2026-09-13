---
id: REFAC-089
type: refactor
severity: low
source: FEAT-063 review 2026-09-13 — adding the destination threading pushed several already-flat interfaces past the point where the missing domain groupings became obvious
---

**Depends on:** FEAT-063.

**Related:** REFAC-088 (the capability-core split), `Sol_cli_command_request` (the pattern this extends), FEAT-061 (scope), DEC-016/DEC-020.

FEAT-063 did not create the argument-list problem; it crossed a threshold where interfaces that were already flat became hard to read. Group the inputs that genuinely belong together — and only those.

## The distinction

Not every long argument list is a smell. Two different things look alike:

- **Independent knobs** — a labelled OCaml signature with 5–6 of them is fine. Turning those into a record just hides the same complexity behind a constructor.
- **A concept that has already emerged** — several arguments that (a) travel together, (b) are repeatedly pulled from the same source, and (c) mean one thing together. Those want a named type.

Rule of thumb for this codebase: **4+ arguments that routinely travel together and are pulled from the same source probably want a named type.**

## Findings (from the FEAT-063 diff)

| Function | Read |
| --- | --- |
| `cmd_deploy.run_plan` | **Refactor.** It unpacks `deploy_context` only to repack the same conceptual operation across 8 labelled arguments. It should consume the record it came from. |
| `Sol_cli_executor.run_plan` | **Leave.** `ctx`/`workspace`/`env`/`mode`/`secret_backend`/`plan` have six distinct meanings and are cohesive. |
| `Sol_cli_factory.execute` | **Leave** (~5 meaningful inputs). |
| `Sol_cli_factory.run` | **Group.** `~workspace ~env ?env_label ?requested_scope ?resolved_config` are pieces of a deployment identity that already exists conceptually; split into something like a target value (`kube_ctx`, `env`, `env_label`) and a request value (`workspace`, `requested_scope`, `resolved_config`). |
| `cmd_logs.run` + its Cmdliner lambda | **Group.** Nine-plus values for scope/follow/tail/observability config. `observability_options` and `log_options` records make this readable and let the flag set evolve without touching the signature. |
| `cmd_status.run` | **Same as logs** — the observability configuration should be one value, not five arguments. |
| Cmdliner lambdas generally | Long lambdas are the symptom of parsing into primitives instead of into a typed request. |

## Scope

1. `cmd_deploy.run_plan` takes the deployment context; the body keeps its current calls.
2. `Sol_cli_factory.run` groups its inputs into 2–3 cohesive values.
3. `cmd_logs` / `cmd_status` gain `observability_options` (and `log_options` for logs), and their `run` signatures and Cmdliner lambdas collapse to `run ~ctx options`.
4. **Extend `Sol_cli_command_request` rather than inventing a generic runtime record.** That module is already the right shape — a typed command request built at the CLI edge and handed to command logic. This refactor is more of it, not a new abstraction.
5. Do **not** create wrapper records for functions whose arguments are genuinely independent (see `Sol_cli_executor.run_plan`): a record that only reduces a visible count is a loss.

## Acceptance criteria

- `cmd_deploy.run_plan` consumes `deploy_context` instead of re-listing its fields.
- `cmd_logs.run` / `cmd_status.run` take a small, typed set of option values; the Cmdliner lambdas build those values rather than calling `run` with nine primitives.
- `Sol_cli_executor.run_plan` is unchanged (documented here as deliberately not grouped, so a later reader does not "fix" it).
- No behaviour change: the golden path and the unit suite stay green.

## Notes

This is deliberately *not* a generic "options record" sweep. The point is to name the concepts that have already emerged, and to leave the genuinely flat interfaces flat.
