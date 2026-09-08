# Sun Style Audit — OCaml Type Safety and Config Parsing

## Config parsing policy

External config values — environment variables, CLI flags, and TOML fields from
user input — follow these rules across the Sun codebase.

### 1. Unknown values fail closed

A parser that receives an unrecognised string must return `Error`, not a silent
default.  Example: `KAFKA_SECURITY_PROTOCOL=foo` must produce
`Error "unknown protocol: foo"`, not silently become `Plaintext`.

Already correct examples:
- `Kafka_security.protocol_of_string` — returns `Result`, tests in
  `test_kafka_security.ml` cover rejection of unknown protocols.
- `release_status_of_string` in `sun_cli_registry.ml` — returns `Error` for
  unknown values.
- `secret_backend` CLI argument parsing in `cmd_deploy.ml` — returns
  `\`Error` for unknown `--secret-backend` values.

### 2. Missing required values fail closed

If a value is required for the operation to succeed, its absence must produce a
typed `Error`, not an empty string or zero default.

**Kubernetes_live secret rendering** (`sun_cli_deployment_render.ml`):
When `secret_backend = Kubernetes_live`, every user-declared secret key in
`spec.secrets` must be present in the process environment.  A missing key
returns `Error "Kubernetes_live render failed: required secret env var(s) not
set: KEY_NAME"`.  This propagates through `Sun_cli_deployment_render.render_spec`
(returns `(string * string, string) result`) and `Sun_cli_change_set.build`
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
| CODEX_STYLE_AUDIT-073 | `sun_cli_deployment_render.ml` — `Kubernetes_live` secret rendering | `render_spec` now returns `(string * string, string) result`; missing user-declared secret env vars produce `Error`. |

## Secret strategy contract

Secret handling is encoded as a deployment-phase decision derived from the
`Sun_cli_env_target.t` value.  The allowed combinations are:

| Target | Allowed secret backends | Notes |
|--------|------------------------|-------|
| `Local` (`sun up`) | `Kubernetes_live` | Reads values from the process environment |
| `Customer_direct` | `Kubernetes_live` | Reads values from the process environment |
| `Customer_gitops` | `Kubernetes_placeholder`, `External_secrets` | **Never** `Kubernetes_live` |
| `Sun_hosted` | `Kubernetes_placeholder` (default) | Real secrets managed by the Sun platform |

`Sun_cli_env_target.default_secret_backend` derives the correct default backend
from the target, replacing the previous hard-coded `Kubernetes_placeholder` for
all targets.  `cmd_deploy.ml` additionally enforces the invariant at the CLI
layer: specifying `--secret-backend kubernetes-live` together with `--emit-to`
(which selects a `Customer_gitops` target) is rejected with an actionable error
message before any rendering begins.

This makes GitOps plaintext leakage impossible by construction: the type system
plus the explicit guard ensure that `Kubernetes_live` can never reach the YAML
renderer when the output goes to a file on disk destined for a git repository.

## Areas noted for future improvement

- `param_int` in `sun_cli_control_plane.ml` silently defaults invalid integers
  from HTTP query parameters.  This is lower priority (not CI/CD-facing) but
  should be converted to return `Result` when the control-plane API is
  stabilised.
