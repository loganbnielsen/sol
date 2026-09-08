---
id: REFAC-054
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-054/label-rollout-args
worktree: ../sun-REFAC-054-label-rollout-args
---

Label positional tail arguments in `rollout_doc`

**Depends on:** None.

**Description:**

`cli/sun/lib/sun_cli_manifest_yaml.ml:290`:

```ocaml
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "") ~ports ~probes ~replicas ~cpu ~memory ns name image pd =
```

After the labeled and optional arguments, there are four bare positional parameters: `ns`, `name`, `image`, `pd`. All four are different types (`string`, `string`, `string`, `Sun_cli_toml.progressive_delivery`), but `ns`, `name`, and `image` are all strings — swapping any two compiles fine. The function is also long enough that a call site reader cannot tell which string is which without jumping to the definition.

The companion `deployment_doc` function (earlier in the same file) has the same pattern.

**Remediation:**

Convert the positional tail parameters to labeled arguments:

```ocaml
let rollout_doc ?(extra_labels = []) ?(secret_keys = []) ?(config_hash = "")
    ~ports ~probes ~replicas ~cpu ~memory ~ns ~name ~image ~pd () =
```

Update all call sites in `sun_cli_manifest_yaml.ml` and anywhere `rollout_doc` / `deployment_doc` are called (search for usages). Add the trailing `()` because optional arguments precede the new labeled ones.

## Review — automated checks passed
deployment_doc and rollout_doc fully labelled; .mli matches; all 4 call sites updated; build clean.
