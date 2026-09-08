---
id: REFAC-050
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-050/provider-variant
worktree: ../sun-REFAC-050-provider-variant
---

Replace mutually-exclusive bool flags with `provider` variant in `cloud_init`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_cloud_tf.ml:83` defines:

```ocaml
let cloud_init use_aws use_gcp var_file dry_run = ...
```

`use_aws` and `use_gcp` are passed as separate positional booleans even though they represent a single mutually-exclusive choice. The file already declares a `provider` variant at line 79:

```ocaml
type provider = Aws | Gcp
```

The function then immediately reconstructs this variant from the two booleans (lines 85–93), with explicit runtime error handling for the `true, true` and `false, false` cases — failures the compiler could catch instead.

**Remediation:**

1. Change the CLI term in the Cmdliner wiring to produce a `provider` directly (use `Arg.required` with a `Cmdliner.Arg.conv` or a custom `Arg.t` that converts `"aws"` / `"gcp"` to the variant — or keep flag parsing in a helper that returns `(provider, string) result`).
2. Change `cloud_init` signature to `provider -> var_file:string option -> dry_run:bool -> unit`.
3. Delete the `match use_aws, use_gcp with` block.

The `true, true` / `false, false` error paths become compile-time-unreachable rather than runtime exits.

## Review — automated checks passed
cloud_init now takes provider variant; provider_term converts --aws/--gcp flags at parse time; match use_aws,use_gcp block deleted; build clean
