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

## Directive (2026-09-13)

**This is not a behaviour-preserving cleanup, and it is not required to preserve
the current function signatures.** The widened signatures are *evidence about
missing domain types*, not something to be preserved. Minimise argument
plumbing and make the interfaces say what the concepts are, even where that
means changing callers more broadly than the original scope anticipated.

Preserve the **product semantics**. Do not preserve the internal API shape.

The target shape:

```text
Cmdliner
   │
   ▼
typed command request
   │
   ▼
resolve destination once
   │
   ▼
bound operation context
   │
   ├── destination / cluster capability
   ├── workspace
   └── target / environment
   │
   ▼
factory / executor
```

The key discriminator, and the reason this is not one record: **the environment
an execution happens in is not an instruction for this particular execution.**

```ocaml
type execution_context =
  { cluster : Sol_cli_kube_destination.context  (* where *)
  ; workspace : string                          (* whose *)
  ; env : string option                         (* which environment *)
  }

val run_plan
  :  execution_context
  -> mode:mode                 (* an instruction for this execution *)
  -> ?secret_backend:secret_backend
  -> deployment_plan
  -> (result list, string) result
```

`mode` and `secret_backend` stay outside the context: they are choices made *by*
this execution, not properties of the world it runs in. Flattening them into the
same record would be the same mistake in a new place.

## Scope

1. **Introduce the execution context** (`{ cluster; workspace; env }`) as the
   bound thing the executor and factory take, replacing the `~ctx ~workspace
   ~env` triple they each re-declare.
2. **`Sol_cli_executor.run_plan`** takes the context plus `mode`; `secret_backend`
   remains an optional instruction.
3. **`Sol_cli_factory.run` / `execute`** take the context plus a *request* value
   for the selection/config half (`requested_scope`, `resolved_config`, and the
   resolved target `env_config`), plus `mode` and the services. `env_label`
   belongs with the context (it is what the executed objects are labelled with),
   not with the request.
4. **`cmd_deploy`**: `deploy_context` should collapse toward the execution
   context plus the deploy-specific extras, rather than carrying both spellings
   of the same facts (`kube_ctx` *and* `workspace` *and* `target_cfg`).
5. **`cmd_logs` / `cmd_status`** take option records built at the CLI edge
   (done in this pass) — `observability_options` is a real concept: where to read
   telemetry, and with what credentials.
6. **Do not** create a wrapper record merely to reduce a visible argument count
   where the inputs are genuinely independent.

## Acceptance criteria

- `cmd_deploy.run_plan` consumes `deploy_context` instead of re-listing its fields.
- `cmd_logs.run` / `cmd_status.run` take a small, typed set of option values; the Cmdliner lambdas build those values rather than calling `run` with nine primitives.
- `Sol_cli_executor.run_plan` is unchanged (documented here as deliberately not grouped, so a later reader does not "fix" it).
- No behaviour change: the golden path and the unit suite stay green.

## Notes

This is deliberately *not* a generic "options record" sweep. The point is to name the concepts that have already emerged, and to leave the genuinely flat interfaces flat.

## Completion notes

Landed 2026-09-13, under the directive above: **behaviour was preserved, the API
shape was not.**

**The execution environment is now a value.** `Sol_cli_execution.context` is
`{ cluster; workspace; env }` — *where*, *whose*, *which environment* — bound at
the command boundary and carried down as one thing. `Sol_cli_executor.run_plan`
and `Sol_cli_factory.execute` take it directly instead of re-declaring the
`~ctx ~workspace ?env` triple apiece.

**`mode` and `secret_backend` stayed outside it.** This is the discriminator the
directive names: they are instructions for *this* execution, not properties of
the world it runs in. Folding them in would have been the same flattening mistake
in a new place, so `run_plan` reads:

```ocaml
val run_plan
  :  Sol_cli_execution.context
  -> mode:mode
  -> ?secret_backend:secret_backend
  -> Sol_cli_deployment_plan.service_spec list
  -> (result list, string) result
```

**`Factory.run` got concepts, not a bucket.** It is now
`run execution ~request ~mode services`, where `request` is the *selection and
configuration* half — `{ env : env_config; requested_scope; resolved_config }` —
genuinely distinct from the execution environment. `env_label` moved into the
context (it is what the executed objects are labelled with). The trailing `()`
disappeared with the optional-argument ambiguity that required it.

**`cmd_deploy` stopped spelling the same facts twice.** `deploy_context` carried
`kube_ctx` *and* `workspace` *and* re-derived the env label; it now carries one
`execution` field, and the `execution_of` adapter that existed only to bridge the
two spellings is gone.

**`cmd_logs` / `cmd_status` take option records built at the CLI edge.**
`observability_options` (`backend`, `base_domain`, `grafana_base_url`,
`loki_base_url`, `loki_username`, `loki_password`) is a real concept — where to
read telemetry, and with what credentials — and was six labelled arguments on
every telemetry-touching command. `log_options` / `status_options` wrap it with
the selection. The two entry points now differ in exactly two ways: how they
produce the destination, and whether `--target` is declared at all (the local
form declares `Term.const None`, so `sol local logs` no longer advertises a
`--target` it ignores).

**Deliberately not grouped**, so a later reader does not "fix" them:

- `Sol_cli_executor.run_plan` — after the change its inputs are the context, two
  instructions, and the payload. That is small and cohesive; the widened
  signature the ticket complained about was the *old* shape.
- `Sol_cli_factory.plan_of_services` — a planning function's inputs
  (workspace, resolved `env_config`, scope/config) are distinct facts, and it is
  internal to the factory now that `run` composes it.

**Note on a lint:** `sol status` and `sol local status` are two Cmdliner
definitions over one core, which is the shape REFAC-088 pinned. This ticket did
not change that relationship; it changed what the core takes.

**Verification.** `dune build`, `dune fmt`, `cli/sol/test` and the whole
`dune test` are green. The golden-path CI job exercises `sol up`, `sol deploy`
and `sol local releases` end to end and is the live check.
