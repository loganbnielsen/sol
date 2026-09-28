---
name: style-audit
description: Run an OCaml type-safety and readability style audit. Finds boolean traps, positional debt, stringly-typed domains, Result/Option pyramids, unnormalized arguments, hidden conceptual groups, mixed effect boundaries, and embedded phase/state handling across the whole repo. Requires manual folder walks beyond grep and creates actionable tickets.
---

# /style-audit - OCaml Type Safety and API Design Audit

Find refactoring opportunities where Sol code relies on caller memory, raw
strings, defensive runtime checks, or deeply nested control flow instead of
OCaml types and readable pipelines.

Read `internal/pipeline/audits/STYLE_AUDIT.md` in full before starting. Treat it as the
source-of-truth checklist.

## Output

Create actionable tickets in:

```text
internal/pipeline/tickets/READY_FOR_ENGINEERING/
```

Do not put actionable style findings in `BACKLOG/`.

Use prefix `CODEX_STYLE_AUDIT-NNN` unless the user requests another prefix.
Continue from the highest existing `CODEX_STYLE_AUDIT-*` ticket across all
`internal/pipeline/tickets/` subdirectories.

## Core Rule

Do not rely on grep alone.

Use grep/ripgrep to seed candidate locations, then manually read files by
folder. Every ticket must be based on surrounding code context, not just a regex
match.

## Audit Targets

Flag these three categories:

1. Boolean traps and positional debt
   - Multiple positional args of the same primitive type.
   - More than 3 positional args in public or widely used APIs.
   - More than 3 labeled args when the function still feels cumbersome or
     exposes several concepts at once.
   - Paired booleans or boolean flags whose meaning is not clear at call sites.
   - Optional args without a trailing `()`.

2. Stringly-typed finite domains
   - String matches for statuses, modes, roles, providers, strategies, kinds.
   - Record fields named `status`, `mode`, `state`, `role`, `environment`,
     `kind`, `backend`, `strategy`, `target`, or `provider` typed as `string`.
   - Unknown strings silently defaulting to a valid mode.
   - `type foo_id = string` aliases where distinct IDs can be swapped.

3. Option/Result pyramids
   - Nested matches over `Some`/`None` and `Ok`/`Error`.
   - Manual first-error refs or accumulator matches where Result pipelines would
     be clearer.
   - Repeated JSON/decode/validate/dispatch code that should be extracted.
   - Control-flow fragmentation: the same mode/phase value is matched
     repeatedly through a long imperative function, especially with empty
     branches or inline guard matches. Prefer one higher-level branch, a tuple
     match over the actual dimensions, or a small phase boundary.

4. Eager argument normalization
   - Single-use `let*` values passed unchanged to one function with no further work:
     prefer existing direct bind composition only when the name adds no meaning.
     Keep names that clarify domain phases, types, transformations, or later reuse.
     Standard bind takes the value first; piped bind here uses `Fun.flip Result.bind`.
   - Multi-line `match`, `if`, `try`, Result/Option unwraps, fallbacks, or
     transformations embedded inside an outer function/constructor/effect call.
   - Manual `Error e -> Error e` forwarding before the next domain decision.
   - Inputs validated or defaulted only inside a terminal renderer/effect.
   - Prefer `let*`/existing combinators and a named local binding before
     application. Keep short familiar expressions inline; this is not a ban on
     expressions as arguments.

5. Explicit domain grouping
   - More than five or six primitive/config-fragment arguments that travel as
     one request, spec, runtime, or mode.
   - Several conceptually different collection groups constructed and combined
     in one expression.
   - Prefer an existing domain type, a real named record/variant, or named local
     groups. Never replace a swarm with a vague `deps` bag.

6. Separated effect boundaries
   - A bounded operation computes, interprets, renders, and prints its result in
     one function when the outcome could be tested directly.
   - Side effects buried in transformation pipelines.
   - Prefer operation -> typed outcome -> renderer -> outer controller effect.
     Exempt progress, prompts, streaming, and child-process forwarding where the
     effect is inherently part of execution.

7. Visible phase pipelines
   - Controller-sized closures that mix validation, provisioning, decode,
     decision, execution, shutdown, and error arbitration.
   - Sibling paths that inline the same transition policy separately.
   - Prefer typed phase outcomes and one linear top-level orchestration. Do not
     turn a short exhaustive match into a framework.

## Manual Folder Walk

Walk these folders even if grep finds enough tickets early:

- `framework/ocaml/`
- `cli/lib/`
- `cli/bin/`
- `examples/`
- `internal/tooling/`
- tests and scaffold templates that teach users patterns

