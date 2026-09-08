# OCaml Style Audit: Type Safety, Readability, and API Design

This audit finds refactoring opportunities where the code relies on caller
memory, raw strings, runtime validation, or deeply nested control flow instead
of using OCaml's type system and local readability.

The output is a set of actionable tickets in
`project/tickets/READY_FOR_ENGINEERING/`.

## Audit Principles

### 1. Eliminate Boolean Traps and Positional Debt

Flag APIs where a caller can pass the right type in the wrong position.

Look for:

- Functions with multiple positional arguments of the same primitive type.
- Functions with more than 3 positional arguments.
- Functions with more than 3 labeled arguments that still feel cumbersome or
  expose too many implementation details.
- Back-to-back `bool`, `string`, `int`, or `float` arguments.
- Public `.mli` signatures with repeated unlabeled `string -> string -> ...`.
- Optional arguments without a trailing `unit` when execution timing may be
  ambiguous.
- Records or helpers that require callers to coordinate several independent
  booleans.

Preferred fixes:

- Convert to labeled arguments.
- Replace boolean pairs with variants.
- Replace long argument lists with records or mode-specific variants.
- Split functions by phase when arguments belong to different steps such as
  parse, validate, plan, render, and execute.
- Add trailing `()` to functions with optional labeled arguments.

#### Labels vs Records vs Variants vs Smaller Functions

Labels are a readability tool, not a universal abstraction. A function with
eight labeled arguments is less ambiguous than eight positional arguments, but it
may still expose too much surface area to callers.

Use this decision guide:

- Use labeled arguments when the function has a small number of independent
  inputs and the call site remains compact.
- Use a record when the fields form a real domain concept: config, request,
  render spec, deployment target, route, credential set, or environment.
- Use variants when only some fields are valid in some modes. Avoid records with
  many optional fields plus a tag when each mode has different requirements.
- Split the function when groups of parameters belong to different phases. For
  example, parse external strings into a typed request, validate it, build a
  plan, render artifacts, then execute side effects.

Passing records is idiomatic OCaml when the record represents a meaningful
domain value or configuration. Avoid vague "dependencies" records created only
to hide a messy signature; prefer a named concept with invariants.

Ticket examples:

- A manifest renderer with `~namespace ~name ~image ~replicas ~cpu ~memory
  ~ports ~probes ...` likely wants a typed render spec or workload variant.
- An HTTP helper with `~meth ~path ~content_type_opt ~body_opt` likely wants a
  request variant so body/content-type mismatches are unrepresentable.
- A CLI `run` entrypoint may keep labeled Cmdliner inputs, but should usually
  construct a typed command request before doing domain work.

### 2. Eradicate Stringly-Typed Finite Domains

Flag raw strings used for fixed domain values.

Look for:

- `match value with | "active" -> ...` style parsing.
- Record fields named `type`, `status`, `mode`, `state`, `role`,
  `environment`, `kind`, `backend`, `strategy`, `provider`, or `target` typed
  as `string`.
- Repeated literals for the same domain across modules.
- Unknown input silently defaulting to a valid mode.
- Identifier aliases such as `type account_id = string` where distinct domains
  can be swapped.

Preferred fixes:

- Introduce variants for closed sets.
- Introduce private/refined wrapper types for validated identifiers.
- Keep parse/string conversion at IO boundaries.
- Return `Result` for unknown external strings instead of defaulting.

### 3. Flatten Option and Result Pyramids

Flag sequential fallible logic hidden inside nested matches.

Look for:

- `match` inside `match` inside `match` over `Some`/`None` or `Ok`/`Error`.
- Manual accumulator folds that repeatedly match `acc`.
- Repeated decode pipelines: parse JSON, extract fields, validate, dispatch.
- Side effects mixed into decode/validation branches.

Preferred fixes:

- Use `Result.bind`, `Option.bind`, `Option.to_result`, or local `let*`.
- Extract small helpers for one fallible operation each.
- Keep side effects at the edge after typed decisions are made.

## Manual Audit Requirement

Do not rely on grep alone. Grep is useful for seeding candidates, but every
ticket must be based on reading the surrounding file or module.

For each folder, manually inspect:

- Public `.mli` signatures before implementation details.
- Record types and variant boundaries.
- Constructors and parsing functions.
- Long labeled function signatures to decide whether labels are sufficient or a
  higher-level abstraction is missing.
- Call sites that reveal whether an API is easy to misuse.
- Tests/templates/examples that teach future users a pattern.

## Suggested Folder Walk

Cover the repository by ownership area:

- `framework/` - public primitives and generated app lifecycle patterns.
- `framework/kafka-eio-service/` - FFI boundaries, producer/consumer/service APIs,
  schema registry, retry and decode paths.
- `cli/sun/lib/` - deployment planning, rendering, state, hosted model, secrets.
- `cli/sun/bin/` - Cmdliner terms, command entrypoint shapes, string parsing.
- `examples/` - user-facing patterns and generated-code quality.
- `tools/` - workflow helpers, process execution, ticket tooling.
- `cli/sun/test/`, `framework/*/test/`, `framework/*/test/` - repeated
  helper patterns and assertions that reveal awkward APIs.

## Multi-Agent Partitioning

When subagents are available, assign one ownership area per agent. Give each
agent:

- The audit principles above.
- Exactly one folder group to inspect.
- Instructions to read files manually, not just grep.
- A ticket output contract with file references and acceptance criteria.

Recommended partitions:

1. `framework/` and generated lifecycle expectations.
2. `framework/kafka-eio-service/`.
3. `cli/sun/lib/`.
4. `cli/sun/bin/`.
5. `examples/` and scaffold templates.
6. `tools/` and test helper patterns.

Merge duplicate findings by refactor boundary, not by individual line. Prefer
one ticket per coherent API refactor.

## Ticket Quality Bar

Create a ticket only when the improvement is actionable now.

Each ticket must include:

- A concrete title.
- File and line references for the current smell.
- Why the current shape is risky or hard to read.
- The desired type-safe/readable shape.
- Acceptance criteria.
- `**Depends on:** none.` unless the work genuinely depends on another ticket.

Use `project/tickets/READY_FOR_ENGINEERING/` for actionable findings.

Use a stable prefix for the run, for example `CODEX_STYLE_AUDIT-NNN` or
`STYLE-NNN`, continuing from the highest existing ID with that prefix.

Ticket template:

```markdown
---
id: CODEX_STYLE_AUDIT-NNN
type: refactor
severity: <high|medium|low>
source: docs/audits/STYLE_AUDIT.md
---

<one-line title>

**Depends on:** none.

**Problem:** <specific file references and explanation>

**Goal:** <target API/design shape>

**Acceptance criteria:**

- <verifiable criterion>
- <verifiable criterion>
```

## Severity Guidance

- `high` - Auth/security behavior, deployment correctness, DB/SQL safety,
  Kafka delivery/ack semantics, FFI boundaries, or APIs likely to cause data
  loss or production incidents.
- `medium` - Public API readability, generated user-facing patterns, repeated
  decode/validation pyramids, invalid state representable in normal usage.
- `low` - Local cleanup that improves clarity but has limited blast radius.

## Anti-Patterns in Audit Execution

Avoid:

- Filing one ticket per grep hit.
- Filing vague "clean this file up" tickets.
- Duplicating existing tickets in any `project/tickets/` state.
- Putting actionable tickets in `BACKLOG/`.
- Auditing only `cli/` because it has many obvious command booleans.
- Ignoring tests/templates/examples; they often define the pattern users copy.
