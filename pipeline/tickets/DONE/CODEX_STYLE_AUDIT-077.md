---
id: CODEX_STYLE_AUDIT-077
type: refactor
severity: low
source: follow-up from CODEX_STYLE_AUDIT-075 review
---

Parse `sol.yml` target keys into a small variant instead of duplicating target-key string matches

**Depends on:** CODEX_STYLE_AUDIT-075.

**Problem:** `cli/sol/lib/sol_cli_config.ml` now has a helper like:

```ocaml
let target_scalar_key = function
  | "registry" | "base_domain" | "cluster_name" | "terraform_var_file"
  | "observability_backend" -> true
  | _ -> false
```

That helper exists only so the hand-rolled `sol.yml` parser can distinguish an empty scalar target key such as `target.registry:` from an unknown provider box such as `target.azure:`. The same string keys are then matched again where the parser actually applies target fields. This is a small schema leak: strings are allowed at the YAML boundary, but after that the parser should classify them once into a known target-key shape.

**Goal:** Replace the duplicate string-key checks in `target:` parsing with a small internal variant, for example:

```ocaml
type target_key =
  | Target_registry
  | Target_base_domain
  | Target_cluster_name
  | Target_terraform_var_file
  | Target_observability_backend
  | Target_provider_box of Sol_cli_provider.t
  | Target_unknown of string
```

The parser should convert the raw YAML key string once, then match on this variant for empty-value handling and field application.

**Acceptance criteria:**

- `target_scalar_key` or equivalent duplicate string-key predicate is removed.
- The known `target:` scalar keys are defined in one parser classification function, not repeated across separate checks.
- Provider boxes continue to use `Sol_cli_provider` for supported provider names.
- Existing error behavior is preserved for missing scalar values, duplicate provider boxes, unknown provider boxes, and unknown target keys.
- Existing `Sol_cli_config` tests pass; add or adjust focused tests only if preserving an error branch would otherwise be untested.