For each folder:

1. Read public `.mli` files first.
2. Read type definitions and constructors.
3. Read parsing and rendering functions.
4. Read representative call sites.
5. Read tests/templates/examples for copied patterns.
6. For stateful code, write down the actual phase sequence and sibling paths
   before deciding that nesting is a finding.

## Long Parameter Lists

Do not treat labeled arguments as the automatic final fix.

When a function has more than 3 labeled arguments, decide whether the signature
is still the right abstraction:

- Keep labels when the inputs are few, independent, and the call site is compact.
- Use a record when the fields form a real domain concept such as config,
  request, render spec, deployment target, route, credential set, or environment.
- Use a variant when valid fields differ by mode, such as service/worker/fn,
  GET/request-with-body, or local/customer/hosted deployment.
- Split the function when parameters belong to phases such as parse, validate,
  plan, render, and execute.

Passing records is idiomatic OCaml when the record is a meaningful value with a
name and invariants. Avoid vague "dependencies" records that only hide a messy
signature.

Ticket good targets:

- Manifest/render functions with many fields that should accept a typed render
  spec or workload variant.
- HTTP helpers where method, content type, and body options can be mismatched.
- CLI command bodies where Cmdliner args should be converted into a typed request
  before domain logic runs.

## Helpful Grep Seeds

Use these only as starting points:

```bash
rg -n '\|\s*"[^"]+"\s*->' -g '*.ml' -g '*.mli'
rg -n '\b(status|mode|state|role|environment|kind|backend|strategy|target|provider)\s*:\s*string\b' -g '*.ml' -g '*.mli'
rg -n '\b(true|false)\s+(true|false)\b' -g '*.ml' -g '*.mli'
rg -n '^val .*string -> string|^val .*(bool|int|float) -> .*(bool|int|float)' -g '*.mli'
rg -n '\bmatch\b' -g '*.ml' -g '*.mli'
rg --pcre2 -n -U '\| Error ([a-zA-Z_][a-zA-Z0-9_]*) -> Error \1' -g '*.ml'
rg -n -U 'List\.concat[[:space:]]*\n[[:space:]]*\[' -g '*.ml'
```

After running searches, open files manually with `sed`, `nl`, or an editor.
Do not file tickets from grep output alone.

## Multi-Agent Mode

When multiple agents are available, split the audit by folder. Assign one group
per agent and ask for ticket-quality findings only.

Recommended partitions:

- Agent 1: `framework/`
- Agent 2: `framework/ocaml/kafka-eio-service/`
- Agent 3: `cli/lib/`
- Agent 4: `cli/bin/`
- Agent 5: `examples/` plus scaffold templates
- Agent 6: `internal/tooling/` plus tests

Subagent instruction template:

```text
Inspect <folder-group> for OCaml style audit findings:
boolean traps/positional debt, stringly-typed finite domains, and nested
Option/Result pyramids. Read files manually; grep is only for seeding. Return
ticket-ready findings with file references, problem, goal, and acceptance
criteria. Do not edit files.
```

Merge duplicate findings by API/refactor boundary. Prefer one coherent ticket
over many line-level tickets.

## Ticket Template

```markdown
---
id: CODEX_STYLE_AUDIT-NNN
type: refactor
severity: <high|medium|low>
source: internal/pipeline/audits/STYLE_AUDIT.md
---

<one-line title>

**Depends on:** none.

**Problem:** <specific file references and why this is risky/confusing>

**Goal:** <type-safe or readability target>

**Acceptance criteria:**

- <verifiable criterion>
- <verifiable criterion>
```

Use dependencies only when the ticket truly cannot be started first. A ticket in
`READY_FOR_ENGINEERING/` with an unmet dependency is allowed, but it will not be
actionable until the dependency reaches `DONE/`.

## Quality Bar

Good tickets:

- Name a concrete API or module boundary.
- Include exact file references.
- Explain how the compiler can prevent the issue after refactor.
- For long parameter lists, say whether the fix should be labels, a domain
  record, a mode-specific variant, or a split into smaller phase functions.
- Have acceptance criteria that a reviewer can verify.

Bad tickets:

- "Clean up nested matches in this file."
- One ticket for every string literal.
- Findings copied straight from grep.
- Tickets without a clear owner module or refactor boundary.

## Final Summary

At the end, report:

- Number of tickets created.
- ID range.
- Folders manually inspected.
- Any folders not inspected and why.
- Validation command, usually:

```bash
dune exec internal/tooling/soldev/bin/main.exe -- pipeline ls | rg 'CODEX_STYLE_AUDIT'
```
