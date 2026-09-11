---
id: REFAC-036
type: refactor
severity: high
source: codebase simplification review 2026-06-15
branch: REFAC-036/decompose-manifest
worktree: /home/lbendtly/Code/sun-REFAC-036-decompose-manifest
---

Decompose sun_cli_manifest.ml (667 lines, 3 concerns) into focused modules

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_manifest.ml` at 667 lines mixes three distinct responsibilities:

| Concern | Lines | Description |
|---------|-------|-------------|
| Service discovery | 26–107 | `prim_of_suffix`, `discover_services`, `extract_schedule` — scans `app/` |
| YAML document generators | 109–568 | 17 `*_doc` and `render_*` functions building Kubernetes YAML strings |
| kubectl I/O | 569–667 | `render`, `write_tmp`, `apply_live` — writes files, shells out to kubectl |

The YAML generator functions (the 17 `*_doc`/`render_*` functions) constitute ~450 lines and are the core of the module. They have no dependency on the discovery functions or on file I/O — they take typed arguments and return strings. Currently, finding any specific YAML generator requires scrolling through 450 lines of string-building code.

**Remediation:**

Split into:

1. **`sun_cli_manifest_yaml.ml`** — all `*_doc` and `render_*` functions: `namespace_doc`, `service_account_doc`, `configmap_doc`, `secret_doc`, `external_secret_doc`, `deployment_doc`, `rollout_doc`, `service_doc`, `ingress_doc`, `network_policy_doc`, `cronjob_doc`, `render`, etc. (~450 lines). No filesystem or subprocess calls.

2. **`sun_cli_manifest.ml`** — service discovery (`prim_of_suffix`, `discover_services`, `extract_schedule`), the `service` type, and the kubectl I/O functions (`write_tmp`, `apply_live`, `render` orchestration). Keep the `secret_backend` type here since `apply_live` references it. (~120 lines after split.)

Re-export any types that callers expect from `Sun_cli_manifest` to preserve the public API without requiring callers to change.

**Acceptance criteria:**

- `sun_cli_manifest.ml` is ≤150 lines after the split.
- `sun_cli_manifest_yaml.ml` contains no `Sys.command`, `open_out`, or `Sys.readdir` calls.
- `dune build` passes.
- No external callers need to change their `open` or module references.

## Review — automated checks passed
sun_cli_manifest.ml split: yaml generators in sun_cli_manifest_yaml.ml (includes render/extract_schedule); main file 105 lines; no Sys.command/open_out/Sys.readdir in yaml module; all tests pass; no callers changed
