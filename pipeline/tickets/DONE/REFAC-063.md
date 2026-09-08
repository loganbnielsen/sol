---
id: REFAC-063
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-063/flatten-print-outputs
worktree: ../sun-REFAC-063-flatten-print-outputs
---

Flatten `print_outputs` four-level JSON match pyramid in `cmd_cloud_tf.ml`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_cloud_tf.ml:47–75` — the `print_outputs` function matches Terraform JSON output with four levels of nesting:

```
match json with                            (* level 1: top-level assoc *)
| `Assoc pairs ->
  List.iter (fun (key, obj) ->
    match obj with                         (* level 2: per-output object *)
    | `Assoc fields ->
      let sensitive = match List.assoc_opt "sensitive" fields with ...
      if not sensitive then begin
        match List.assoc_opt "value" fields with  (* level 3: value field *)
        | Some (`String v) -> ...
        | Some (`List vs) ->
          let strs = List.filter_map (function   (* level 4: list items *)
            | `String s -> Some s | _ -> None) vs
```

The `| _ -> ()` exit cases at each level are correct but make the intended structure — iterate outputs, skip sensitive, print value — invisible under the nesting.

**Remediation:**

Extract a helper `print_output_field key obj` that handles one `(key, obj)` pair and returns unit. This flattens `print_outputs` to:

```ocaml
let print_outputs chdir_arg =
  ...
  (match json with
   | `Assoc pairs -> List.iter (fun (key, obj) -> print_output_field key obj) pairs
   | _ -> ())
```

Inside `print_output_field`, the three-level match on `obj → sensitive → value` is still multi-level but isolated in a focused function where the nesting is the entire function body rather than a buried branch.

## Review — automated checks passed
Build clean. Extracts print_output_field helper, replaces 4-level nested match in print_outputs with single List.iter call. No ticket files modified.
