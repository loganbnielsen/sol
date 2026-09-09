---
id: CODEX_STYLE_AUDIT-075
type: refactor
severity: medium
source: docs/audits/STYLE_AUDIT.md
---

`Sol_cli_config`'s `target.provider`/`resource.typ`/`service.typ` are stringly-typed finite domains, and `provider` duplicates a properly-typed variant that already exists elsewhere

**Depends on:** none.

**Problem:** `cli/sol/lib/sol_cli_config.mli` defines `target.provider : string` (line 4), `resource.typ : string option` (line 22), and `service.typ : string option` (line 32) — all read directly from parsed `sol.yml`/target-file YAML with no validation against the actual finite set of valid values. `resource.typ` is compared against the literal `"postgres"` at `sol_cli_config.ml:713` and both `.typ` fields are only ever printed at `cli/sol/bin/cmd_plan.ml:44,51` — nothing stops an invalid or misspelled value from silently parsing successfully and only failing (or worse, silently doing nothing) far downstream.

`provider` specifically already has a correct, properly-typed twin: `cli/sol/bin/cmd_cloud_tf.ml:102` defines `type provider = Aws | Gcp`, parsed from the `<env>/<provider>/<region>` target path with an explicit error on any other value (`cmd_cloud_tf.ml:106-115`). So this codebase has two independent representations of the same two-value domain — one type-safe (derived from the path), one a bare `string` (read from the YAML config) — that can drift out of sync with no compiler warning if a third provider is ever added to one but not the other.

**Goal:** Make `provider` a shared variant type both `Sol_cli_config` and `Sol_cli_cloud_tf` (or wherever the canonical definition should live — likely a shared module both already depend on) use, so an invalid provider string is rejected at config-parse time with a clear error, not silently accepted and only discovered when a downstream Terraform/cloud command fails to recognize it. Consider whether `resource.typ`/`service.typ` warrant the same treatment if their valid value sets are similarly small and fixed (check current callers/docs for the full valid set before deciding — `"postgres"` is the only literal seen in `cli/sol/lib/`, there may be more elsewhere, e.g. a `"dynamodb"` resource type).

**Acceptance criteria:**

- `Sol_cli_config.target.provider` is a variant (e.g. `Aws | Gcp`), not a bare `string`, parsed with a clear error for any other value at config-load time.
- `cmd_cloud_tf.ml`'s existing `provider` type and parsing logic is either reused directly or consolidated with the new shared type — no second independent definition of the same two values.
- A malformed/unknown provider value in `sol.yml` or a target file produces an error at the point the config is loaded, not a `string` that only fails later when something tries to dispatch on it.
- Existing tests for `Sol_cli_config` and `cmd_cloud_tf` continue to pass, and at least one new test covers rejecting an invalid provider value.
