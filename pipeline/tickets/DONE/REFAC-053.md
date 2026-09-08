---
id: REFAC-053
type: audit-finding
severity: medium
source: ocaml-type-safety-audit 2026-06-16
branch: REFAC-053/run-config-record
worktree: ../sun-REFAC-053-run-config-record
---

Collapse `cmd_deploy.run` 12-arg positional function into a config record

**Depends on:** None.

**Description:**

`cli/sun/bin/cmd_deploy.ml:52–53`:

```ocaml
let run filter_path dry_run emit_to emit_plan_to image_tag registry
        secret_backend_str store_ref store_kind key_prefix refresh_interval confirm_group_change =
```

This function takes 12 positional arguments. Several are `string option` values with similar types (e.g., `emit_to`, `emit_plan_to`, `image_tag`, `registry`, `store_ref`, `store_kind`, `key_prefix`, `refresh_interval`) that could be silently swapped. The function must be called by the Cmdliner term with the arguments in exactly the right order — a fragile coupling that grows worse as flags are added.

Additionally, `parse_secret_backend` on line 19 takes 6 positional args:

```ocaml
let parse_secret_backend backend_str store_ref store_kind key_prefix refresh_interval emit_to =
```

Four of these are `string option` values; misplacing any two compiles fine.

**Remediation:**

1. Define a `run_config` record that groups the arguments:
   ```ocaml
   type run_config = {
     filter_path          : string option;
     dry_run              : bool;
     emit_to              : string option;
     emit_plan_to         : string option;
     image_tag            : string option;
     registry             : string option;
     secret_backend_str   : string;
     store_ref            : string option;
     store_kind           : string option;
     key_prefix           : string option;
     refresh_interval     : string option;
     confirm_group_change : bool;
   }
   ```
2. Change `run` to accept `run_config` and update all internal references.
3. Group the `parse_secret_backend` call site so the secret-related fields are visually isolated.
4. The Cmdliner term builds a `run_config` value before invoking `run`.

Note: REFAC-058 separately proposes replacing `secret_backend_str : string` with the typed `Sun_cli_manifest.secret_backend` variant — this ticket's record should use `string` for now and update the field type once that ticket lands.

## Review — automated checks passed
Build clean, run_config type defined with 12 fields, run accepts single cfg arg, all field accesses use cfg. prefix
