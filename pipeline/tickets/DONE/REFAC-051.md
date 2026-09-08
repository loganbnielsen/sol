---
id: REFAC-051
type: audit-finding
severity: low
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-051/strict-set-val
worktree: ../sun-REFAC-051-strict-set-val
---

Tighten `set_val` type: split `Val of string` into `Bool of bool | Float of float`

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_dev.ml:23`:

```ocaml
type set_val =
  | Val of string  (** --set key=val  (YAML-parsed; use for booleans and floats) *)
  | Str of string  (** --set-string key=val  (always treated as string) *)
```

The comment on `Val` admits it covers two conceptually distinct cases: YAML booleans and YAML floats. Callers pass `Val "true"`, `Val "false"`, `Val "1"`, `Val "1Gi"` with no type-level distinction between them, and readers must inspect the string content to understand intent. A typo like `Val "fasle"` passes Helm a silently broken boolean.

The comment on line 23 explicitly flags this: `(* LOGAN: should these be more strictly typed? *)`.

Also: `cli/sun/bin/cmd_dev.ml:119` constructs the boolean string by hand:

```ocaml
let grafana_val = if need_grafana then "true" else "false" in
```

**Remediation:**

1. Extend the type:
   ```ocaml
   type set_val =
     | Bool  of bool    (** --set key=true/false *)
     | Float of float   (** --set key=<number>   *)
     | Str   of string  (** --set-string key=val *)
   ```
2. Update `flag` in `helm_install` to render each constructor appropriately:
   ```ocaml
   | Bool  b -> Printf.sprintf "--set %s=%s" k (string_of_bool b)
   | Float f -> Printf.sprintf "--set %s=%g" k f
   | Str   s -> Printf.sprintf "--set-string %s=%s" k s
   ```
3. Update all call sites (the `~values` lists in `dev_up`) to use `Bool true`, `Bool false`, `Float 1.5`, etc.
4. Delete the `grafana_val` string construction on line 119; replace with `Bool need_grafana`.

## Review — automated checks passed
set_val type replaced with Bool/Float/Str; all call sites updated; grafana flag uses Bool need_grafana; build clean
