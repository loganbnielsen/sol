# Sol Style Audit — OCaml Type Safety and Config Parsing

## Readability and API meta-principles

These are audit lenses, not mechanical formatting laws. Start from a concrete example,
extract the principle, then inspect the whole codebase for the same design pressure.
Read every candidate in context; grep only seeds the walk.

### Eager argument normalization

Resolve, validate, default, and bind non-trivial expressions before passing them to a
higher-order function, constructor, or terminal effect. Prefer `let*` when an `Error e`
arm only returns `Error e`, so the remaining code states the next domain decision.

Flag multi-line matches, conditionals, exception handlers, Option/Result unwraps,
fallbacks, and transformations embedded in argument position when pre-binding makes the
outer operation readable in one pass. Keep short familiar expressions inline.

### Explicit domain grouping

Single-use unchanged handoffs are candidates, not automatic findings. Remove a binding
only when its name adds no domain meaning and direct composition is clearer.
`let* cfg = apply ... in Ok cfg` should simply be `apply ...`; retain
`let* creds_json = classify_imdsv2_response ... in resolved_of_json_credentials creds_json`
because it identifies a meaningful phase. Keep bindings for reuse, transformations,
additional arguments, clearer types/control flow, or whenever prefix `Result.bind`
would make the reader work harder. Standard `Result.bind` and `Option.bind` take their
value first; piped bind requires the existing `Fun.flip Result.bind` form, not plain
`|> Result.bind f`. Introduce no new operator or line-count objective.

When arguments travel together as one real concept, represent that concept with an
existing or named record/variant. Labels alone do not make a 20-argument API cohesive.
Choose a phase split when the arguments belong to sequential work, and never hide them
in a vague dependencies record.

A family of optional/defaulted callbacks is one concept. When several `?on_*` hooks on
one function are all instrumentation or lifecycle hooks of the same concern — a
consumer's `on_assigned`/`on_revoked`/`on_poll`/`on_retry`, an HTTP client's retry and
redirect observers — group them behind one named record with a `no_hooks` default, so
the signature stays about the operation instead of growing one callback at a time. Do
not bundle a handle (`?ot`), a policy, or an unrelated required dependency into that
record merely to shorten the signature; those stay separate arguments.

When several collections mean different things, name the conceptual groups before
combining them. Preserve useful pipelines within each group and do not name every
trivial intermediate.

### Separated effect boundaries

For bounded work, prefer operation → typed outcome → renderer → outer controller
effect. Semantic failure belongs with the outcome, while stdout/stderr and exit
conversion belong at the command boundary. Progress, prompts, streaming, and child
output may remain effectful because buffering them would change the operation.

### Visible phase pipelines

Stateful orchestration should expose validation, provisioning, decode/decision,
execution, shutdown, and reconciliation as named phases with typed transitions. Look
for controller-sized closures and sibling paths that duplicate policy. Do not extract a
short exhaustive match or invent a state-machine framework without a real repeated
boundary.

### Required sweep evidence

For each principle, completion notes must name the folders inspected, representative
changes, and representative candidates deliberately retained. Useful seeds include:

```bash
rg --pcre2 -n -U '\| Error ([a-zA-Z_][a-zA-Z0-9_]*) -> Error \1' --glob '*.ml'
rg -n -U 'List\.concat[[:space:]]*\n[[:space:]]*\[' --glob '*.ml'
```

Neither result set is a finding without reading the surrounding flow.

## Executable parameter candidate scan

The advisory AST checker in [`internal/tooling/style_audit`](../../tooling/style_audit/README.md)
seeds the long-parameter-list and explicit-domain-grouping review:

```bash
opam exec -- dune exec internal/tooling/style_audit/main.exe -- cli framework internal/tooling examples
opam exec -- dune exec internal/tooling/style_audit/main.exe -- --json ~/Code/kafka-eio
```

It reports name families (three `on_*` arguments or four with another shared
prefix), signatures with 12 value parameters or four optional arguments, and
syntactic default counts. Warnings do not fail the scan or establish a finding;
parse/I/O errors do fail it. Inspect each candidate's types and callers before
choosing a hooks/config type or retaining independent arguments. Other style
principles still require contextual review.

## Config parsing policy

