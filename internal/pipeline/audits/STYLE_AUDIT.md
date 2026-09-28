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

When arguments travel together as one real concept, represent that concept with an
existing or named record/variant. Labels alone do not make a 20-argument API cohesive.
Choose a phase split when the arguments belong to sequential work, and never hide them
in a vague dependencies record.

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
- `secret_backend` CLI argument parsing in `cmd_deploy.ml` — returns
  `\`Error` for unknown `--secret-backend` values.

### 2. Missing required values fail closed

If a value is required for the operation to succeed, its absence must produce a
typed `Error`, not an empty string or zero default.

**Kubernetes_live secret rendering** (`sol_cli_deployment_render.ml`):
When `secret_backend = Kubernetes_live`, every user-declared secret key in
`spec.secrets` must be present in the process environment.  A missing key
returns `Error "Kubernetes_live render failed: required secret env var(s) not
set: KEY_NAME"`.  This propagates through `Sol_cli_deployment_render.render_spec`
(returns `(string * string, string) result`) and `Sol_cli_change_set.build`
(returns `(change_set, string) result`), so callers must handle the error
before any side effect occurs.

### 3. Intentional defaults for omitted optional fields are acceptable

`Option.value toml.replicas ~default:1` is correct — the field is optional and
the default is documented.  Platform-default secrets such as `POSTGRES_URL`
(in `default_secrets`) intentionally use `""` when unset; operators fill them
in via a secrets manager before applying.  This is an explicit, documented
design choice, not a silent failure.

### 4. Parsers return `Result`

Functions that parse external strings into typed values must have the signature
`string -> ('a, string) result`, not `string -> 'a` with a fallback.  Callers
unwrap with an explicit error path so failures are surfaced as early as
possible.

## Findings addressed by this policy

| ID | Location | Fix |
|----|----------|-----|
| CODEX_STYLE_AUDIT-073 | `sol_cli_deployment_render.ml` — `Kubernetes_live` secret rendering | `render_spec` now returns `(string * string, string) result`; missing user-declared secret env vars produce `Error`. |

## Secret strategy contract

Secret handling is encoded as a deployment-phase decision derived from the
`Sol_cli_env_target.t` value.  The allowed combinations are:

| Target | Allowed secret backends | Notes |
|--------|------------------------|-------|
| `Local` (`sol up`) | `Kubernetes_live` | Reads values from the process environment |
| `Customer_direct` | `Kubernetes_live` | Reads values from the process environment |
| `Customer_gitops` | `Kubernetes_placeholder`, `External_secrets` | **Never** `Kubernetes_live` |
| `Sol_hosted` | `Kubernetes_placeholder` (default) | Real secrets managed by the Sol platform |

`Sol_cli_env_target.default_secret_backend` derives the correct default backend
from the target, replacing the previous hard-coded `Kubernetes_placeholder` for
all targets.  `cmd_deploy.ml` additionally enforces the invariant at the CLI
layer: specifying `--secret-backend kubernetes-live` together with `--emit-to`
(which selects a `Customer_gitops` target) is rejected with an actionable error
message before any rendering begins.

This makes GitOps plaintext leakage impossible by construction: the type system
plus the explicit guard ensure that `Kubernetes_live` can never reach the YAML
renderer when the output goes to a file on disk destined for a git repository.

## Areas noted for future improvement

*None open.* The one item here — `param_int` silently defaulting invalid integers
from control-plane HTTP query parameters — named a function and a module
(`sun_cli_control_plane.ml`) that no longer exist: the control-plane API surface it
belonged to is not in this repository. It is deleted rather than re-pointed at
whatever module looks closest today, because there is no current call site to fix.
