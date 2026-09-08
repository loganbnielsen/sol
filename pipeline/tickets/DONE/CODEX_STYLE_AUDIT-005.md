---
id: CODEX_STYLE_AUDIT-005
type: refactor
severity: medium
source: style audit
branch: CODEX_STYLE_AUDIT-005/labeled-yaml-builders
worktree: ../sun-CODEX-005
---

Label low-level YAML document builder arguments.

**Depends on:** none.

**Problem:** `Sun_cli_manifest` exposes many low-level builders with repeated
positional strings:

- `namespace_doc : string -> string`
- `service_account_doc : string -> string -> string`
- `configmap_doc : ... -> string -> string -> string`
- `cronjob_doc : ... -> string -> string -> string -> string -> string`

The implementation in `cli/sun/lib/sun_cli_manifest_yaml.ml:85-469` uses
short names such as `ns name image schedule`, making accidental swaps easy.

**Goal:** Make manifest builder calls readable without checking the definition.

**Acceptance criteria:**

- Convert public builders to labeled arguments such as `~namespace`, `~name`,
  `~image`, and `~schedule`.
- Add trailing `()` to functions that keep optional arguments.
- Update renderers and tests to use labels.
- Leave internal string formatting behavior unchanged.

## Review — automated checks passed
All 10 builder functions converted to labeled args with correct trailing () on optional-arg functions; build clean; diff confined to cli/sun/; callers, .mli, and tests all updated consistently.