External config values — environment variables, CLI flags, and TOML fields from
user input — follow these rules across the Sol codebase.

### 1. Unknown values fail closed

A parser that receives an unrecognised string must return `Error`, not a silent
default.  Example: `KAFKA_SECURITY_PROTOCOL=foo` must produce
`Error "unknown protocol: foo"`, not silently become `Plaintext`.

Already correct examples:
- `Kafka.Security.protocol_of_string` — returns `Result`. The module is in the
  standalone `kafka-eio` opam package, not this repository (see the source-location
  notes in `AUDIT.md`), so its rejection tests live with that package.
- `apply_mode_of_string` in `sol_cli_release.ml` — returns `Error` for unknown
  values.
- External secret authority parsing in `sol_cli_config.ml` — rejects malformed
  authority declarations rather than selecting a default.

### 2. Missing required values fail closed

If a value is required for the operation to succeed, its absence must produce a
typed `Error`, not an empty string or zero default.

**Secret authority and delivery** (`cli/lib/deploy/sol_cli_secret.ml`): every required unit
key has an explicit `sol` or `external` authority. Sol writes only Sol-owned keys to
`<unit>-secrets`; ESO writes external keys to `<unit>-external-secrets`. Direct and GitOps
renders use these exact references and never emit values or placeholder Secrets. Direct
deployment fails closed unless Sol-owned keys exist and ESO reports `SecretSynced` with the
exact materialized key set.

### 3. Intentional defaults for omitted optional fields are acceptable

`Option.value toml.replicas ~default:1` is correct — the field is optional and
the default is documented.  Platform-default keys such as `POSTGRES_URL` and `SOL_API_KEY` are declared for each
workload and resolved from target configuration. Sol platform Jobs use the reserved
`@platform` target scope; those values are not copied into application unit Secrets.

### 4. Parsers return `Result`

Functions that parse external strings into typed values must have the signature
`string -> ('a, string) result`, not `string -> 'a` with a fallback.  Callers
unwrap with an explicit error path so failures are surfaced as early as
possible.

## Sites examined in the support libraries and deliberately left (2026-09-29)

The pinned `*-eio` packages were re-audited against this checklist after
REFAC-138, and three families of candidate findings were examined in the code
and left unchanged. Recording them here is the point: a later pass should not
have to re-derive why, and if it disagrees, it changes the specific site named.

- **A library-default warning sink that prints** (`kafka-eio`
  `kafka_consumer.ml:57 default_on_warning` and `:213 default_on_poll_error`,
  `lambda-eio` `lambda_runtime.ml:132 default_on_error`, `obs-eio`
  `obs_eio.ml:129,138,158`, `obs-loki-eio` `obs_loki.ml:140`,
  `obs-prometheus-eio` `obs_prometheus.ml:68`). REFAC-135's rule — a library
  returns its warnings and the caller owns the sink — was considered and does not
  apply here: each of these is a *named, overridable default* on a callback the
  caller replaces by passing their own, not a print buried in a code path. The
  alternative, a silent default, would hide poll/rebalance/backend failures with
  nothing to replace. `obs-eio`'s two `Printf.printf` sites are a backend the
  caller selects, i.e. the sink *is* the feature.
- **`= ""` / `Some ""` checks** beyond the ones REFAC-138 already recorded
  (`obs-loki-eio` `obs_loki.ml:17` truncated-body formatting,
  `obs-prometheus-eio` `obs_prometheus.ml:399` `if body = "" then Ok ()`).
  Formatting a possibly-empty detail, and treating an empty renderer output as
  "nothing to push", are decisions at the point of formatting rather than an
  absent-vs-empty domain value being guessed. The empty-logfmt-key check next to
  `obs_loki.ml:17` *was* a real instance and is fixed in that repository's own
  PR: an empty field name is now omitted rather than renamed to `"field"`.
- **A duplicate three-line helper** (`truncated`-and-detail formatting, identical
  in `obs-loki-eio/lib/obs_loki.ml:17` and `obs-tempo-eio/lib/obs_tempo.ml:22`).
  Sharing it would mean a new package dependency between two sibling backends for
  three lines; the checklist says to keep a duplicate that small.

