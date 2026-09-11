---
id: REFAC-058
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-058/parse-secret-backend-cli
worktree: ../sun-REFAC-058-parse-secret-backend-cli
---

Parse `--secret-backend` flag into `Sun_cli_manifest.secret_backend` at CLI boundary

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_deploy.ml:19–45` defines `parse_secret_backend`, a function that accepts a raw `backend_str : string` and four `string option` parameters and produces a `Sun_cli_manifest.secret_backend`:

```ocaml
let parse_secret_backend backend_str store_ref store_kind key_prefix refresh_interval emit_to =
  match backend_str with
  | "kubernetes-placeholder" | "" -> Sun_cli_manifest.Kubernetes_placeholder
  | "external-secrets" -> ...
  | other -> eprintf "error: unknown --secret-backend value %S..." other; exit 1
```

This function is called from `run` (line 54–55), meaning the raw string travels deep into business logic before being validated. The six-argument positional signature (four `string option` values adjacent to each other) is also prone to silent argument swaps.

Additionally, `secret_backend_to_string` (lines 47–50) converts the variant back to a string for display — confirming the round-trip exists but is done manually in two separate functions instead of once at the CLI boundary.

**Remediation:**

1. Move string-to-variant conversion into a Cmdliner `Arg.conv` (or a small `of_string` helper) that runs when the CLI flags are parsed.
2. Change `run`'s `secret_backend_str : string` parameter (and associated `store_ref`, `store_kind`, `key_prefix`, `refresh_interval`) to a single `secret_backend : Sun_cli_manifest.secret_backend` value assembled by the converter.
3. Delete `parse_secret_backend` — the validation happens at parse time, not inside the run function.
4. The `secret_backend_to_string` helper can remain for display; consider moving it to `sun_cli_manifest.ml` as `Sun_cli_manifest.to_string`.

## Review — automated checks passed
All four remediation requirements are met. parse_secret_backend is deleted. run_config carries a single secret_backend : Sun_cli_manifest.secret_backend field. secret_backend_term assembles the typed variant before run is called. run uses cfg.secret_backend directly.