Constructor argument checks that raise `Invalid_argument` on a programmer error
remain out of scope, as REFAC-138 recorded (`obs-eio` metric/label names,
`pg-eio`'s `Identifier.of_string_exn`, which now takes a variant kind).

## Areas noted for future improvement

*None open.* The one item here — `param_int` silently defaulting invalid integers
from control-plane HTTP query parameters — named a function and a module
(`sun_cli_control_plane.ml`) that no longer exist: the control-plane API surface it
belonged to is not in this repository. It is deleted rather than re-pointed at
whatever module looks closest today, because there is no current call site to fix.

### The `*-eio` facades (2026-09-29)

`kafka-eio`'s `Kafka` and `aws-eio`'s `Aws` mirrored the interfaces of the modules
they re-exported, which read as duplication (REFAC-158). It was not: the mirrored
modules were `private_modules`, so the copies were the only way to keep the
installed `.cmi` self-contained, and replacing them with `module type of` — which
gives every datatype a fresh type — broke `Aws.Error.t`'s identity with
`Aws_error.t`. Both packages now install their modules and alias them from the
facade, which removes the copies without either hazard. The reasoning is recorded
on REFAC-158 and in each package's `CHANGES.md`.

## Implementation-quality pass (2026-10-02)

A second pass over `main` at `2c8d9ea8` looking past the type-checker checklist
at execution shape: exception/control-flow usage, Result composition,
duplicated helpers, mutation and branching, parsing boundaries, shell logic
that belongs in OCaml, oversized functions, parameter smells, naming and error
semantics, and dead compatibility code.

**Folders walked.** `cli/lib/` (base, kube, workspace, cloud, deploy, local),
`cli/bin/`, `framework/ocaml/*/lib`. Seeded with
`Sys.command`/`Unix.open_process`, `failwith`/`raise`/`assert`, `[@deprecated]`/
`legacy`/`compat`, `Option.get`/`List.hd`/`List.nth`, identity `Error x -> Error x`,
catch-all `exception _ ->`, `exit` from `cli/lib`, and a top-level function
length scan.

**Filed.** CODEX_STYLE_AUDIT-080 (one substring toolkit),
-081 (local component variant), -082 (typed declared-contract decode),
-083 (port-forward retry policy out of a generated shell script),
-084 (provider capability records from named values).

**Closed (2026-10-02).** All five are implemented and merged: 080–082 in #910,
083 in #917, 084 in this change. There is no open work item from this pass. The
retained candidates below are decisions not to act, with their reasons; a later
pass should read them before re-deriving them.

**Retained candidates, with reasons.**

- `Sol_cli_compat` is the language type (`Ocaml | Typescript`), not a
  compatibility shim; its name is misleading. A rename to `Sol_cli_language`
  touches ~23 files including `sol_cli_deployment_render.ml`, which BUG-054
  owns, so it is deferred rather than filed as a rename that would collide.
- `Sol_cli_compat.supported_by_profile` returns `[ Ocaml ]` for every profile
  while `all` includes `Typescript`. Whether a profile should ever accept
  TypeScript is a product decision (DEC-022, FEAT-082), not a mechanical fix,
  so it is recorded and not filed.
- `sol_cli_config.ml` (1445 lines) and its `decode_layer` (292 lines) are
  REFAC-140's split; the format-parsing pieces touched here are only the
  helpers, not the split.
- `sol_cli_supervised.run` (131 lines) and `sol_cli_installation_stage.reconcile`
  (145 lines) are controller-shaped by design — they fork/exec and arbitrate
  interrupts — and the checklist exempts child-process forwarding. Left.
- The 14 `| Error e -> Error e` identity arms were read; the ones that are the
  whole body of a match (`sol_cli_workload_scope.workloads_of_json`) could be a
  `Result.map`, but each remaining one carries a preceding multi-line match and
  the forwarding arm is the clearest form. Left, per the checklist's
  "candidates, not automatic findings".
- `internal/tooling/sol_process.run_shell` is the deliberate shell entry point
  (`sh -c`) of a maintainer tooling library; no shipped code depends on it.
  Shipped subprocess calls go through `Sol_cli_process.cmd`, whose `cmd` carries
  a `string list` argv, and `Sys.command` appears nowhere in `cli/`, `framework/`
  or `platform/`. Left: the shell entry point is that library's interface, and
  the argv helpers quote each element for display.
